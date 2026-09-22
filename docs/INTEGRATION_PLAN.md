# Nethriva integration and packaging notes

Nethriva integrates SwiftTerm for local, SSH, and Telnet sessions, macOS OpenSSH/SFTP for compatibility with the user's existing configuration, Network.framework for Telnet TCP transport, and FreeRDP's native Cocoa client view for RDP. Passwords are stored in Keychain and are not included in the JSON connection store.

Nethriva uses stable persistence and Keychain identifiers so Release application updates continue to find saved connections, groups, and credentials. Xcode Debug builds use separate preferences and a separate Keychain service to keep development records out of the user's Release-profile library and distribution workflow.

Connection libraries can be exported without credentials as `.nethriva` JSON archives or with credentials as password-protected `.nethriva-secure` archives. Credential archives encrypt the complete payload with AES-256-GCM using a PBKDF2-HMAC-SHA256 derived key. Imports validate schema and record bounds, preview their contents, preserve empty groups, and offer keep-or-replace handling for matching UUIDs before saving credentials to Keychain.

An app-wide Settings scene persists display preferences in the active Debug or Release defaults profile. Sidebar and session headers independently control endpoint and username visibility; usernames are hidden by default. The SSH and Telnet transport banners avoid writing account details into terminal history. Remote-generated terminal text remains under the remote system's control.

Version 0.10.0 adds a complete offline HTML help manual bundled in the application resources. A native SwiftUI help window hosts it through WebKit, with light/dark appearance support, section navigation, full-text highlighting, print styling, a Help-menu command, Command-?, and a main-window toolbar entry.

Version 0.11.0 consolidates Telnet, connection import/export, isolated Debug data, privacy settings, credential and SFTP hardening, and the in-app RDP authentication dialog improvements. It is the current project version until a separate GitHub release is published.

## SSH, Telnet, and SwiftTerm

SwiftTerm 1.20.0 is pinned through Swift Package Manager. `LocalProcessTerminalView` provides the local terminal and hosts `/usr/bin/ssh` for remote sessions. This path supports OpenSSH configuration, key files, ssh-agent, password prompts, and keyboard-interactive authentication. The earlier unused SwiftNIO SSH implementation and packages were removed so there is one supported SSH path.

1. ~~Connect SwiftTerm input/output and terminal resize handling.~~ — complete
2. ~~Use macOS OpenSSH for key, agent, password, and keyboard-interactive authentication.~~ — complete
3. ~~Expose identity-file selection, preferred authentication, and jump hosts in the connection editor.~~ — complete
4. ~~Add SFTP as a sibling session tool rather than coupling it to the renderer.~~ — complete
5. ~~Add native Telnet transport for legacy devices without an external executable dependency.~~ — complete

Every SSH tab now also includes a compact, resizable SFTP tree beside the live terminal. Directory contents load on expansion. Local files and folders can be dropped onto the tree for recursive upload, remote items can be dragged between remote folders to move them, and dragging a remote item to Finder performs a file-promise download. The full SFTP tab remains available for detailed listings and bulk operations. OpenSSH connection multiplexing shares an authenticated transport between matching terminal and SFTP processes, eliminating repeated key exchange and authentication during folder navigation. Masters are explicitly closed with the last matching tab and during app shutdown; stale per-process socket directories are cleaned on launch. SFTP passwords enter the helper through a private pipe, commands are passed as separate values, and control characters are rejected from the textual command channel.

Telnet uses a Network.framework TCP connection and a small stateful negotiation layer for echo, suppress-go-ahead, terminal type, and window-size options. The user interface marks Telnet as unencrypted and only offers saved-password submission as an explicit action.

Reference: [SwiftTerm repository and integration notes](https://github.com/migueldeicaza/SwiftTerm).

## FreeRDP 3.31.1

FreeRDP is treated as a native dependency and is not reimplemented in Swift. Nethriva includes a self-contained Apple-silicon runtime under `Nethriva/Resources/FreeRDP`, plus a small Cocoa bridge built from FreeRDP's official macOS client sources.

The Swift adapter loads `libNethrivaRDP.dylib` in-process and inserts its `NSView` into the SwiftUI session tab. Credentials are passed directly to the in-process parser and never appear in the operating system's process argument list. OpenSSL provider search configuration is applied through the bridge's own library context rather than mutating the entire app process environment. The tab owns the client context and disconnects it when the tab closes.

The server authentication alert offers an unchecked **Save credentials in Keychain** option. The native view retains that candidate only within its session, and the Swift adapter consumes it only after FreeRDP reports a connected desktop. The app then updates the saved connection's username/domain and writes its password to the matching Debug or Release Keychain service. Failed, cancelled, gateway, and smart-card authentication does not save credentials.

The embedded surface measures its actual detail-area bounds in logical macOS points. It uses those measurements for the initial desktop size and sends debounced Display Control monitor-layout updates after app-window or sidebar resizing. Local drawing and pointer mapping scale continuously while the server applies a new resolution.

The connection editor exposes dynamic resolution, scaling, network profile, H.264/AVC444, clipboard, audio input/output, home/custom folder redirection, printers, smart cards, USB, domain, RD Gateway, certificate policy, administrative sessions, and reconnect limits. Potentially sensitive device redirects are opt-in. The Cocoa bridge translates macOS editing shortcuts into Windows control shortcuts and exchanges clipboard text as UTF-16LE `CF_UNICODETEXT`. Finder drops and copied Finder items use the RDP file-clipboard protocol: Nethriva activates the remote drop point, advertises file descriptors, streams file contents on demand, waits for Windows to acknowledge the new clipboard offer, and issues a Windows paste without first copying the item into a local staging directory.

The bundled runtime is arm64 with a macOS 14 deployment target and includes its linked third-party license texts. A later distribution phase can add a universal binary plus Developer ID signing and notarization.

References: [FreeRDP repository](https://github.com/FreeRDP/FreeRDP) and [official compilation guidance](https://github.com/FreeRDP/FreeRDP/wiki/Compilation).

## Delivery status

1. ~~SwiftTerm local PTY replacement~~ — complete in the MVP
2. ~~SSH transport, host-key verification, and key/password/keyboard-interactive authentication~~ — complete through macOS OpenSSH
3. ~~SSH identity and jump-host controls in the editor~~ — complete
4. ~~SFTP browser~~ — complete
5. ~~Integrated SSH file tree with recursive drag-and-drop transfers~~ — complete
6. ~~Functional FreeRDP desktop sessions~~ — complete through the bundled Cocoa client view
7. ~~RDP display, input, clipboard, audio, device, gateway, certificate, and reconnect options~~ — complete
8. ~~Complete bundled offline help manual and native help window~~ — complete
9. ~~Native Telnet sessions for legacy infrastructure~~ — complete
10. ~~CI, issue templates, redacted diagnostics, release scripts, checklist, and compatibility matrix~~ — complete
11. ~~Connection-library import/export, optional encrypted credentials, and isolated Debug data~~ — complete
12. Universal runtime and optional Developer ID signing/notarization — future distribution hardening

The existing session-tab architecture keeps terminal, file-browser, and RDP client lifecycles independent while preserving all open sessions during tab switches.
