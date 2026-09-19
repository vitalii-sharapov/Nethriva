import Combine
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SessionConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)
}

protocol SessionDriver: AnyObject {
    var state: SessionConnectionState { get }
    func stop()
}

enum SSHSessionError: LocalizedError {
    case cancelled
    case invalidChannelType
    case passwordRequired
    case rejectedHostKey

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "The SSH connection was cancelled."
        case .invalidChannelType:
            "The server did not open an interactive SSH session."
        case .passwordRequired:
            "A password is required for this connection."
        case .rejectedHostKey:
            "The server identity was not trusted."
        }
    }
}

/// Owns the UI-facing lifecycle for one SSH tab. Network work remains on a
/// dedicated SwiftNIO event-loop thread and all published updates return to main.
final class SSHSessionDriver: ObservableObject, SessionDriver {
    @Published private(set) var state: SessionConnectionState = .idle
    @Published private(set) var hostKeyChallenge: SSHHostKeyChallenge?

    let connection: RemoteConnection
    var onData: (([UInt8]) -> Void)?

    private var transport: SSHConnectionTransport?
    private var hostKeyDecision: ((Bool) -> Void)?
    private var isStopping = false

    init(connection: RemoteConnection) {
        self.connection = connection
    }

    deinit {
        transport?.disconnect()
    }

    func start(password: String, columns: Int = 80, rows: Int = 24) {
        stop()

        guard !password.isEmpty else {
            state = .failed(SSHSessionError.passwordRequired.localizedDescription)
            return
        }

        isStopping = false
        state = .connecting

        let transport = SSHConnectionTransport(
            connection: connection,
            password: password,
            initialSize: (max(columns, 1), max(rows, 1)),
            hostKeyStore: .shared,
            onHostKeyChallenge: { [weak self] challenge, decision in
                DispatchQueue.main.async {
                    guard let self, !self.isStopping else {
                        decision(false)
                        return
                    }
                    self.hostKeyDecision = decision
                    self.hostKeyChallenge = challenge
                }
            },
            onConnected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isStopping else { return }
                    self.state = .connected
                }
            },
            onData: { [weak self] bytes in
                DispatchQueue.main.async {
                    self?.onData?(bytes)
                }
            },
            onClosed: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isStopping else { return }
                    if case .failed = self.state { return }
                    self.state = .disconnected
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.isStopping else { return }
                    self.state = .failed(Self.readableMessage(for: error))
                }
            }
        )

        self.transport = transport
        transport.connect()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        transport?.send(Data(bytes))
    }

    func resize(columns: Int, rows: Int) {
        transport?.resize(columns: columns, rows: rows)
    }

    func resolveHostKey(trust: Bool) {
        let decision = hostKeyDecision
        hostKeyDecision = nil
        hostKeyChallenge = nil
        decision?(trust)
    }

    func stop() {
        isStopping = true
        hostKeyDecision?(false)
        hostKeyDecision = nil
        hostKeyChallenge = nil
        transport?.disconnect()
        transport = nil
        if state != .idle {
            state = .disconnected
        }
    }

    private static func readableMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }

        let details = String(describing: error)
        if details.localizedCaseInsensitiveContains("authentication") {
            return "SSH authentication failed. Check the username and password, then reconnect."
        }
        if details.localizedCaseInsensitiveContains("refused") {
            return "The server refused the connection. Check the host, port, and SSH service."
        }
        return "SSH connection failed: \(details)"
    }
}

private final class ConfirmingHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    typealias ChallengeHandler = (SSHHostKeyChallenge, @escaping (Bool) -> Void) -> Void

    private let endpoint: String
    private let store: SSHHostKeyStore
    private let onChallenge: ChallengeHandler

    init(endpoint: String, store: SSHHostKeyStore, onChallenge: @escaping ChallengeHandler) {
        self.endpoint = endpoint
        self.store = store
        self.onChallenge = onChallenge
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let identity = SSHHostKeyIdentity(hostKey: hostKey)
        let savedKey = store.trustedKey(for: endpoint)

        if savedKey == identity.openSSH {
            validationCompletePromise.succeed(())
            return
        }

        let challenge = SSHHostKeyChallenge(
            endpoint: endpoint,
            algorithm: identity.algorithm,
            fingerprint: identity.fingerprint,
            isChangedKey: savedKey != nil
        )

        let decisionLock = NSLock()
        var hasDecided = false
        onChallenge(challenge) { [store, endpoint] shouldTrust in
            decisionLock.lock()
            guard !hasDecided else {
                decisionLock.unlock()
                return
            }
            hasDecided = true
            decisionLock.unlock()

            if shouldTrust {
                store.trust(identity, for: endpoint)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSessionError.rejectedHostKey)
            }
        }
    }
}

