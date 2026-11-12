import AppKit
import Foundation
import SwiftTerm
import SwiftUI

struct TerminalAppearance: Codable, Hashable, Identifiable {
  enum Theme: String, Codable, CaseIterable { case midnight, light, green }
  enum Cursor: String, Codable, CaseIterable { case block, underline, bar }
  var id = UUID()
  var name = "New Profile"
  var fontName = "Menlo"
  var fontSize = 13.0
  var theme: Theme = .midnight
  var cursor: Cursor = .block
  var scrollback = 5000
  static let standard = TerminalAppearance(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!, name: "Default")
  func validate() throws {
    guard !name.isEmpty, name.count <= 200, fontName.count <= 100, (9...32).contains(fontSize),
      (100...10000).contains(scrollback)
    else {
      throw WorkflowError.invalid(
        "Invalid terminal profile. Use 9–32 pt and 100–10,000 scrollback lines.")
    }
  }
  var options: TerminalOptions {
    TerminalOptions(
      cursorStyle: cursor == .bar
        ? .steadyBar : cursor == .underline ? .steadyUnderline : .steadyBlock,
      scrollback: scrollback)
  }
  @MainActor func apply(_ terminal: TerminalView) {
    terminal.font =
      NSFont(name: fontName, size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    terminal.nativeBackgroundColor =
      theme == .light ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.055, alpha: 1)
    terminal.nativeForegroundColor =
      theme == .light
      ? .black
      : theme == .green
        ? NSColor(calibratedRed: 0.45, green: 0.95, blue: 0.55, alpha: 1)
        : NSColor(white: 0.90, alpha: 1)
  }
}

private struct AppearanceKey: EnvironmentKey {
  static let defaultValue = TerminalAppearance.standard
}
private struct TerminalToolsKey: EnvironmentKey {
  static let defaultValue: TerminalExperience? = nil
}
extension EnvironmentValues {
  var terminalAppearance: TerminalAppearance {
    get { self[AppearanceKey.self] }
    set { self[AppearanceKey.self] = newValue }
  }
  var terminalExperience: TerminalExperience? {
    get { self[TerminalToolsKey.self] }
    set { self[TerminalToolsKey.self] = newValue }
  }
}

/// Streaming, bounded plain-text lines. Never writes raw ANSI/OSC sequences or
/// partial lines: a credential label split over reads must still be detected.
struct TerminalLogFilter {
  private enum Escape { case none, esc, csi, string, stringEsc }
  private var escape: Escape = .none
  private var bytes: [UInt8] = []
  private var overflow = false
  private static let sensitive = try! NSRegularExpression(
    pattern:
      "(?i)(password|passphrase|secret|token|authorization|credential|private[ -]?key|login:|username:)"
  )
  mutating func consume(_ input: ArraySlice<UInt8>) -> [String] {
    var lines: [String] = []
    for byte in input {
      switch escape {
      case .esc:
        if byte == 91 {
          escape = .csi
        } else if [93, 80, 94, 95].contains(byte) {
          escape = .string
        } else {
          escape = .none
        }
        continue
      case .csi:
        if (64...126).contains(byte) { escape = .none }
        continue
      case .string:
        if byte == 7 { escape = .none } else if byte == 27 { escape = .stringEsc }
        continue
      case .stringEsc:
        escape = byte == 92 ? .none : .string
        continue
      case .none: break
      }
      if byte == 27 {
        escape = .esc
        continue
      }
      if byte == 10 {
        let text = String(decoding: bytes, as: UTF8.self)
        let sensitive =
          Self.sensitive.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        lines.append(
          overflow ? "[oversized output omitted]" : sensitive ? "[sensitive output omitted]" : text)
        bytes.removeAll(keepingCapacity: true)
        overflow = false
      } else if byte == 13 { /* keep entire overwritten line for conservative redaction */
      } else if byte == 9 || byte >= 32 {
        if bytes.count < 16384 { bytes.append(byte) } else { overflow = true }
      }
    }
    return lines
  }
}

