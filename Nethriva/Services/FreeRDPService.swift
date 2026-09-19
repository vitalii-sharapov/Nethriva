import Foundation

enum FreeRDPServiceError: LocalizedError {
    case runtimeNotFound
    case invalidSetting(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            "FreeRDP is not installed. Install it with “brew install freerdp”, or choose an sdl-freerdp executable."
        case .invalidSetting(let message), .launchFailed(let message):
            message
        }
    }
}

enum FreeRDPSessionSurface: Equatable {
    case externalWindow
    case embedded(width: Int, height: Int)
}

struct FreeRDPArgumentsBuilder {
    static func arguments(
        for connection: RemoteConnection,
        password: String?,
        surface: FreeRDPSessionSurface = .externalWindow,
        displayScale: Int? = nil
    ) throws -> [String] {
        guard connection.kind == .rdp else {
            throw FreeRDPServiceError.invalidSetting("The selected connection is not an RDP connection.")
        }

        let host = clean(connection.host)
        var username = clean(connection.username).trimmingCharacters(in: .whitespacesAndNewlines)
        var domain = normalized(connection.rdpDomain)
        if let separator = username.firstIndex(of: "\\") {
            let embeddedDomain = String(username[..<separator])
            let accountStart = username.index(after: separator)
            let embeddedUsername = String(username[accountStart...])
            if !embeddedDomain.isEmpty, !embeddedUsername.isEmpty {
                username = embeddedUsername
                domain = domain ?? embeddedDomain
            }
        }
        guard !host.isEmpty else {
            throw FreeRDPServiceError.invalidSetting("Enter an RDP host name or address.")
        }

        let requestedScale = displayScale ?? connection.effectiveRDPScale
        let effectiveScale = [100, 140, 180].contains(requestedScale) ? requestedScale : 100

        var arguments = [
            "/v:\(host):\(connection.port)",
            "/network:\(connection.effectiveRDPNetworkProfile.rawValue)",
            "/scale:\(effectiveScale)",
            "+compression",
            "/compression-level:2",
            "+grab-keyboard",
            "/mouse:grab:on",
            "+multitouch",
            "/log-level:INFO",
        ]

        if !username.isEmpty { arguments.append("/u:\(username)") }
        if let password, !password.isEmpty { arguments.append("/p:\(clean(password))") }
        if let domain { arguments.append("/d:\(domain)") }

        switch surface {
        case .embedded(let width, let height):
            let embeddedWidth = min(max(width, 200), 8192) & ~1
            let embeddedHeight = min(max(height, 200), 8192) & ~1
            arguments += [
                "/size:\(embeddedWidth)x\(embeddedHeight)",
                "+dynamic-resolution",
            ]
        case .externalWindow:
            switch connection.effectiveRDPDisplayMode {
            case .dynamicWindow:
                arguments += [
                    "/size:\(connection.effectiveRDPWidth)x\(connection.effectiveRDPHeight)",
                    "+dynamic-resolution",
                ]
            case .fullscreen:
                arguments += ["/f", "/floatbar:sticky:on,default:hidden,show:fullscreen"]
            case .multiMonitor:
                arguments += ["/f", "/multimon:force", "/floatbar:sticky:on,default:hidden,show:fullscreen"]
            }
        }

        arguments.append(connection.effectiveRDPClipboard ? "+clipboard" : "-clipboard")

        switch connection.effectiveRDPAudioMode {
        case .local:
            arguments += ["/audio-mode:0", "/sound"]
        case .remote:
            arguments.append("/audio-mode:1")
        case .disabled:
            arguments.append("/audio-mode:2")
        }

        if connection.rdpMicrophone == true { arguments.append("/microphone") }
        if connection.rdpRedirectHome == true { arguments.append("+home-drive") }
        if let sharedFolder = normalized(connection.rdpSharedFolder) {
            guard !sharedFolder.contains(",") else {
                throw FreeRDPServiceError.invalidSetting("The shared-folder path cannot contain a comma.")
            }
            arguments.append("/drive:Nethriva,\(sharedFolder)")
        }
        if connection.rdpPrinters == true { arguments.append("/printer") }
        if connection.rdpSmartCards == true { arguments.append("/smartcard") }
        if connection.rdpUSBDevices == true { arguments.append("/usb:auto") }

        if connection.effectiveRDPGraphicsAcceleration {
            arguments += ["/bpp:32", "/gfx:AVC444:on", "/video"]
        } else {
            arguments += ["/bpp:24", "/gdi:sw"]
        }

        switch connection.effectiveRDPCertificatePolicy {
        case .trustOnFirstUse:
            arguments.append("/cert:tofu")
        case .systemValidation:
            arguments.append("/cert:deny")
        case .ignore:
            arguments.append("/cert:ignore")
        }

        if connection.rdpAdminSession == true { arguments.append("/admin") }
        if connection.effectiveRDPAutoReconnect {
            arguments += [
                "+auto-reconnect",
                "/auto-reconnect-max-retries:\(connection.effectiveRDPReconnectRetries)",
            ]
        }

        if let gatewayHost = normalized(connection.rdpGatewayHost) {
            var gatewayParts = ["g:\(gatewayHost)", "usage-method:direct"]
            if let gatewayUsername = normalized(connection.rdpGatewayUsername) {
                gatewayParts.insert("u:\(gatewayUsername)", at: 1)
            }
            arguments.append("/gateway:\(gatewayParts.joined(separator: ","))")
        }

        return arguments
    }

    static func redacted(_ arguments: [String]) -> [String] {
        arguments.map { argument in
            argument.hasPrefix("/p:") ? "/p:••••••••" : argument
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = clean(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}

final class FreeRDPRuntimeLocator {
    private static let preferenceKey = "freeRDPExecutablePath.v1"

    static func locate() -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("FreeRDP/MacOS")
        if let bundledRoot {
            candidates += [
                bundledRoot.appendingPathComponent("sdl-freerdp").path,
                bundledRoot.appendingPathComponent("sdl-freerdp3").path,
            ]
        }
        if let saved = UserDefaults.standard.string(forKey: preferenceKey) {
            candidates.append(saved)
        }
        candidates += [
            "/opt/homebrew/bin/sdl-freerdp",
            "/opt/homebrew/bin/sdl-freerdp3",
            "/usr/local/bin/sdl-freerdp",
            "/usr/local/bin/sdl-freerdp3",
        ]

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: preferenceKey)
    }
}

final class FreeRDPService {
    func launch(
        connection: RemoteConnection,
        password: String?,
        onOutput: @escaping (String) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws -> Process {
        guard let executable = FreeRDPRuntimeLocator.locate() else {
            throw FreeRDPServiceError.runtimeNotFound
        }

        let settings = try FreeRDPArgumentsBuilder.arguments(for: connection, password: password)
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["/args-from:stdin"]
        process.environment = Self.processEnvironment(for: executable)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            onOutput(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            onTermination(process.terminationStatus)
        }

        do {
            try process.run()
            let input = (settings.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
            return process
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw FreeRDPServiceError.launchFailed("Could not start FreeRDP: \(error.localizedDescription)")
        }
    }

    static func processEnvironment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let modulesDirectory = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks/ossl-modules", isDirectory: true)
        let legacyProvider = modulesDirectory.appendingPathComponent("legacy.dylib")

        if FileManager.default.fileExists(atPath: legacyProvider.path) {
            environment["OPENSSL_MODULES"] = modulesDirectory.path
        }
        return environment
    }
}
