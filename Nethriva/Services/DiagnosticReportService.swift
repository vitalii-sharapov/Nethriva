import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticReportService {
    @MainActor
    static func export(connections: [RemoteConnection]) throws {
        let panel = NSSavePanel()
        panel.title = "Export Redacted Diagnostics"
        panel.nameFieldStringValue = "Nethriva-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try makeReport(connections: connections).write(to: url, atomically: true, encoding: .utf8)
    }

    static func makeReport(
        connections: [RemoteConnection],
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let counts = Dictionary(grouping: connections, by: \.kind).mapValues(\.count)
        let runtimePresent = bundle.resourceURL
            .map {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(
                        "FreeRDP/Frameworks/libNethrivaRDP.dylib"
                    ).path
                )
            } ?? false

        return """
        Nethriva Redacted Diagnostic Report
        Generated: \(ISO8601DateFormatter().string(from: Date()))

        Application version: \(version) (\(build))
        macOS: \(processInfo.operatingSystemVersionString)
        Architecture: \(architectureName)
        Processor count: \(processInfo.processorCount)
        Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(processInfo.physicalMemory), countStyle: .memory))

        Saved connection counts
        Local: \(counts[.localShell, default: 0])
        SSH: \(counts[.ssh, default: 0])
        Telnet: \(counts[.telnet, default: 0])
        RDP: \(counts[.rdp, default: 0])

        Bundled RDP bridge present: \(runtimePresent ? "Yes" : "No")
        SSH client present: \(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") ? "Yes" : "No")
        SFTP client present: \(FileManager.default.isExecutableFile(atPath: "/usr/bin/sftp") ? "Yes" : "No")

        Privacy
        This report intentionally excludes connection names, groups, usernames,
        hostnames, addresses, ports, passwords, keys, paths, clipboard contents,
        session output, and application logs.
        """
    }

    private static var architectureName: String {
#if arch(arm64)
        "Apple silicon (arm64)"
#elseif arch(x86_64)
        "Intel (x86_64)"
#else
        "Unknown"
#endif
    }
}
