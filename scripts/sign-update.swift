#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
let repository = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
func outsideRepository(_ path: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return resolved != repository.path && !resolved.hasPrefix(repository.path + "/")
}
// Explicit publisher operation only. App builds never generate private signing keys.
if args.count == 2 && args[0] == "--create-key" {
    guard outsideRepository(args[1]) else { fail("Private signing keys must be stored outside the source repository.") }
    let key = Curve25519.Signing.PrivateKey()
    let descriptor = open(args[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { fail("Choose a new private-key file outside the repository; existing files are never replaced.") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do { try file.write(contentsOf: key.rawRepresentation); try file.synchronize(); try file.close() }
    catch { fail("Could not save the private signing key.") }
    print("Publisher public key (base64): " + key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard args.count == 5 else { fail("Usage: swift scripts/sign-update.swift VERSION ARCH ZIP PRIVATE_KEY OUTPUT_DIR\nOr: --create-key /private/path/outside/repository") }
let version = args[0], architecture = args[1]
guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
      ["arm64", "x86_64", "universal"].contains(architecture) else { fail("Invalid version or architecture.") }
let zip = URL(fileURLWithPath: args[2]), keyURL = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
guard outsideRepository(keyURL.path) else { fail("Private signing keys must be stored outside the source repository.") }
let expectedName = "Nethriva-\(version)-macOS-\(architecture).zip"
guard zip.lastPathComponent == expectedName else { fail("ZIP filename does not match the version and architecture.") }
let keyDescriptor = open(keyURL.path, O_RDONLY | O_NOFOLLOW)
guard keyDescriptor >= 0 else { fail("Could not open a private, regular key file.") }
let keyFile = FileHandle(fileDescriptor: keyDescriptor, closeOnDealloc: true)
var info = stat()
guard fstat(keyDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_mode & 0o077 == 0, info.st_size == 32 else { fail("Private key must be a private, regular 32-byte file, not a symlink.") }
struct Manifest: Codable {
    var schema = 1; var version: String; var assets: [Asset]
    struct Asset: Codable { var architecture: String; var url: String; var sha256: String; var size: Int }
}
do {
    let data = try Data(contentsOf: zip, options: .mappedIfSafe)
    guard data.count > 0, data.count <= 512 * 1024 * 1024 else { fail("ZIP is empty or too large.") }
    let keyData = try keyFile.read(upToCount: 33) ?? Data(); try keyFile.close()
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let manifest = Manifest(version: version, assets: [.init(architecture: architecture,
        url: "https://github.com/vitalii-sharapov/Nethriva/releases/download/v\(version)/\(expectedName)", sha256: digest, size: data.count)])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(manifest), signature = try key.signature(for: payload)
    guard key.publicKey.isValidSignature(signature, for: payload) else { fail("Signature self-check failed.") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (name, bytes) in [("Nethriva-update.json", payload), ("Nethriva-update.sig", signature)] {
        let path = output.appendingPathComponent(name)
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { fail("Manifest output exists; choose a new output directory.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: bytes); try file.close()
    }
    print("Created and verified signed update files. No upload was performed.")
    print("Required NETHRIVA_UPDATE_PUBLIC_KEY: " + key.publicKey.rawRepresentation.base64EncodedString())
} catch { fail("Could not sign the update. Check input files and output directory.") }
