import AppKit
import SwiftUI

struct MultiSessionCommandView: View {
  let router: TerminalCommandRouter
  @EnvironmentObject private var appState: AppState
  @State private var selected = Set<UUID>()
  @State private var command = ""
  @State private var acknowledged = false
  @State private var review: MultiCommandReview?
  @State private var message = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Multi-Session Command").font(.title2.bold())
      Text(
        "One confirmed command, not keyboard broadcasting. Only explicitly selected terminal tabs receive it. Check each is at its intended command prompt, not a login, editor or interactive program."
      ).font(.callout)
      List {
        ForEach(Array(appState.tabs.enumerated()), id: \.element.id) { index, tab in
          if tab.tool == .primary, DefaultField.appearance.supports(tab.connection.kind) {
            Toggle(
              "\(index + 1). \(tab.title) — \(tab.connection.kind.displayName)",
              isOn: Binding(
                get: { selected.contains(tab.id) },
                set: {
                  if $0 { selected.insert(tab.id) } else { selected.remove(tab.id) }
                  acknowledged = false
                }))
          }
        }
      }.frame(minHeight: 150)
      Text("Recipients: \(selected.count) • Maximum 100 • Nothing selected automatically").font(
        .headline)
      TextField("Single-line command", text: $command).font(.system(.body, design: .monospaced))
        .onChange(of: command) { _, _ in acknowledged = false }
      Toggle(
        "I checked every selected terminal and intend this command to run on each one",
        isOn: $acknowledged)
      Text(
        "Commands can be destructive and may be echoed by remote systems. Do not put passwords in commands. Delivery is not atomic across servers; no automatic resend."
      ).font(.caption).foregroundStyle(.secondary)
      HStack {
        Text(message).font(.callout).textSelection(.enabled)
        Spacer()
        Button("Review Execution…") {
          do {
            let prepared = try router.prepare(selected, command: command)
            let names = appState.tabs.enumerated().filter { selected.contains($0.element.id) }
              .map { "\($0.offset + 1). \($0.element.title)" }
            review = MultiCommandReview(command: command, recipients: prepared, names: names)
          } catch { message = error.localizedDescription }
        }.disabled(!acknowledged || selected.isEmpty || command.isEmpty)
      }
    }.padding().frame(minWidth: 720, minHeight: 480)
      .sheet(item: $review) { snapshot in
        VStack(alignment: .leading, spacing: 14) {
          Text("Run on \(snapshot.recipients.count) terminals?").font(.title2.bold())
          ScrollView {
            Text(snapshot.names.joined(separator: "\n")).frame(
              maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 220)
          Text(snapshot.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          HStack {
            Button("Cancel") { review = nil }
            Spacer()
            Button("Execute Once") {
              do {
                let result = try router.execute(snapshot.command, recipients: snapshot.recipients)
                let accepted = result.values.filter { $0 }.count
                message =
                  "Accepted by \(accepted) of \(result.count) terminal input channels. Check output in each tab; nothing will be resent."
              } catch { message = error.localizedDescription }
              review = nil
              selected = []
              acknowledged = false
            }
          }
        }.padding().frame(width: 680)
      }
      .onChange(of: appState.tabs.map(\.id)) { _, ids in
        selected.formIntersection(ids)
        acknowledged = false
      }
  }
}

