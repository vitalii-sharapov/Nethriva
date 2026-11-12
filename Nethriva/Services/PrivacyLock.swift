import AppKit
import LocalAuthentication
import SwiftUI

enum PrivacyError: LocalizedError {
  case locked
  var errorDescription: String? {
    "Nethriva is locked. Unlock it with Touch ID or your Mac login password first."
  }
}

/// Synchronous secret boundaries share this gate, including background Keychain calls.
final class CredentialAccessGate: @unchecked Sendable {
  static let shared = CredentialAccessGate()
  private let mutex = NSLock()
  private var locked = false
  private var revision = UUID()
  var isLocked: Bool {
    mutex.lock()
    defer { mutex.unlock() }
    return locked
  }
  func setLocked(_ value: Bool) {
    mutex.lock()
    defer { mutex.unlock() }
    locked = value
    revision = UUID()
  }
  func check() throws -> UUID {
    mutex.lock()
    defer { mutex.unlock() }
    guard !locked else { throw PrivacyError.locked }
    return revision
  }
  func check(_ epoch: UUID) throws {
    mutex.lock()
    defer { mutex.unlock() }
    guard !locked, revision == epoch else { throw PrivacyError.locked }
  }
}

struct GatedCredentialVault: CredentialVault {
  let base: CredentialVault
  let gate: CredentialAccessGate
  func password(for id: UUID) throws -> String? {
    let epoch = try gate.check()
    let value = try base.password(for: id)
    try gate.check(epoch)
    return value
  }
  func containsPassword(for id: UUID) throws -> Bool {
    let epoch = try gate.check()
    let value = try base.containsPassword(for: id)
    try gate.check(epoch)
    return value
  }
  func save(password: String, for id: UUID) throws {
    _ = try gate.check()
    try base.save(password: password, for: id)
  }
  func deletePassword(for id: UUID) throws {
    _ = try gate.check()
    try base.deletePassword(for: id)
  }
}

@MainActor
protocol DeviceAuthenticating: AnyObject {
  func authenticate(_ completion: @escaping (Bool) -> Void)
  func cancel()
}
@MainActor
final class MacDeviceAuthentication: DeviceAuthenticating {
  private var context: LAContext?
  func authenticate(_ completion: @escaping (Bool) -> Void) {
    let context = LAContext()
    self.context = context
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      completion(false)
      return
    }
    context.evaluatePolicy(
      .deviceOwnerAuthentication,
      localizedReason: "Unlock Nethriva and access your connection library"
    ) { success, _ in
      DispatchQueue.main.async { completion(success) }
    }
  }
  func cancel() {
    context?.invalidate()
    context = nil
  }
}

@MainActor
final class PrivacyLock: ObservableObject {
  static let shared = PrivacyLock()
  @Published private(set) var isLocked = false
  @Published private(set) var authenticating = false
  @Published private(set) var message: String?
  @Published var lockOnSleep: Bool {
    didSet { defaults.set(lockOnSleep, forKey: "privacy.lockOnSleep") }
  }
  @Published var idleMinutes: Int {
    didSet { defaults.set(idleMinutes, forKey: "privacy.idleMinutes") }
  }
  let gate: CredentialAccessGate
  private let defaults: UserDefaults
  private let authentication: any DeviceAuthenticating
  private let protectWindows: Bool
  private var attempt = UUID()
  private var monitors: [NSObjectProtocol] = []
  private var eventMonitor: Any?
  private var timer: Timer?
  private var lastActivity = Date()
  var onLock: (() -> Void)?
  var onCleanup: (() async -> Void)?
  private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
  var shutdownPending: Bool { !cleanupTasks.isEmpty }
  private var shields: [Int: WindowPrivacyShield] = [:]

