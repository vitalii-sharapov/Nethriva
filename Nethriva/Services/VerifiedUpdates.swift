import AppKit
import CryptoKit
import CoreServices
import Foundation
import SwiftUI

enum UpdateValidation {
    static let releasesURL = URL(string: "https://github.com/vitalii-sharapov/Nethriva/releases")!
    static let apiURL = URL(string: "https://api.github.com/repos/vitalii-sharapov/Nethriva/releases/latest")!
    static func version(_ value: String) -> [Int]? {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { "0123456789".contains($0) } }) else { return nil }
        return pieces.compactMap { Int($0) }
    }
    static func newer(_ offered: String, than installed: String) -> Bool {
        guard let lhs = version(offered), let rhs = version(installed) else { return false }
        return lhs.lexicographicallyPrecedes(rhs) == false && lhs != rhs
    }
    static func assetURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.hasPrefix("/vitalii-sharapov/Nethriva/releases/download/"),
              !parts.path.contains(".."), !parts.path.contains("%") else { return nil }
        return parts.url
    }
    static func verify(_ payload: Data, signature: Data, publicKey: Data) throws -> UpdateManifest {
        guard payload.count < 64 * 1024, signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { throw UpdateError.signature }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        guard manifest.schema == 1, version(manifest.version) != nil, (1...4).contains(manifest.assets.count),
              Set(manifest.assets.map(\.architecture)).count == manifest.assets.count,
              manifest.assets.allSatisfy({ ["arm64", "x86_64", "universal"].contains($0.architecture)
                && assetURL($0.url) != nil && $0.url.hasSuffix(".zip") && $0.size > 0 && $0.size <= 512 * 1024 * 1024
                && $0.sha256.count == 64 && $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } }) else { throw UpdateError.manifest }
        return manifest
    }
}

struct UpdateManifest: Codable, Equatable {
    var schema: Int
    var version: String
    var assets: [Asset]
    struct Asset: Codable, Equatable {
        var architecture: String
        var url: String
        var sha256: String
        var size: Int
    }
}

enum UpdateError: LocalizedError {
    case signature, manifest, transport, checksum, notConfigured
    var errorDescription: String? {
        switch self {
        case .signature: "The update manifest signature could not be verified. Nothing was installed."
        case .manifest: "The update manifest is invalid or does not match this release."
        case .transport: "Could not retrieve the update securely. Open the official releases page to check manually."
        case .checksum: "The download does not match its signed checksum or size. It was discarded."
        case .notConfigured: "This build has no publisher update-verification key. Verified downloads are disabled; use the official releases page."
        }
    }
}

enum UpdateArchiveWriter {
    static func write(_ data: Data, to destination: URL, source: URL) throws {
        guard UpdateValidation.assetURL(source.absoluteString) != nil else { throw UpdateError.transport }
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw UpdateError.transport }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            // Byte-stream downloads do not reliably acquire quarantine automatically.
            // Set it explicitly; a download must not bypass the user's normal launch approval.
            let quarantine: [String: Any] = [kLSQuarantineAgentNameKey as String: "Nethriva",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                kLSQuarantineDataURLKey as String: source,
                kLSQuarantineOriginURLKey as String: UpdateValidation.releasesURL]
            try (destination as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
        } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: destination)
            throw UpdateError.transport
        }
    }
}

/// Only public GitHub release data, never account authentication, cookies or local diagnostics.
final class UpdateTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let hosts = ["release-assets.githubusercontent.com", "objects.githubusercontent.com", "github.com"]
        guard url?.scheme == "https", let host = url?.host, hosts.contains(host), url?.user == nil, url?.password == nil,
              request.httpMethod == "GET" else { completionHandler(nil); return }
        var safe = URLRequest(url: url!); safe.httpMethod = "GET"
        completionHandler(safe)
    }
    func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard url == UpdateValidation.apiURL || UpdateValidation.assetURL(url.absoluteString) != nil else { throw UpdateError.transport }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Int64(limit) else { throw UpdateError.transport }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw UpdateError.transport }
                data.append(byte)
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw UpdateError.transport }
    }
}