struct DefaultsFieldsEditor: View {
  @Binding var draft: ConnectionDefaults
  let state: AppState
  @ObservedObject var library: LibraryTools
  var body: some View {
    Picker("Credential profile", selection: $draft.credentialProfileID) {
      Text("Not set / inherit parent").tag(UUID?.none)
      ForEach(state.credentialProfiles) { Text($0.name).tag(Optional($0.id)) }
    }
    Picker("Terminal profile", selection: $draft.terminalProfileID) {
      Text("Not set / inherit parent").tag(UUID?.none)
      ForEach(library.data.profiles) { Text($0.name).tag(Optional($0.id)) }
    }
    ForEach([ConnectionKind.ssh, .telnet, .rdp], id: \.self) { kind in
      TextField(
        "\(kind.displayName) port (blank inherits)",
        text: Binding(
          get: { draft.ports[kind].map(String.init) ?? "" },
          set: { draft.ports[kind] = $0.isEmpty ? nil : Int($0) ?? -1 }))
    }
    TextField("SSH jump chain (blank clears)", text: optional(\.jumpHost))
    TextField("RDP gateway (blank clears)", text: optional(\.gateway))
    TextField(
      "SSH keepalive seconds (blank inherits)",
      text: Binding(
        get: { draft.keepAlive.map(String.init) ?? "" },
        set: { draft.keepAlive = $0.isEmpty ? nil : Int($0) ?? -1 }))
    Picker("RDP scale", selection: $draft.desktopScale) {
      Text("Not set / inherit parent").tag(Int?.none)
      ForEach([100, 140, 180], id: \.self) { Text("\($0)%").tag(Optional($0)) }
    }
    Text(
      "Unset fields inherit from the nearest parent. Entering then clearing a jump chain or gateway explicitly disables it. Passwords are not copied into templates."
    ).font(.caption).foregroundStyle(.secondary)
  }
  private func optional(_ path: WritableKeyPath<ConnectionDefaults, String?>) -> Binding<String> {
    Binding(get: { draft[keyPath: path] ?? "" }, set: { draft[keyPath: path] = $0 })
  }
}

