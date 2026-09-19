# Nethriva integration and packaging notes

Nethriva integrates SwiftTerm for local and SSH sessions, macOS OpenSSH/SFTP for compatibility with the user's existing configuration, and FreeRDP's native Cocoa client view for RDP. Passwords are stored in Keychain and are not included in the JSON connection store.

Version 0.9.1 introduced the Nethriva product identity and bundle identifier. The persistence and Keychain services include a one-time compatibility lookup so connections, groups, and passwords created under the earlier development identifier continue to work.

Version 0.10.0 adds a complete offline HTML help manual bundled in the application resources. A native SwiftUI help window hosts it through WebKit, with light/dark appearance support, section navigation, full-text highlighting, print styling, a Help-menu command, Command-?, and a main-window toolbar entry.

## SSH and SwiftTerm

SwiftTerm 1.20.0, SwiftNIO SSH 0.15.0, and SwiftNIO 2.81.0 are pinned through Swift Package Manager. `LocalProcessTerminalView` provides the local terminal and hosts `/usr/bin/ssh` for remote sessions. This active path supports OpenSSH configuration, key files, ssh-agent, password prompts, and keyboard-interactive authentication. SwiftNIO groundwork remains available for a future fully embedded connector, but SwiftNIO SSH does not currently support keyboard-interactive authentication.

1. ~~Add an embedded SwiftNIO SSH transport with password authentication and host-key groundwork.~~ — complete
2. ~~Connect SwiftTerm input/output and terminal resize handling.~~ — complete
3. ~~Add a compatibility path using macOS OpenSSH for key, agent, and keyboard-interactive authentication.~~ — complete and now the default
4. ~~Expose identity-file selection, preferred authentication, and jump hosts in the connection editor.~~ — complete
5. Revisit the embedded connector when keyboard-interactive support is available or implemented.
6. ~~Add SFTP as a sibling session tool rather than coupling it to the renderer.~~ — complete

Every SSH tab now also includes a compact, resizable SFTP tree beside the live terminal. Directory contents load on expansion. Local files and folders can be dropped onto the tree for recursive upload, remote items can be dragged between remote folders to move them, and dragging a remote item to Finder performs a file-promise download. The full SFTP tab remains available for detailed listings and bulk operations. OpenSSH connection multiplexing shares an authenticated transport between matching terminal and SFTP processes, eliminating repeated key exchange and authentication during folder navigation. Terminal password-prompt observation stays inside the AppKit terminal view and only notifies SwiftUI when the prompt state actually changes, keeping normal command output off the application-state update path.

Reference: [SwiftTerm repository and integration notes](https://github.com/migueldeicaza/SwiftTerm).

## FreeRDP 3.31.1

FreeRDP is treated as a native dependency and is not reimplemented in Swift. Nethriva includes a self-contained Apple-silicon runtime under `Nethriva/Resources/FreeRDP`, plus a small Cocoa bridge built from FreeRDP's official macOS client sources.

The Swift adapter loads the Cocoa bridge in-process and inserts its `NSView` into the SwiftUI session tab. Credentials are passed directly to the in-process parser and never appear in the operating system's process argument list. The tab owns the client context and disconnects it when the tab closes.

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
9. Universal runtime, Developer ID signing/notarization, and Windows compatibility matrix — distribution hardening

The existing session-tab architecture keeps terminal, file-browser, and RDP client lifecycles independent while preserving all open sessions during tab switches.
