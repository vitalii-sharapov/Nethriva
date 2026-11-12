import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  fileprivate static let nethrivaSharedLibrary = UTType(
    exportedAs: "com.vitalii.nethriva.shared-library", conformingTo: .json)
}

struct SharedLibrariesView: View {
  @EnvironmentObject private var state: AppState
  @ObservedObject var library: SharedLibraries
  @State private var selected = Set<UUID>()
  @State private var name = "Shared Connections"
  @State private var includeEmptyGroups = false
  @State private var review: SharedLibraryReview?
  @State private var publication: SharedLibraryPublication?
  @State private var busy = false
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Shared Connection Libraries").font(.title2.bold())
      Text(
        "Share names, hosts, ports and folders — never usernames, passwords, profiles or vault references. Files are private infrastructure metadata; choose who can access them."
      ).font(.callout)
      HSplitView {
        VStack(alignment: .leading) {
          Text("Create a new shared copy").font(.headline)
          TextField("Library name", text: $name)
          List(
            state.connections.filter { $0.kind != .localShell && $0.kind != .serial },
            selection: $selected
          ) { client in
            VStack(alignment: .leading) {
              Text(client.name)
              Text(client.group + " · " + client.kind.displayName).font(.caption).foregroundStyle(
                .secondary)
            }.tag(client.id)
          }
          Button("Select All") {
            selected = Set(
              state.connections.filter { $0.kind != .localShell && $0.kind != .serial }.map(\.id))
          }
          Toggle("Include all groups, including empty ones", isOn: $includeEmptyGroups)
          Button("Save New Shared File…") { create() }.disabled(selected.isEmpty || busy)
        }.frame(minWidth: 260)
        VStack(alignment: .leading) {
          Text("Linked files").font(.headline)
          List {
            ForEach(library.links) { link in
              VStack(alignment: .leading, spacing: 6) {
                Text(link.baseline.name).font(.headline)
                Text(
                  "\(link.mapping.count) linked clients · \(URL(fileURLWithPath: link.path).lastPathComponent)"
                ).font(.caption)
                HStack {
                  Button("Refresh & Review") { load(URL(fileURLWithPath: link.path)) }
                  Button("Save New Revision…") {
                    do {
                      publication = .init(
                        document: try state.makeSharedRevision(
                          link, additionalIDs: selected, includeEmptyGroups: includeEmptyGroups))
                    } catch { message = error.localizedDescription }
                  }
                  Button("Unlink") {
                    do {
                      _ = try state.credentialGate.check()
                      try library.unlink(link.id)
                    } catch { message = error.localizedDescription }
                  }
                }
              }
            }
          }
          Button("Link Shared File…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.nethrivaSharedLibrary, .json]
            panel.allowsMultipleSelection = false
            panel.begin { response in if response == .OK, let url = panel.url { load(url) } }
          }
          Text(
            "Refresh is manual. Personal overrides remain local. Shared deletions keep personal clients. Unlink keeps your clients and passwords; no teammate’s file is modified."
          ).font(.caption).foregroundStyle(.secondary)
        }.frame(minWidth: 310)
      }
      if busy { ProgressView("Reading library…") }
      if let message { Text(message).font(.caption).foregroundStyle(.orange) }
      if let notice = library.notice { Text(notice).foregroundStyle(.orange) }
    }.padding(20).frame(minWidth: 750, minHeight: 550).disabled(busy)
      .sheet(item: $review) { item in
        SharedLibraryReviewView(review: item) { takeShared in
          Task {
            busy = true
            defer { busy = false }
            do {
              try await state.applySharedReview(item, takeShared: takeShared)
              review = nil
              message =
                "Library merged. Existing sessions and personal credentials were not changed."
            } catch {
              message = error.localizedDescription
              review = nil
            }
          }
        }
      }
      .sheet(item: $publication) { item in
        SharedPublicationView(document: item.document) {
          publication = nil
          DispatchQueue.main.async { saveCopy(item.document) }
        }
      }
  }
  private func load(_ url: URL) {
    busy = true
    message = nil
    Task {
      defer { busy = false }
      do {
        _ = try state.credentialGate.check()
        review = try await library.review(url, originals: state.connections)
        _ = try state.credentialGate.check()
      } catch {
        message =
          (error as? SharedLibraryError)?.localizedDescription
          ?? "Could not read the shared library. Check the file and permissions."
      }
    }
  }
  private func create() {
    do {
      let document = try state.makeSharedLibrary(
        name: name, ids: selected, includeEmptyGroups: includeEmptyGroups)
      publication = .init(document: document)
    } catch { message = error.localizedDescription }
  }
  private func saveCopy(_ document: SharedLibraryDocument) {
    guard !state.credentialGate.isLocked else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.nethrivaSharedLibrary]
    panel.nameFieldStringValue = "Nethriva Shared Connections"
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task {
        do {
          let epoch = try state.credentialGate.check()
          try await Task.detached { try SharedLibraryFile.create(document, at: url) }.value
          try state.credentialGate.check(epoch)
          message =
            "Saved a password-free copy. Link it separately to track future changes. Existing files are not overwritten."
        } catch {
          message =
            "The new shared file could not be saved. Choose a new filename and check write permissions."
        }
      }
    }
  }
}

