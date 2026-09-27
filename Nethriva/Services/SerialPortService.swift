import Darwin
import Foundation

enum SerialPortDiscovery {
    static func availablePorts(in directory: String = "/dev") -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("cu.") }
            .map { directory + "/" + $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isValidDevicePath(_ path: String) -> Bool {
        let prefix = path.hasPrefix("/dev/cu.") ? "/dev/cu." : "/dev/tty."
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        return !suffix.isEmpty && !suffix.contains("/") && !suffix.contains("..")
            && !suffix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct SerialPortConfiguration {
    static let supportedBaudRates = [300, 1_200, 2_400, 4_800, 9_600, 19_200,
                                     38_400, 57_600, 115_200, 230_400]

    let path: String
    let baudRate: Int
    let dataBits: Int
    let parity: SerialParity
    let stopBits: Int
    let flowControl: SerialFlowControl

    init(connection: RemoteConnection) {
        path = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        baudRate = connection.effectiveSerialBaudRate
        dataBits = connection.effectiveSerialDataBits
        parity = connection.effectiveSerialParity
        stopBits = connection.effectiveSerialStopBits
        flowControl = connection.effectiveSerialFlowControl
    }

    var isValid: Bool {
        SerialPortDiscovery.isValidDevicePath(path)
            && Self.supportedBaudRates.contains(baudRate)
            && (dataBits == 7 || dataBits == 8)
            && (stopBits == 1 || stopBits == 2)
    }
}

final class SerialPortService {
    enum State {
        case connected
        case ended(String)
    }

    var onData: (([UInt8]) -> Void)?
    var onState: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.vitalii.nethriva.serial")
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingOutput: [UInt8] = []
    private var retryScheduled = false
    private var stopped = false

    func open(_ configuration: SerialPortConfiguration) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            guard configuration.isValid else {
                self.finish("Invalid serial port or settings.")
                return
            }
            let fd = Darwin.open(configuration.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                self.finish("Could not open \(configuration.path): \(self.systemError())")
                return
            }
            guard self.configure(fd, with: configuration) else {
                let reason = self.systemError()
                Darwin.close(fd)
                self.finish("Could not configure serial port: \(reason)")
                return
            }
            self.descriptor = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            self.readSource = source
            source.resume()
            self.publish(.connected)
        }
    }

    func send(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.descriptor >= 0, !self.stopped else { return }
            self.pendingOutput.append(contentsOf: bytes)
            self.drainOutput()
        }
    }

    func close() {
        queue.async {
            self.stopped = true
            self.closeDescriptor()
        }
    }

    private func configure(_ fd: Int32, with config: SerialPortConfiguration) -> Bool {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { return false }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_cflag |= config.dataBits == 7 ? tcflag_t(CS7) : tcflag_t(CS8)
        if config.parity != .none {
            options.c_cflag |= tcflag_t(PARENB)
            if config.parity == .odd { options.c_cflag |= tcflag_t(PARODD) }
            options.c_iflag |= tcflag_t(INPCK)
        }
        if config.stopBits == 2 { options.c_cflag |= tcflag_t(CSTOPB) }
        switch config.flowControl {
        case .none: break
        case .hardware: options.c_cflag |= tcflag_t(CRTSCTS)
        case .software: options.c_iflag |= tcflag_t(IXON | IXOFF)
        }
        guard cfsetispeed(&options, speed_t(config.baudRate)) == 0,
              cfsetospeed(&options, speed_t(config.baudRate)) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0 else { return false }
        return true
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            let bytes = Array(buffer.prefix(count))
            DispatchQueue.main.async { [weak self] in self?.onData?(bytes) }
        } else if count == 0 {
            finish("Serial device disconnected.")
        } else if errno != EAGAIN && errno != EINTR {
            finish("Serial read failed: \(systemError())")
        }
    }

    private func drainOutput() {
        guard descriptor >= 0, !pendingOutput.isEmpty else { return }
        let count = pendingOutput.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            pendingOutput.removeFirst(count)
            if !pendingOutput.isEmpty { drainOutput() }
        } else if count < 0 && errno != EAGAIN && errno != EINTR {
            finish("Serial write failed: \(systemError())")
        } else if !retryScheduled {
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.drainOutput()
            }
        }
    }

    private func finish(_ message: String) {
        guard !stopped else { return }
        stopped = true
        closeDescriptor()
        publish(.ended(message))
    }

    private func closeDescriptor() {
        readSource?.cancel()
        readSource = nil
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        pendingOutput.removeAll()
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private func systemError() -> String { String(cString: strerror(errno)) }
}