  init(
    defaults: UserDefaults = NethrivaDataProfile.defaults, gate: CredentialAccessGate = .shared,
    authentication: (any DeviceAuthenticating)? = nil, protectWindows: Bool = true
  ) {
    self.defaults = defaults
    self.gate = gate
    self.authentication = authentication ?? MacDeviceAuthentication()
    self.protectWindows = protectWindows
    lockOnSleep = defaults.bool(forKey: "privacy.lockOnSleep")
    let idle = defaults.integer(forKey: "privacy.idleMinutes")
    idleMinutes = [0, 5, 15, 30, 60].contains(idle) ? idle : 0
    isLocked = defaults.bool(forKey: "privacy.isLocked")
    if isLocked { gate.setLocked(true) }
  }
  func install() {
    guard timer == nil else { return }
    monitors.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in if self?.lockOnSleep == true { self?.lock() } }
      })
    monitors.append(
      DistributedNotificationCenter.default().addObserver(
        forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in if self?.lockOnSleep == true { self?.lock() } }
      })
    monitors.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.shieldWindows() }
      })
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
    ]) { [weak self] event in
      guard let self else { return event }
      if isLocked {
        shieldWindows()
        if event.type == .keyDown, event.modifierFlags.contains(.command),
          ["q", "w"].contains(event.charactersIgnoringModifiers ?? "")
        {
          return event
        }
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 {
          unlock(); return nil
        }
        guard let window = event.window, let shield = shields[window.windowNumber],
          event.type == .leftMouseDown || event.type == .leftMouseUp
        else { return nil }
        let point = shield.convert(event.locationInWindow, from: nil)
        return shield.hitTest(point) != nil ? event : nil
      }
      lastActivity = Date()
      return event
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if self.isLocked {
          self.shieldWindows()
        } else if self.idleMinutes > 0,
          Date().timeIntervalSince(self.lastActivity) >= Double(self.idleMinutes * 60)
        {
          self.lock()
        }
      }
    }
  }
  func lock() {
    attempt = UUID()
    authentication.cancel()
    authenticating = false
    gate.setLocked(true)
    isLocked = true
    defaults.set(true, forKey: "privacy.isLocked")
    message = nil
    // Put the privacy boundary in place synchronously, before closing any
    // protocol view can surface an error/dialog or application notification.
    shieldWindows()
    onLock?()
    shieldWindows()
    if let onCleanup {
      let id = UUID()
      cleanupTasks[id] = Task {
        await onCleanup()
        cleanupTasks[id] = nil
        if cleanupTasks.isEmpty {
          message = nil
          shieldWindows()
        }
      }
    }
  }
  func unlock() {
    guard isLocked, !authenticating else { return }
    guard cleanupTasks.isEmpty else {
      message = "Finishing session shutdown. Try unlocking again shortly."
      shieldWindows()
      return
    }
    let id = UUID()
    attempt = id
    authenticating = true
    message = nil
    shieldWindows()
    authentication.authenticate { [weak self] success in
      self?.completeAuthentication(success: success, attempt: id)
    }
  }
  // Testable completion boundary: an old/cancelled authentication cannot unlock a newer lock.
  func completeAuthentication(success: Bool, attempt id: UUID) {
    guard id == attempt, isLocked else { return }
    authenticating = false
    authentication.cancel()
    guard success else {
      message = "Not unlocked. Try Touch ID or your Mac login password again."
      shieldWindows()
      return
    }
    gate.setLocked(false)
    isLocked = false
    defaults.set(false, forKey: "privacy.isLocked")
    lastActivity = Date()
    shields.values.forEach { $0.restore() }
    shields.removeAll()
    message = nil
  }
  func shieldWindows() {
    guard isLocked, protectWindows else { return }
    for window in NSApp.windows where window.contentView != nil {
      if shields[window.windowNumber] == nil {
        let shield = WindowPrivacyShield(window: window, owner: self)
        shields[window.windowNumber] = shield
      }
      shields[window.windowNumber]?.cover()
    }
    for key in Array(shields.keys) where shields[key]?.window == nil { shields[key] = nil }
  }
}