private struct SharedLibraryPublication: Identifiable {
  var id = UUID()
  let document: SharedLibraryDocument
}
private struct SharedPublicationView: View {
  let document: SharedLibraryDocument
  let save: () -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review Shared Copy").font(.title2.bold())
      Text(
        "Only these clients and groups will be published. Personal name/host/group edits are included; review before sharing. Usernames, credentials, provider references and local settings are excluded."
      )
      List {
        Section("Clients") {
          ForEach(document.connections) { item in
            VStack(alignment: .leading) {
              Text(item.name)
              Text(
                item.group + " · " + item.kind.displayName + " · " + item.host + ":"
                  + String(item.port)
              ).font(.caption).textSelection(.enabled)
            }
          }
        }
        Section("Groups (including empty groups)") {
          ForEach(document.groups, id: \.self) { Text($0) }
        }
      }
      Text(
        "A revision keeps the library identity. Teammates can link the new revision file to merge against their previous baseline. Existing files are never overwritten."
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Save Reviewed Copy…", action: save)
      }
    }.padding(20).frame(width: 700, height: 570)
  }
}

private struct SharedLibraryReviewView: View {
  let review: SharedLibraryReview
  let apply: (Set<String>) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var takeShared = Set<String>()
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Review \(review.document.name)").font(.title2.bold())
      Text(
        "\(review.document.connections.count) clients · \(review.document.groups.count) groups · \(review.conflicts.count) decisions"
      )
      Text(
        "Changed destinations require approval. Accepting a new host/port/protocol creates a fresh client without credentials; your previous client remains independent. Existing sessions are unchanged."
      ).font(.caption).foregroundStyle(.orange)
      List {
        Section("Incoming clients (no passwords or usernames)") {
          ForEach(review.document.connections) { item in
            VStack(alignment: .leading) {
              Text(item.name)
              Text(
                item.group + " · " + item.kind.displayName + " · " + item.host + ":"
                  + String(item.port)
              ).font(.caption).textSelection(.enabled)
            }
          }
        }
        Section("Conflicts / destination changes — keep personal by default") {
          ForEach(review.conflicts) { conflict in
            VStack(alignment: .leading) {
              Text(conflict.connectionName + " — " + conflict.field.rawValue)
              Text("Personal: \(conflict.personal)\nShared: \(conflict.incoming)").font(.caption)
                .textSelection(.enabled)
              Toggle(
                "Use shared value",
                isOn: Binding(
                  get: { takeShared.contains(conflict.id) },
                  set: {
                    if $0 { takeShared.insert(conflict.id) } else { takeShared.remove(conflict.id) }
                  }))
            }
          }
        }
      }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }
        Spacer()
        Button("Merge Reviewed Library") { apply(takeShared) }.keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: 730, height: 640)
  }
}

struct ExternalCredentialSettingsView: View {
  let profileID: UUID
  @ObservedObject var providers: ExternalCredentials
  @State private var useExternal = false
  @State private var draft = ExternalCredentialReference()
  @State private var token = ""
  @State private var message: String?
  @State private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Read password from an external provider", isOn: $useExternal)
      if useExternal {
        Picker("Provider", selection: $draft.kind) {
          ForEach(ExternalCredentialKind.allCases) { Text($0.label).tag($0) }
        }
        if draft.kind == .onePassword {
          Picker("Official op executable", selection: $draft.executable) {
            Text("Apple silicon Homebrew").tag("/opt/homebrew/bin/op")
            Text("/usr/local/bin/op").tag("/usr/local/bin/op")
            Text("/usr/bin/op").tag("/usr/bin/op")
          }
          TextField(
            "Secret reference", text: $draft.reference, prompt: Text("op://vault/item/password"))
          Text(
            "Install the official CLI and enable desktop-app integration. 1Password handles authorization. No shell or service-account token is used."
          ).font(.caption)
        } else {
          TextField(
            "HTTPS Vault server", text: $draft.server, prompt: Text("https://vault.example.invalid")
          )
          TextField(
            "KV v2 mount/path", text: $draft.reference, prompt: Text("secret/network/admin"))
          TextField("Password field", text: $draft.field)
          TextField("Namespace (optional)", text: $draft.namespace)
          SecureField("Temporary Vault token", text: $token)
          Button("Authorize for This App Session") {
            do {
              try providers.authorize(profileID, token: token)
              token = ""
              message = "Authorized in memory until lock, profile change, logout or app quit."
            } catch { message = error.localizedDescription }
          }.disabled(token.isEmpty || providers.references[profileID]?.kind != .vaultKV2)
        }
      }
      HStack {
        Button("Save Provider Choice") {
          do {
            try providers.configure(useExternal ? draft : nil, for: profileID)
            token = ""
            message =
              "Provider choice saved locally. Provider passwords are not stored in Keychain or exports."
          } catch { message = error.localizedDescription }
        }
        if providers.references[profileID] != nil {
          Button("Test Read (No Password Display)") {
            busy = true
            Task {
              defer { busy = false }
              do {
                _ = try await providers.password(for: profileID)
                message = "Provider supplied the password field. Nothing was saved or displayed."
              } catch { message = error.localizedDescription }
            }
          }.disabled(busy)
          Button("Forget Vault Authorization") {
            providers.clearAuthorization()
            token = ""
            message = "Temporary Vault authorization cleared."
          }
        }
      }
      Text(
        "Save the profile first. External selection overrides any old Keychain password without deleting it. Provider references and tokens are excluded from all archives and shared files."
      ).font(.caption).foregroundStyle(.secondary)
      if busy { ProgressView("Requesting provider authorization…") }
      if let message { Text(message).font(.caption).foregroundStyle(.orange) }
      if let notice = providers.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
    }
    .task(id: profileID) {
      draft = providers.references[profileID] ?? .init()
      useExternal = providers.references[profileID] != nil
      token = ""
      message = nil
    }
  }
}