private final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let initialSize: (columns: Int, rows: Int)
    private let onData: ([UInt8]) -> Void
    private let onClosed: () -> Void
    private var didNotifyClosure = false

    init(
        initialSize: (columns: Int, rows: Int),
        onData: @escaping ([UInt8]) -> Void,
        onClosed: @escaping () -> Void
    ) {
        self.initialSize = initialSize
        self.onData = onData
        self.onClosed = onClosed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.columns,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "LANG",
                value: Locale.current.identifier.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
            ),
            promise: nil
        )
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        onData(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            onData(Array("\r\n[SSH session exited with status \(status.exitStatus)]\r\n".utf8))
            notifyClosed()
            context.close(promise: nil)
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onData(Array("\r\n[SSH session closed by signal \(signal.signalName)]\r\n".utf8))
            notifyClosed()
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        notifyClosed()
        context.fireChannelInactive()
    }

    private func notifyClosed() {
        guard !didNotifyClosure else { return }
        didNotifyClosure = true
        onClosed()
    }
}

private final class SSHConnectionTransport {
    typealias HostKeyChallengeHandler = (SSHHostKeyChallenge, @escaping (Bool) -> Void) -> Void

    private let connection: RemoteConnection
    private let password: String
    private let initialSize: (columns: Int, rows: Int)
    private let hostKeyStore: SSHHostKeyStore
    private let onHostKeyChallenge: HostKeyChallengeHandler
    private let onConnected: () -> Void
    private let onData: ([UInt8]) -> Void
    private let onClosed: () -> Void
    private let onError: (Error) -> Void
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var parentChannel: Channel?
    private var sessionChannel: Channel?
    private var didShutdown = false
    private var isDisconnectRequested = false

    init(
        connection: RemoteConnection,
        password: String,
        initialSize: (Int, Int),
        hostKeyStore: SSHHostKeyStore,
        onHostKeyChallenge: @escaping HostKeyChallengeHandler,
        onConnected: @escaping () -> Void,
        onData: @escaping ([UInt8]) -> Void,
        onClosed: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.connection = connection
        self.password = password
        self.initialSize = (initialSize.0, initialSize.1)
        self.hostKeyStore = hostKeyStore
        self.onHostKeyChallenge = onHostKeyChallenge
        self.onConnected = onConnected
        self.onData = onData
        self.onClosed = onClosed
        self.onError = onError
    }

    func connect() {
        let endpoint = "[\(connection.host.lowercased())]:\(connection.port)"
        let serverDelegate = ConfirmingHostKeysDelegate(
            endpoint: endpoint,
            store: hostKeyStore,
            onChallenge: onHostKeyChallenge
        )
        let userDelegate = SimplePasswordDelegate(
            username: connection.username,
            password: password
        )

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let self else { throw SSHSessionError.cancelled }
                    let handler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: userDelegate,
                                serverAuthDelegate: serverDelegate
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(handler)
                    try pipeline.addHandler(
                        SSHErrorHandler { [weak self] error in
                            self?.fail(error)
                        }
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: connection.host, port: connection.port).whenComplete { [self] result in
            switch result {
            case .failure(let error):
                self.fail(error)
                self.shutdownGroup()
            case .success(let channel):
                self.lock.lock()
                self.parentChannel = channel
                let shouldClose = self.isDisconnectRequested
                self.lock.unlock()

                channel.closeFuture.whenComplete { [self] _ in
                    self.onClosed()
                    self.shutdownGroup()
                }
                if shouldClose {
                    channel.close(promise: nil)
                } else {
                    self.createSessionChannel(on: channel)
                }
            }
        }
    }

    func send(_ data: Data) {
        guard let channel = currentSessionChannel(), !data.isEmpty else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                promise: nil
            )
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, let channel = currentSessionChannel() else { return }
        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: columns,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    func disconnect() {
        lock.lock()
        isDisconnectRequested = true
        let channel = parentChannel
        lock.unlock()

        if let channel {
            channel.eventLoop.execute {
                channel.close(promise: nil)
            }
        }
    }

    private func createSessionChannel(on channel: Channel) {
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
                self.disconnect()
            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] child, channelType in
                    guard let self, channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(SSHSessionError.invalidChannelType)
                    }

                    return child.eventLoop.makeCompletedFuture {
                        let pipeline = child.pipeline.syncOperations
                        try pipeline.addHandler(
                            SSHShellChannelHandler(
                                initialSize: self.initialSize,
                                onData: self.onData,
                                onClosed: { [weak self] in self?.disconnect() }
                            )
                        )
                        try pipeline.addHandler(
                            SSHErrorHandler { [weak self] error in
                                self?.fail(error)
                                self?.disconnect()
                            }
                        )
                    }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.fail(error)
                        self.disconnect()
                    case .success(let child):
                        self.lock.lock()
                        self.sessionChannel = child
                        self.lock.unlock()
                        self.onConnected()
                    }
                }
            }
        }
    }

    private func currentSessionChannel() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return sessionChannel
    }

    private func fail(_ error: Error) {
        onError(error)
    }

    private func shutdownGroup() {
        lock.lock()
        guard !didShutdown else {
            lock.unlock()
            return
        }
        didShutdown = true
        parentChannel = nil
        sessionChannel = nil
        lock.unlock()

        group.shutdownGracefully { _ in }
    }
}