/// A native sibling sits above ALL hosting surfaces (including detached ones).
/// Hiding the covered views also removes their accessibility content.
@MainActor
private final class WindowPrivacyShield: NSView {
  private weak var owner: PrivacyLock?
  private weak var protectedWindow: NSWindow?
  private var covered: [(NSView, Bool)] = []
  private let oldTitle: String
  private let oldURL: URL?
  private let status = NSTextField(wrappingLabelWithString: "")
  init(window: NSWindow, owner: PrivacyLock) {
    self.owner = owner
    protectedWindow = window
    oldTitle = window.title
    oldURL = window.representedURL
    super.init(frame: window.contentView?.bounds ?? .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    autoresizingMask = [.width, .height]
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 16
    let title = NSTextField(labelWithString: "Nethriva is locked")
    title.font = .boldSystemFont(ofSize: 22)
    let explanation = NSTextField(
      wrappingLabelWithString:
        "Sessions were disconnected for privacy. Your saved connections and credentials are unchanged."
    )
    explanation.alignment = .center
    let button = NSButton(
      title: "Unlock with Touch ID or Mac Password", target: self, action: #selector(unlock))
    button.keyEquivalent = "\r"
    button.setAccessibilityLabel("Unlock Nethriva with Touch ID or Mac login password")
    stack.addArrangedSubview(title)
    stack.addArrangedSubview(explanation)
    stack.addArrangedSubview(button)
    status.alignment = .center
    status.font = .systemFont(ofSize: 12)
    stack.addArrangedSubview(status)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
    ])
  }
  required init?(coder: NSCoder) { fatalError("Not used") }
  @objc private func unlock() { owner?.unlock() }
  func cover() {
    guard let window = protectedWindow, var content = window.contentView else { return }
    // Auxiliary SwiftUI windows may use a hosting view directly as contentView.
    // Add the shield beside that view in plain AppKit—not inside its managed graph.
    if !content.isMember(of: NSView.self) {
      let hosted = content
      let container = NSView(frame: hosted.frame)
      window.contentView = container
      hosted.frame = container.bounds
      hosted.autoresizingMask = [.width, .height]
      container.addSubview(hosted)
      content = container
    }
    if superview !== content {
      removeFromSuperview()
      content.addSubview(self, positioned: .above, relativeTo: nil)
    }
    for view in content.subviews where view !== self {
      if !covered.contains(where: { $0.0 === view }) { covered.append((view, view.isHidden)) }
      view.isHidden = true
    }
    status.stringValue =
      owner?.message ?? (owner?.authenticating == true ? "Waiting for Mac authentication…" : "")
    frame = content.bounds
    isHidden = false
    window.title = "Nethriva — Locked"
    window.representedURL = nil
    window.makeFirstResponder(nil)
  }
  func restore() {
    covered.forEach { $0.0.isHidden = $0.1 }
    covered.removeAll()
    protectedWindow?.title = oldTitle
    protectedWindow?.representedURL = oldURL
    removeFromSuperview()
  }
}

/// Conceals non-session SwiftUI windows from their very first frame, including
/// restored windows on a launch that is still locked. Native shields handle
/// sibling protocol surfaces and existing AppKit editor/dialog windows.
struct PrivacyProtectedView: ViewModifier {
  @ObservedObject var privacy: PrivacyLock
  func body(content: Content) -> some View {
    content.opacity(privacy.isLocked ? 0 : 1)
      .disabled(privacy.isLocked).allowsHitTesting(!privacy.isLocked).accessibilityHidden(
        privacy.isLocked
      )
      .overlay {
        if privacy.isLocked {
          VStack(spacing: 14) {
            Text("Nethriva is locked").font(.title2.bold())
            Button("Unlock with Touch ID or Mac Password") { privacy.unlock() }
          }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
        }
      }
  }
}