/// All file work is on one worker queue; UI/terminal callbacks never wait for disk.
final class TerminalLogWriter: @unchecked Sendable {
  let url: URL?
  private let queue = DispatchQueue(label: "com.vitalii.nethriva.session-log", qos: .utility)
  private let lock = NSLock()
  private var pending = 0
  private var accepting = true
  private var handle: FileHandle?
  private var filter = TerminalLogFilter()
  private var size = 0
  var onFailure: (() -> Void)?
  init(url: URL) throws {
    self.url = url
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw WorkflowError.invalid("Could not create a private session log.")
    }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }
  func append(_ bytes: ArraySlice<UInt8>, date: Date = Date()) {
    lock.lock()
    guard accepting, pending < 32, bytes.count <= 65536 else {
      let failed = accepting
      accepting = false
      lock.unlock()
      if failed {
        queue.async {
          self.finish()
          self.onFailure?()
        }
      }
      return
    }
    pending += 1
    lock.unlock()
    let owned = Array(bytes)
    queue.async {
      defer {
        self.lock.lock()
        self.pending -= 1
        self.lock.unlock()
      }
      guard let handle = self.handle else { return }
      let stamp = ISO8601DateFormatter().string(from: date)
      let lines = self.filter.consume(owned[...])
      guard !lines.isEmpty else { return }
      let data = Data((lines.map { "[\(stamp)] \($0)" }.joined(separator: "\n") + "\n").utf8)
      do {
        guard self.size + data.count <= 8 * 1024 * 1024 else {
          throw WorkflowError.invalid("Log size limit reached.")
        }
        try handle.write(contentsOf: data)
        self.size += data.count
      } catch {
        self.finish()
        self.onFailure?()
      }
    }
  }
  func stop() {
    lock.lock()
    accepting = false
    lock.unlock()
    queue.async { self.finish() }
  }
  func waitForPendingWrites() async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  }
  private func finish() {
    try? handle?.close()
    handle = nil
  }
  deinit { try? handle?.close() }
}