struct LibraryToolsView: View {
  @EnvironmentObject private var state: AppState
  @ObservedObject var library: LibraryTools
  @State private var mode = 0
  @State private var appearance = TerminalAppearance()
  @State private var template = ConnectionTemplate()
  @State private var group = "Ungrouped"
  @State private var groupDraft = ConnectionDefaults()
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading) {
      Picker("Tools", selection: $mode) {
        Text("Terminal Profiles").tag(0)
        Text("Templates").tag(1)
        Text("Group Defaults").tag(2)
      }.pickerStyle(.segmented)
      if let notice = library.notice { Text(notice).foregroundStyle(.red) }
      ScrollView {
        Form {
          if mode == 0 {
            appearanceEditor
          } else if mode == 1 {
            templateEditor
          } else {
            groupEditor
          }
        }.formStyle(.grouped)
      }
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
    }.padding().frame(minWidth: 700, minHeight: 570)
      .onAppear {
        if let requested = state.toolsGroupRequest {
          group = requested
          mode = 2
          groupDraft = library.data.groupDefaults[requested] ?? ConnectionDefaults()
        }
      }
      .onChange(of: state.toolsGroupRequest) { _, requested in
        if let requested {
          group = requested
          mode = 2
          groupDraft = library.data.groupDefaults[requested] ?? ConnectionDefaults()
        }
      }
  }
  private var appearanceEditor: some View {
    Group {
      HStack {
        Menu("Load Profile") {
          ForEach(library.data.profiles) { profile in Button(profile.name) { appearance = profile }
          }
        }
        Button("New") { appearance = TerminalAppearance() }
      }
      TextField("Name", text: $appearance.name)
      Picker("Font", selection: $appearance.fontName) {
        ForEach(["Menlo", "Monaco", "Courier"], id: \.self) { Text($0).tag($0) }
      }
      Stepper(
        "Font size: \(Int(appearance.fontSize)) pt", value: $appearance.fontSize, in: 9...32,
        step: 1)
      Picker("Theme", selection: $appearance.theme) {
        ForEach(TerminalAppearance.Theme.allCases, id: \.self) {
          Text($0.rawValue.capitalized).tag($0)
        }
      }
      Picker("Cursor", selection: $appearance.cursor) {
        ForEach(TerminalAppearance.Cursor.allCases, id: \.self) {
          Text($0.rawValue.capitalized).tag($0)
        }
      }
      Stepper(
        "Scrollback: \(appearance.scrollback) lines", value: $appearance.scrollback,
        in: 100...10000, step: 100)
      HStack {
        Button("Save Profile") {
          perform {
            var data = library.data
            data.profiles.removeAll { $0.id == appearance.id }
            data.profiles.append(appearance)
            try library.save(data)
          }
        }
        Button("Use as Default") {
          perform {
            var data = library.data
            data.profiles.removeAll { $0.id == appearance.id }
            data.profiles.append(appearance)
            data.defaultTerminalProfile = appearance.id
            try library.save(data)
          }
        }
      }
      Text(
        "Profiles apply when a terminal is created or restarted. Remote programs can change the cursor/colors. Existing live terminals are not reconnected."
      ).font(.caption).foregroundStyle(.secondary)
      Stepper(
        "Private output-log retention: \(library.data.retentionDays) days",
        value: Binding(
          get: { library.data.retentionDays },
          set: { value in
            perform {
              var data = library.data
              data.retentionDays = value
              try library.save(data)
            }
          }), in: 1...90)
      Text(
        "Recording is always off until explicitly started in a terminal. Retention cleanup runs when recording starts or from Settings; logs are never included in diagnostic or connection exports."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private var templateEditor: some View {
    Group {
      HStack {
        Menu("Load Template") {
          ForEach(library.data.templates) { item in Button(item.name) { template = item } }
        }
        Button("New") { template = ConnectionTemplate() }
      }
      TextField("Template name", text: $template.name)
      Picker("Protocol", selection: $template.kind) {
        ForEach([ConnectionKind.ssh, .telnet, .rdp, .serial], id: \.self) {
          Text($0.displayName).tag($0)
        }
      }
      DefaultsFieldsEditor(draft: $template.defaults, state: state, library: library)
      HStack {
        Button("Save Template") {
          perform {
            var data = library.data
            data.templates.removeAll { $0.id == template.id }
            data.templates.append(template)
            try library.save(data)
          }
        }
        Button("Delete", role: .destructive) {
          perform {
            var data = library.data
            data.templates.removeAll { $0.id == template.id }
            try library.save(data)
            template = ConnectionTemplate()
          }
        }
      }
      Text(
        "Choose Apply Template in a connection editor to copy applicable settings. Endpoints, names, passwords and group assignments are never part of templates. Updating a template does not change previously created clients."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private var groupEditor: some View {
    Group {
      Picker("Group", selection: $group) {
        ForEach(state.editableGroupPaths, id: \.self) { Text($0).tag($0) }
      }
      .onChange(of: group) { _, path in
        groupDraft = library.data.groupDefaults[path] ?? ConnectionDefaults()
      }
      DefaultsFieldsEditor(draft: $groupDraft, state: state, library: library)
      HStack {
        Button("Save Group Defaults") {
          perform {
            guard state.editableGroupPaths.contains(group) else {
              throw ConnectionGroupError.unavailable
            }
            var data = library.data
            data.groupDefaults[group] = groupDraft
            try library.save(data)
          }
        }
        Button("Clear Defaults") {
          perform {
            var data = library.data
            data.groupDefaults[group] = nil
            try library.save(data)
            groupDraft = ConnectionDefaults()
          }
        }
      }
      Text(
        "Inheritance is opt-in per field in each connection editor. Parent groups provide fallbacks; the nearest subgroup wins. Individual overrides remain unchanged. Close/reopen a tab to use changed transport defaults; live tabs and their Reconnect controls retain snapshots."
      ).font(.caption).foregroundStyle(.secondary)
    }.onAppear { groupDraft = library.data.groupDefaults[group] ?? ConnectionDefaults() }
  }
  private func perform(_ action: () throws -> Void) {
    do {
      for reference in [template.defaults, groupDraft] {
        if let id = reference.credentialProfileID,
          !state.credentialProfiles.contains(where: { $0.id == id })
        {
          throw CredentialProfileError.unavailable
        }
        if let id = reference.terminalProfileID,
          !library.data.profiles.contains(where: { $0.id == id })
        {
          throw WorkflowError.invalid("A referenced terminal profile is unavailable.")
        }
      }
      try action()
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

struct BulkConnectionEditView: View {
  @EnvironmentObject private var state: AppState
  @ObservedObject var library: LibraryTools
  @State private var ids = Set<UUID>()
  @State private var fields = Set<DefaultField>()
  @State private var draft = ConnectionDefaults()
  @State private var moveGroup = false
  @State private var group = "Ungrouped"
  @State private var review: BulkEditReview?
  @State private var message = ""
  var body: some View {
    HStack {
      List(state.connections.filter { $0.kind != .localShell }) { connection in
        Toggle(
          connection.name + " · " + connection.kind.displayName,
          isOn: Binding(
            get: { ids.contains(connection.id) },
            set: { if $0 { ids.insert(connection.id) } else { ids.remove(connection.id) } }))
      }.frame(width: 260)
      VStack(alignment: .leading) {
        Text("Bulk Edit — \(ids.count) selected").font(.title2.bold())
        ScrollView {
          Form {
            Section("Fields to change (unchecked fields stay unchanged)") {
              ForEach(DefaultField.allCases) { field in
                Toggle(
                  field.label,
                  isOn: Binding(
                    get: { fields.contains(field) },
                    set: { if $0 { fields.insert(field) } else { fields.remove(field) } }))
              }
              Toggle("Move to group", isOn: $moveGroup)
              if moveGroup {
                Picker("Destination", selection: $group) {
                  ForEach(state.editableGroupPaths, id: \.self) { Text($0).tag($0) }
                }
              }
            }
            DefaultsFieldsEditor(draft: $draft, state: state, library: library)
          }.formStyle(.grouped)
        }
        Text(
          "Only applicable protocols change. Set a value for each checked field; blank ports/credentials/appearance are skipped. Blank jump/gateway clears them. Individual passwords are not read, replaced or removed. Changed fields stop inheriting; active tabs keep their snapshots."
        ).font(.caption).foregroundStyle(.secondary)
        Text(message).font(.callout)
        Button("Preview Changes…") {
          do {
            let patch = BulkConnectionPatch(
              fields: fields, defaults: draft, group: moveGroup ? group : nil)
            let originals = state.connections.filter {
              ids.contains($0.id) && $0.kind != .localShell
            }
            let updated = try originals.map { try patch.apply($0) }
            review = BulkEditReview(
              originals: originals, updated: updated, patch: patch,
              rules: library.data.groupDefaults)
          } catch { message = error.localizedDescription }
        }.disabled(ids.isEmpty || (fields.isEmpty && !moveGroup))
      }.padding()
    }.frame(minWidth: 880, minHeight: 620)
      .onAppear { ids = editableIDs(state.bulkEditIDs) }
      .onChange(of: state.bulkEditIDs) { _, value in ids = editableIDs(value) }
      .sheet(item: $review) { snapshot in
        VStack(alignment: .leading) {
          Text("Apply to \(snapshot.updated.count) clients?").font(.title2.bold())
          ScrollView {
            ForEach(snapshot.updated) { next in
              VStack(alignment: .leading) {
                Text(next.name).bold()
                if let original = snapshot.originals.first(where: { $0.id == next.id }) {
                  ForEach(
                    previewFields(original, patch: snapshot.patch).filter { $0.supports(next.kind) }
                      .sorted {
                        $0.rawValue < $1.rawValue
                      }
                  ) { field in
                    Text(
                      "\(field.label): \(value(library.resolve(original), field)) → \(value(library.resolve(next), field))"
                    ).font(.caption)
                  }
                  if snapshot.patch.group != nil {
                    Text("Group: \(original.group) → \(next.group)").font(.caption)
                  }
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
          }.frame(maxHeight: 400)
          HStack {
            Button("Cancel") { review = nil }
            Spacer()
            Button("Apply Metadata Changes") {
              do {
                guard library.data.groupDefaults == snapshot.rules else {
                  throw WorkflowError.invalid("Group defaults changed. Review the changes again.")
                }
                try state.applyBulk(
                  snapshot.patch, ids: Set(snapshot.originals.map(\.id)),
                  expected: snapshot.originals)
                message =
                  "Saved metadata for \(snapshot.originals.count) clients. Reopen sessions to use changes."
              } catch { message = error.localizedDescription }
              review = nil
            }
          }
        }.padding().frame(width: 720)
      }
  }
  private func value(_ connection: RemoteConnection, _ field: DefaultField) -> String {
    switch field {
    case .credential:
      state.credentialProfiles.first { $0.id == connection.credentialProfileID }?.name
        ?? "Own credentials"
    case .port: String(connection.port)
    case .jumpHost: connection.sshJumpHost ?? "None"
    case .gateway: connection.rdpGatewayHost ?? "None"
    case .appearance:
      library.data.profiles.first { $0.id == connection.terminalProfileID }?.name ?? "Default"
    case .keepAlive: String(connection.effectiveSSHKeepAliveInterval)
    case .desktopScale: "\(connection.effectiveRDPScale)%"
    }
  }
  private func previewFields(_ original: RemoteConnection, patch: BulkConnectionPatch) -> Set<
    DefaultField
  > {
    patch.fields.union(patch.group == nil ? [] : original.inheritedFields ?? [])
  }
  private func editableIDs(_ proposed: Set<UUID>) -> Set<UUID> {
    proposed.intersection(Set(state.connections.filter { $0.kind != .localShell }.map(\.id)))
  }
}

struct MigrationImportView: View {
  @EnvironmentObject private var state: AppState
  @EnvironmentObject private var settings: AppSettings
  @State private var format: MigrationFormat = .sshConfig
  @State private var preview: MigrationPreview?
  @State private var selected = Set<UUID>()
  @State private var loading = false
  @State private var error = ""
  @State private var generation = UUID()
  @State private var confirmation = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import Other Connection Formats").font(.title2.bold())
      HStack {
        Picker("Format", selection: $format) {
          ForEach(MigrationFormat.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: format) { _, _ in
          generation = UUID()
          preview = nil
          selected = []
        }
        Button("Choose File…", action: choose).disabled(loading)
      }
      Text(
        "Preview only until confirmed. Password fields are ignored. No configuration code is executed, no hosts contacted, no existing clients or credentials overwritten."
      ).font(.callout)
      if loading { ProgressView("Reading and validating…") }
      if let preview {
        List(preview.connections) { connection in
          Toggle(
            isOn: Binding(
              get: { selected.contains(connection.id) },
              set: {
                if $0 { selected.insert(connection.id) } else { selected.remove(connection.id) }
              })
          ) {
            VStack(alignment: .leading) {
              Text(connection.name + " · " + connection.kind.displayName)
              if let endpoint = settings.sidebarEndpoint(for: connection) {
                Text(endpoint).font(.caption).foregroundStyle(.secondary)
              }
              Text(connection.group).font(.caption)
            }
          }
        }
        Text(
          "\(selected.count) selected; \(preview.groups.count) group paths. Same name/endpoint duplicates are unchecked by default. Explicitly select one to create a separate new client."
        ).font(.caption)
        ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        Button("Import Selected…") { confirmation = true }.disabled(selected.isEmpty)
      }
      Text(error).foregroundStyle(.secondary).textSelection(.enabled)
      Spacer(minLength: 0)
    }.padding().frame(minWidth: 780, minHeight: 600)
      .confirmationDialog(
        "Add \(selected.count) new clients?", isPresented: $confirmation, titleVisibility: .visible
      ) {
        Button("Import") {
          guard let preview else { return }
          do {
            try state.addMigratedConnections(
              preview.connections.filter { selected.contains($0.id) }, groups: preview.groups)
            error = "Imported \(selected.count) clients without passwords."
            self.preview = nil
            selected = []
          } catch { self.error = error.localizedDescription }
        }
      } message: {
        Text(
          "Existing clients and Keychain data will not be changed. Imported groups, including empty groups, are preserved."
        )
      }
  }
  private func choose() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.title = "Choose connection configuration"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      loading = true
      error = ""
      preview = nil
      selected = []
      let current = UUID()
      generation = current
      let selectedFormat = format
      Task { @MainActor in
        do {
          let result = try await BackgroundWork.run {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let raw = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            return try MigrationImport.parse(raw, format: selectedFormat)
          }
          guard current == generation else {
            loading = false
            return
          }
          preview = result
          selected = Set(
            result.connections.filter { incoming in
              !state.connections.contains {
                $0.kind == incoming.kind
                  && ($0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                    || ($0.host.caseInsensitiveCompare(incoming.host) == .orderedSame
                      && $0.port == incoming.port && $0.username == incoming.username))
              }
            }.map(\.id))
        } catch { if current == generation { self.error = error.localizedDescription } }
        loading = false
      }
    }
  }
}