@MainActor
final class VerifiedUpdates: ObservableObject {
    @Published var status = "Updates are checked only when you choose Check. No automatic installation."
    @Published var busy = false
    @Published var asset: UpdateManifest.Asset?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private let publicKey: Data?
    private let installed: String
    init(bundle: Bundle = .main) {
        publicKey = (bundle.object(forInfoDictionaryKey: "NethrivaUpdatePublicKey") as? String).flatMap { Data(base64Encoded: $0) }
        installed = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    func check() {
        guard !busy else { return }
        busy = true; asset = nil; status = "Checking the official GitHub release…"
        let generation = generation
        work = Task {
            defer { if self.generation == generation { busy = false } }
            do {
                let transport = UpdateTransport()
                let data = try await transport.fetch(UpdateValidation.apiURL, limit: 1024 * 1024)
                guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      release["draft"] as? Bool == false, release["prerelease"] as? Bool == false,
                      let version = release["tag_name"] as? String, UpdateValidation.version(version) != nil else { throw UpdateError.manifest }
                guard UpdateValidation.newer(version, than: installed) else { status = "No newer stable release than \(installed) was found."; return }
                guard let publicKey, publicKey.count == 32 else { throw UpdateError.notConfigured }
                let assets = release["assets"] as? [[String: Any]] ?? []
                func url(_ name: String) throws -> URL {
                    guard let value = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String,
                          let url = UpdateValidation.assetURL(value) else { throw UpdateError.manifest }
                    return url
                }
                let manifest = try await transport.fetch(url("Nethriva-update.json"), limit: 64 * 1024)
                let signature = try await transport.fetch(url("Nethriva-update.sig"), limit: 64)
                let signed = try UpdateValidation.verify(manifest, signature: signature, publicKey: publicKey)
                guard UpdateValidation.version(signed.version) == UpdateValidation.version(version), UpdateValidation.newer(signed.version, than: installed),
                      let asset = signed.assets.first(where: { $0.architecture == RDPRuntimeArchitecture.current }) ?? signed.assets.first(where: { $0.architecture == "universal" }) else { throw UpdateError.manifest }
                try Task.checkCancellation(); guard self.generation == generation else { return }
                self.asset = asset; status = "Verified release \(signed.version) is available. Download is optional; installation is manual."
            } catch { if self.generation == generation, !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    func download() {
        guard !busy, let asset, let url = UpdateValidation.assetURL(asset.url) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Avoid replacing an existing archive, even if NSSavePanel offered replacement.
        guard !FileManager.default.fileExists(atPath: destination.path) else { status = "Choose a new filename; existing files will not be overwritten."; return }
        busy = true; status = "Downloading and checking the signed checksum…"
        let generation = generation
        work = Task {
            defer { if self.generation == generation { busy = false } }
            do {
                let data = try await UpdateTransport().fetch(url, limit: asset.size)
                try Task.checkCancellation(); guard self.generation == generation else { return }
                let digest = try await BackgroundWork.run { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
                guard data.count == asset.size, digest == asset.sha256 else { throw UpdateError.checksum }
                try await BackgroundWork.run {
                    try UpdateArchiveWriter.write(data, to: destination, source: url)
                }
                try Task.checkCancellation(); guard self.generation == generation else { return }
                status = "Verified archive saved. Extract it and replace Nethriva manually. This does not provide Apple notarization; macOS security checks still apply."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { if self.generation == generation, !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    func cancel() { generation = UUID(); work?.cancel(); work = nil; busy = false; asset = nil; status = "Update check cancelled." }
}

struct VerifiedUpdatesView: View {
    @StateObject private var updates = VerifiedUpdates()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nethriva Updates").font(.title2)
            Text(updates.status).textSelection(.enabled)
            Text("Verified downloads require a publisher-signed Ed25519 manifest and its public key in this build. They do not bypass Gatekeeper, remove quarantine, change credentials or install automatically.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Check") { updates.check() }.disabled(updates.busy)
                Button("Download Verified ZIP…") { updates.download() }.disabled(updates.busy || updates.asset == nil)
                if updates.busy { ProgressView().controlSize(.small); Button("Cancel") { updates.cancel() } }
                Link("Official Releases", destination: UpdateValidation.releasesURL)
            }
        }.padding(24).frame(width: 620).onDisappear { updates.cancel() }
    }
}