@MainActor
final class TerminalExperience: ObservableObject {
  struct Registration {
    weak var view: TerminalView?
    let generation: UUID
  }
  @Published private(set) var recording = Set<UUID>()
  @Published private(set) var notice: String?
  private var terminals: [UUID: Registration] = [:]
  private var writers: [UUID: TerminalLogWriter] = [:]
  private var requests: [UUID: UUID] = [:]
  let root: URL
  init(root: URL? = nil) {
    let profile =
      NethrivaDataProfile.isTesting
      ? "NethrivaTests-\(ProcessInfo.processInfo.processIdentifier)"
      : NethrivaDataProfile.isDevelopment ? "NethrivaDevelopment" : "Nethriva"
    self.root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(profile).appendingPathComponent("SessionLogs", isDirectory: true)
  }
  @discardableResult
  func register(_ view: TerminalView, id: UUID?) -> UUID {
    let generation = UUID()
    if let id {
      stop(id)
      terminals[id] = Registration(view: view, generation: generation)
    }
    return generation
  }
  func unregister(_ id: UUID?, generation: UUID) {
    guard let id, terminals[id]?.generation == generation else { return }
    stop(id)
    terminals[id] = nil
  }
  func output(_ bytes: ArraySlice<UInt8>, id: UUID?, generation: UUID) {
    guard let id, terminals[id]?.generation == generation else { return }
    writers[id]?.append(bytes)
  }
  func start(_ id: UUID, retentionDays: Int) async throws {
    guard let registration = terminals[id], registration.view != nil else {
      throw WorkflowError.invalid("This terminal is no longer available.")
    }
    guard !recording.contains(id) else { return }
    let request = UUID()
    requests[id] = request
    let root = root
    let active = Set(writers.values.compactMap { $0.url })
    let writer = try await BackgroundWork.run {
      try Self.prepareDirectory(root)
      try Self.prune(root: root, retentionDays: retentionDays, active: active)
      return try TerminalLogWriter(
        url: root.appendingPathComponent("session-\(UUID().uuidString).log"))
    }
    guard requests[id] == request, terminals[id]?.generation == registration.generation else {
      writer.stop()
      return
    }
    writer.onFailure = { [weak self, weak writer] in
      Task { @MainActor in
        guard let self, let writer, self.writers[id] === writer else { return }
        self.stop(id)
        self.notice = "Recording stopped: the private log limit or disk operation failed."
      }
    }
    writers[id] = writer
    recording.insert(id)
  }
  func stop(_ id: UUID) {
    requests[id] = nil
    writers.removeValue(forKey: id)?.stop()
    recording.remove(id)
  }
  func authenticationPrompt(_ id: UUID, generation: UUID) {
    guard terminals[id]?.generation == generation, recording.contains(id) else { return }
    stop(id)
    notice =
      "Recording stopped at a detected credential prompt. Restart recording explicitly after authentication."
  }
  func close(_ id: UUID) {
    stop(id)
    terminals[id] = nil
  }
  nonisolated private static func prepareDirectory(_ root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attrs = try fm.attributesOfItem(atPath: root.path)
    guard attrs[.type] as? FileAttributeType == .typeDirectory,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw WorkflowError.invalid("The log folder is not a private owned directory.") }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  }
  func prune(retentionDays: Int, now: Date = Date()) async throws {
    let root = root
    let active = Set(writers.values.compactMap { $0.url })
    try await BackgroundWork.run {
      try Self.prune(root: root, retentionDays: retentionDays, active: active, now: now)
    }
  }
  nonisolated private static func prune(
    root: URL, retentionDays: Int, active: Set<URL>, now: Date = Date()
  ) throws {
    guard (1...90).contains(retentionDays) else {
      throw WorkflowError.invalid("Choose 1–90 retention days.")
    }
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.path) else { return }
    let rootAttributes = try fm.attributesOfItem(atPath: root.path)
    guard rootAttributes[.type] as? FileAttributeType == .typeDirectory,
      (rootAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw WorkflowError.invalid("Cannot clean an unowned log directory.") }
    for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard !active.contains(url) else { continue }
      let name = url.lastPathComponent
      guard name.hasPrefix("session-"), name.hasSuffix(".log"),
        UUID(uuidString: String(name.dropFirst(8).dropLast(4))) != nil
      else { continue }
      let attrs = try fm.attributesOfItem(atPath: url.path)
      guard attrs[.type] as? FileAttributeType == .typeRegular,
        (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
        let modified = attrs[.modificationDate] as? Date,
        modified < now.addingTimeInterval(-Double(retentionDays) * 86400)
      else { continue }
      try fm.removeItem(at: url)
    }
  }
  func snapshot(_ id: UUID) -> String {
    guard let view = terminals[id]?.view,
      let anchor = view.terminalContentSnapshot(region: .rows(0..<0)) else { return "" }
    var text = ""
    var size = 0
    let start = max(0, anchor.liveTopRow - 10000)
    let end = anchor.liveTopRow + anchor.dimensions.rows
    for offset in stride(from: start, to: end, by: 64) {
      guard let batch = view.terminalContentSnapshot(region: .rows(offset..<min(end, offset + 64))) else { break }
      for row in batch.rows {
        let next = row.text + "\n"
        size += next.utf8.count
        guard size <= 2 * 1024 * 1024 else { return text }
        text += next
      }
    }
    return text
  }
}

@MainActor
final class TerminalCapture {
  private weak var experience: TerminalExperience?
  private let id: UUID?
  private let generation: UUID?
  private var promptTail = ""
  init(view: TerminalView, id: UUID?, experience: TerminalExperience?) {
    self.experience = experience
    self.id = id
    generation = experience?.register(view, id: id)
    if let local = view as? PasteableLocalProcessTerminalView {
      local.outputObserver = { [weak self] in self?.output($0) }
    }
  }
  func output(_ bytes: ArraySlice<UInt8>) {
    promptTail = String(
      (promptTail + String(decoding: bytes.suffix(512), as: UTF8.self)).suffix(512))
    if let id, let generation,
      ["password:", "passphrase", "verification code:", "token:", "login:", "username:"].contains(
        where: { promptTail.localizedCaseInsensitiveContains($0) })
    {
      experience?.authenticationPrompt(id, generation: generation)
      promptTail = ""
    }
    if let generation { experience?.output(bytes, id: id, generation: generation) }
  }
  func close() { if let generation { experience?.unregister(id, generation: generation) } }
}

struct TerminalSessionTools: View {
  let id: UUID
  @ObservedObject var experience: TerminalExperience
  @ObservedObject var library: LibraryTools
  @State private var showSearch = false
  @State private var search = ""
  @State private var snapshot = ""
  @State private var snapshotVersion = UUID()
  @State private var searchResults = "Type a search term to list matching lines."
  @State private var confirmRecording = false
  @State private var error: String?
  var body: some View {
    HStack(spacing: 12) {
      Button {
        snapshot = experience.snapshot(id)
        snapshotVersion = UUID()
        showSearch = true
      } label: {
        Label("Find Output", systemImage: "magnifyingglass")
      }
      Spacer()
      if let notice = experience.notice {
        Label("Log warning", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(
          notice)
      }
      if experience.recording.contains(id) {
        Label("Recording output", systemImage: "record.circle.fill").foregroundStyle(.red)
        Button("Stop Recording") { experience.stop(id) }
      } else {
        Button("Record Output…") { confirmRecording = true }
      }
    }.font(.caption).controlSize(.mini).padding(.horizontal, 10).frame(height: 26).background(.bar)
      .confirmationDialog(
        "Record this terminal’s future output?", isPresented: $confirmRecording,
        titleVisibility: .visible
      ) {
        Button("Start Recording") {
          Task { @MainActor in
            do { try await experience.start(id, retentionDays: library.data.retentionDays) } catch {
              self.error = error.localizedDescription
            }
          }
        }
      } message: {
        Text(
          "Output may expose private data or echoed commands. Input is not recorded directly. Sensitive labels and terminal control sequences are filtered, but redaction cannot guarantee secrecy. Logs stay on this Mac; recording never starts automatically. Avoid commands that print credentials."
            + " Starting also permanently removes expired app-owned logs under the \(library.data.retentionDays)-day retention policy."
        )
      }
      .sheet(isPresented: $showSearch) {
        VStack(alignment: .leading) {
          HStack {
            Text("Search Terminal Output").font(.headline)
            Spacer()
            Button("Refresh") {
              snapshot = experience.snapshot(id)
              snapshotVersion = UUID()
            }
            Button("Done") {
              showSearch = false
              snapshot = ""
              searchResults = ""
            }
          }
          TextField("Find in this scrollback snapshot", text: $search)
          Text("Read-only, in-memory snapshot. Up to 2 MiB; screen programs may overwrite output.")
            .font(.caption).foregroundStyle(.secondary)
          ScrollView {
            Text(searchResults).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }.padding().frame(width: 720, height: 500)
          .task(id: SearchKey(query: search, version: snapshotVersion)) {
            let query = String(search.prefix(1024))
            let text = snapshot
            do {
              try await Task.sleep(for: .milliseconds(150))
              let result = try await BackgroundWork.run {
                TerminalOutputSearch.matches(text, query: query)
              }
              if !Task.isCancelled { searchResults = result }
            } catch {}
          }
      }
      .alert(
        "Terminal tools",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK") { error = nil }
      } message: {
        Text(error ?? "")
      }
  }
  private struct SearchKey: Hashable {
    let query: String
    let version: UUID
  }
}

enum TerminalOutputSearch {
  static func matches(_ snapshot: String, query: String) -> String {
    guard !query.isEmpty else { return "Type a search term to list matching lines." }
    let matches = snapshot.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
      .lazy.filter { $0.element.localizedCaseInsensitiveContains(query) }.prefix(500).map {
        "\($0.offset + 1): \($0.element)"
      }.joined(separator: "\n")
    return matches.isEmpty ? "No matching output." : matches
  }
}
