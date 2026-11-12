<img src="Nethriva/Resources/Brand/Nethriva-Wordmark.png" alt="Nethriva" width="620">

# Nethriva

Nethriva is an open-source native macOS connection manager for local terminal, SSH, Telnet, Serial, SFTP, RDP, and virtual-machine consoles. It uses a SwiftUI application shell with AppKit-hosted terminal and remote-desktop surfaces, keeps multiple live sessions organized in tabs, and stores saved credentials in macOS Keychain.

Nethriva **0.13.0 (build 30)** is a release. Download the Apple-silicon DMG or ZIP from [v0.13.0](https://github.com/vitalii-sharapov/Nethriva/releases/tag/v0.13.0); both have SHA-256 checksum files. This build is locally/ad-hoc signed and not Apple-notarized. Review the [release notes, installation steps and known limits](docs/releases/0.13.0.md) before use. Version 0.13.0 is the latest release.

Known limitations include a failing WebMKS framebuffer check on GitHub's macOS 27.0.1 virtual machine and an open security warning for legacy VMware SHA-1 certificate fingerprints. Local macOS 27.2 and macOS 26 hosted console tests pass; this is not certification for every Mac, host or OS.

**[Download the Mac app — Apple silicon DMG](https://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/Nethriva-0.13.0-macOS-arm64.dmg)** · [ZIP](https://github.com/vitalii-sharapov/Nethriva/releases/download/v0.13.0/Nethriva-0.13.0-macOS-arm64.zip)

Open the DMG and drag **Nethriva.app** into **Applications**, or extract the ZIP and move the app there. No Xcode or compilation is needed for these downloads.

## At a glance

| Capability | Implementation | Opens in a tab | File transfer |
|---|---|---:|---:|
| Local terminal | SwiftTerm with a real macOS pseudo-terminal | Yes | Local filesystem |
| SSH | macOS OpenSSH hosted inside SwiftTerm | Yes | Integrated SFTP tree |
| Telnet | Native TCP client with Telnet option negotiation and SwiftTerm | Yes | No |
| Serial | Native USB/serial device I/O with SwiftTerm | Yes | No |
| SFTP browser | Structured SFTP v3 over macOS OpenSSH with authenticated connection reuse | Yes | Queued upload/download, move, and drag-and-drop |
| RDP | Bundled FreeRDP 3.33.1 with a native Cocoa bridge | Yes | Opt-in clipboard and Finder file/folder transfer |
| VM host inventory | Proxmox, VMware ESXi/vCenter, QEMU/libvirt, Hyper-V, Xen Orchestra, and Nutanix AHV adapters | Yes | Host-side ISO attachment; not a file uploader |
| VNC / SPICE console | Bundled noVNC / SPICE HTML5 with native TCP or secure WebSocket transport | Yes | Text clipboard when the server/guest supports it; no Finder file transfer |

Virtualization integrations are new in 0.13.0 and require host-specific setup and permissions. Automated checks cover parsing, bundled console loading, and local console transports; live interoperability with each host platform still needs validation. VMware requests one-time WebMKS tickets and renders the console with bundled noVNC inside a tab, without VMRC or a vCenter web-page login; Hyper-V uses the existing embedded RDP bridge. See the [virtualization setup guide](docs/VIRTUALIZATION.md) and [compatibility matrix](docs/COMPATIBILITY.md) before configuring a host.

Nethriva provides downloadable app packages on GitHub Releases and source as an Xcode project. The project folder contains the application source, tests, application and brand assets, the native RDP bridge source, a bundled Apple-silicon RDP runtime, and its third-party license notices.

## Requirements and current platform support

- macOS 14 or later
- Xcode with the macOS development tools installed **only when building from source**; downloaded apps do not require Xcode
- Apple-silicon Mac for the currently bundled RDP runtime
- Network access to the SSH, Telnet, SFTP, RDP, or virtualization hosts you want to use
- Remote hosts with the required SSH/SFTP, Telnet, or RDP service enabled and reachable from the Mac
- Valid credentials, an SSH key or agent, or another authentication method accepted by the remote host

The Xcode project pins its Swift package dependencies. RDP is self-contained in the app resources and does not require a separate package-manager installation.

## Complete feature and capability list

### Native macOS workspace

- Original Nethriva app icon, wordmark, and adaptive blue accent color
- Complete macOS icon set from 16 × 16 through 1024 × 1024
- Branded empty-workspace state using the application mark
- Native Swift and SwiftUI application with AppKit integration where direct system-view hosting is required
- Resizable split-view layout with a hideable, width-adjustable connection sidebar
- Minimum application size of 900 × 600 for a usable session workspace
- Horizontal session tab bar with protocol-specific icons and close controls
- Compact title bar, session tabs, and RDP controls to leave more room for the remote desktop
- Independent local terminal, SSH, Telnet, Serial, SFTP, and RDP tabs
- Resizable remote-file tree beside SSH terminals in single-pane mode; dedicated SFTP tabs remain available in splits
- Multiple tabs for the same saved connection
- Session preservation while switching between open tabs
- Resizable side-by-side or stacked layouts, SSH groups of two to four panes, and movable detached session windows without reconnecting; other new sessions open alone, and selecting an SSH group member restores its layout and sizes
- Command-K Quick Connect palette for saved connections, cached VMs and workflow actions
- Automatic selection of the next available tab when the current tab closes
- Empty-workspace screen with a shortcut to open the selected connection
- Complete offline help manual in a dedicated resizable window
- Searchable help navigation covering every connection and session type, security, shortcuts, limitations, and troubleshooting
- Help access from the toolbar, the macOS Help menu, and Command-?
- Native Settings window available from the app menu, toolbar, or Command-,
- Separate movable Credential Profiles manager for shared SSH, Telnet, and RDP accounts
- Keyboard commands:
  - Command-F focuses the sidebar connection search
  - Command-K opens Quick Connect
  - Command-O opens the selected connection
  - Command-Shift-U opens SFTP for the selected SSH connection

### SSH and workspace workflow tools

- File → SSH Tunnels: saved local, remote and SOCKS forwarding definitions with explicit Start/Stop on authenticated OpenSSH masters, loopback listen defaults, state/error reporting, and transport leases
- Ordered jump-host editor for up to eight OpenSSH ProxyJump hops; per-hop keys/authentication follow SSH config or agent
- Right-click tabs for side-by-side/stacked sessions or Detach to Window; closing the detached window docks it, while closing its tab ends the session
- Right-click regular files in SSH/SFTP to edit UTF-8 text up to 2 MiB, with content-hash conflict checks, explicit overwrite decisions and safe atomic replacement on capable servers
- File → Command Snippets: named/grouped templates, parameter fields, shell quoting, preview, terminal targeting, Insert without Return, and confirmed Run

App-owned SSH masters now suppress forwarding rules inherited from SSH config: define forwards in the tunnel manager instead. Tunnel/snippet definitions remain local to the active data profile and are not yet included in connection-library exports. Remote replacement does not preserve ownership/ACLs and cannot lock out concurrent writers. See the [workflow guide](docs/WORKFLOWS.md) for setup, safety limits and acceptance checks.

### Connection library and sidebar

- File → Multi-Session Command: explicit terminal recipients, exact preview, confirmation and stale/disconnected-target checks; no live keystroke broadcasting or automatic resend
- Named terminal font/theme/cursor/scrollback profiles and read-only **Find Output** search for Local, SSH, Telnet and Serial terminals
- Per-terminal opt-in, timestamped output recording with a visible indicator, bounded private logs and configurable retention; filtering is a precaution, not a secrecy guarantee
- Connection templates, per-field opt-in parent/subgroup inheritance, individual overrides, and protocol-specific credential/port/jump/gateway/appearance defaults
- Previewed bulk metadata editing from multi-selected sidebar clients; active tabs and individual Keychain passwords remain unchanged
- Previewed migration imports for OpenSSH config, RDP files, CSV and attribute-based connection-tree XML; imported passwords are ignored and existing records are not overwritten

See the [terminal and library tools guide](docs/LIBRARY_TOOLS.md) for supported import schemas, recording/privacy limits, inherited settings and acceptance checks. Templates/group rules stay local; connection exports materialize effective settings and embed appearance so exported clients do not depend on the original rules. New transport defaults take effect in newly opened tabs, not an existing tab's Reconnect snapshot.

- Built-in Local Terminal connection
- Saved SSH, Telnet, Serial, RDP, Virtualization Host, VNC Console, and SPICE Console connections
- Persistent connection data and expandable nested groups
- Sidebar search by connection name, hostname/IP address, group path, or port; multiple terms can be combined
- Favorites section for frequently used connections
- Create, edit, quickly rename, duplicate, move, favorite, and delete connections
- Create persistent groups and subgroups; remove a group while moving its connections to Ungrouped
- Right-click a group to add a connection or subgroup, rename it, expand or collapse it, copy its path, or remove it
- Add a connection directly to a selected group
- Command-click to toggle individual connections or folders, or Shift-click to select a visible range of the same kind
- Drag selected connections to another group; drag a folder to move its entire subtree, including empty subfolders
- Drag connections to Favorites to add them there, or to Ungrouped to remove their group assignment
- Alphabetical group and connection ordering
- Single-click selection and double-click opening
- Sidebar Add menu for new connections and groups
- Selected-connection action menu
- Context menus on every connection
- One-click Open button in the sidebar footer
- Copy a connection address to the clipboard
- Copy a ready-to-use SSH command, including a non-default port when configured
- Connection type, endpoint, protocol-specific settings, group, and favorite fields
- Optional reusable credential profile selected per SSH, Telnet, or RDP connection
- Independent sidebar and session privacy settings for host addresses and usernames; usernames are hidden by default
- Protocol-specific settings that appear only when relevant
- Saved connection compatibility defaults for data created by earlier versions
- Import and export from the File menu, toolbar connection-library menu, or sidebar footer
- Credential-free exports containing connection settings, favorites, groups, and empty groups
- Optional password-protected exports containing saved Keychain credentials
- Import preview with connection, group, credential, and duplicate counts
- Duplicate handling that can keep existing records or replace matching connection identifiers

### Credential handling and security

- File → Shared Connection Libraries: reviewed, password/username-free network libraries, manual refresh, personal overrides and three-way conflict handling; changed destinations create fresh credential-free clients
- External password retrieval through the official 1Password CLI or HTTPS HashiCorp Vault KV v2, configured locally per credential profile; provider secrets/references are excluded from archives
- File → Lock & Disconnect Sessions (Command-Shift-L), with Touch ID/Mac-password unlock, persistent lock state and optional sleep/screen/idle locking

Locking disconnects live sessions, stops recordings/tunnels, clears temporary vault authorization and shields all app windows; connections reopen only through an explicit user action. Automatic lock is off by default. Shared files remain sensitive infrastructure metadata, not an encrypted vault. See [sharing, provider setup and privacy-lock limits](docs/SHARING_PRIVACY.md).

- Password storage in macOS Keychain, indexed by a connection or reusable credential-profile identifier
- Named reusable credential profiles with username, optional Windows domain, and a single shared Keychain password
- Profile password rotation updates every linked connection on its next session; existing sessions stay active
- Shared profiles cannot be deleted while a connection uses them; interactive RDP credential saving detaches only that connection
- Passwords are not encoded into the persistent connection database
- Editing a connection can keep, replace, or explicitly remove the existing password
- Keychain items use the device-local, available-only-while-unlocked accessibility class
- Duplicating a connection safely copies its Keychain credential to a new Keychain item
- Deleting a connection also deletes its saved credential
- SSH host verification through the system OpenSSH `known_hosts` workflow
- Changed SSH host keys remain protected by OpenSSH checks
- RDP certificate policies:
  - Require a valid certificate, using macOS system trust and hostname verification by default
  - Trust on first use, with explicit initial fingerprint approval and changed-pin refusal
  - Ignore certificate warnings, requiring confirmation for each session
- RDP defaults to NLA with TLS 1.2 or newer; TLS-only and legacy RDP are explicit compatibility choices, with a session warning for legacy RDP
- RDP credentials are passed to the embedded client in-process and do not appear in a separate RDP process list
- Sensitive RDP device redirection features are disabled unless explicitly enabled for a connection
- SFTP passwords are delivered through a private pipe rather than process arguments or environment variables
- SFTP paths containing control characters or unsafe components are rejected before binary file requests are sent
- Credential-free connection archives cannot contain passwords
- Credential exports encrypt the complete archive with AES-256-GCM and a PBKDF2-HMAC-SHA256 derived key
- Export files are created with permissions restricted to the current macOS user
- Password-free exports include profile metadata and usernames but no passwords; encrypted exports can include shared profile passwords

### Telnet sessions

- Interactive Telnet sessions embedded directly in a SwiftTerm tab
- Native TCP transport using Network.framework, with no external Telnet executable required
- Negotiation support for terminal type, echo, suppress-go-ahead, and window-size updates
- Direct keyboard input, Command-V paste, secondary-click paste, and terminal resizing
- Custom host and port, with port 23 as the default
- Login/username- and password-prompt detection with explicit Send Saved Username and Send Saved Password actions
- Reconnect control after a session closes or fails
- Persistent warnings that Telnet sends credentials and session data without encryption

### Serial sessions

- Saved serial-console connections for USB-to-serial adapters, including USB-to-RJ45 console cables that expose a serial device on macOS
- Live discovery and manual refresh of available `/dev/cu.*` ports in the connection editor; a device path may also be entered manually
- Baud rates from 300 through 230400, 7/8 data bits, none/even/odd parity, 1/2 stop bits, and none/hardware/software flow control
- Optional local echo, SwiftTerm keyboard input, Command-V paste, and secondary-click paste
- Independent tab lifecycle, disconnection notice, and reconnect control
- Serial device paths and settings can be imported/exported with the connection library; no serial credentials are requested or saved
- The adapter must be connected and accessible to the current macOS user when the session opens

### Local terminal

- Login shell launched from the user's configured `SHELL`, with `/bin/zsh` as the fallback
- Starts in the user's home directory
- Real pseudo-terminal session hosted in SwiftTerm
- ANSI and xterm-compatible terminal rendering
- 256-color and true-color support through the terminal environment
- Direct keyboard input
- Text selection and clipboard operations
- Command-V paste
- Two-finger trackpad click or mouse secondary-click paste
- Automatic terminal row and column resizing with the tab
- Terminal process remains alive while switching tabs
- Closing the tab terminates its local process

### SSH sessions

- Interactive SSH sessions embedded directly in a tab
- Compact remote filesystem tree displayed beside the live terminal
- Resizable divider between the remote tree and terminal
- Lazy folder expansion so only opened directories are requested
- Parent-folder, home-folder, refresh, new-folder, and upload controls in the tree
- Double-click a remote folder to use it as the tree root
- Double-click a remote file to choose a download destination
- Drag local files or folders onto the tree root or a remote folder to upload them
- Drag a remote file or folder onto another remote folder to move it
- Drag a remote file or folder out to Finder to download it
- Remote path copying and explicit download actions from the tree context menu
- Native terminal rendering, keyboard input, selection, copy, and paste
- Uses the macOS OpenSSH client and the user's existing SSH environment
- Reuses each authenticated OpenSSH transport for its terminal and file operations, avoiding a new login handshake for every expanded folder
- Explicitly closes a reusable SSH transport when its last associated tab closes and when Nethriva quits
- Uses an unpredictable private control-socket directory, validates its ownership and identity, and removes only its own empty directory
- Supports existing `~/.ssh/config` settings
- Supports existing `known_hosts` entries
- Supports private keys and `ssh-agent`
- Inherits `SSH_AUTH_SOCK`, locale, and relevant shell environment values
- Authentication modes:
  - Automatic configuration and agent discovery
  - Password or keyboard-interactive only
  - Public-key only
- Optional per-connection identity file with a native file chooser
- Optional jump host
- SSH agent forwarding
- SSH compression
- Configurable keepalive interval with missed-response handling
- Custom SSH ports
- First-use fingerprint confirmation in the session terminal
- Password-prompt detection with a visible explanation that terminal password input is hidden
- Send Saved Password button for the current Keychain credential
- Exit-status display when a session ends
- Reconnect control without reopening the saved connection
- Correct terminal focus after opening and after sending a saved password

### SFTP file browser

- SFTP opens as a separate tab associated with an SSH connection
- Uses the same host, port, username, authentication preference, identity file, jump host, agent, and compression settings as SSH
- Uses the saved Keychain password when required
- Honors the system SSH host-key database; an unknown key can be reviewed through an SSH session before file access
- Remote working-directory display with selectable path text
- Directory listing with folders first
- File and folder names, sizes, modification values, permissions, and symbolic-link indicators
- File-type icons for images, archives, scripts, source files, links, and general documents
- Double-click folder navigation
- Parent-folder and home-folder navigation
- Refresh control
- Empty-folder state
- Multiple-file and folder upload through a native file picker
- Recursive folder upload
- Drag-and-drop file and folder upload into the browser
- Download a selected file or folder through a native destination panel
- Recursive folder download
- Create remote folders
- Rename remote files and folders
- Delete remote files
- Delete empty remote folders with confirmation
- Loading and activity indicators
- Fast folder expansion through authenticated OpenSSH connection reuse
- Item count and endpoint status bar
- Actionable authentication, host-key, timeout, permission, and server-response errors
- Shortcut from an SFTP error to the associated SSH session

Recursive deletion of non-empty remote folders is not currently enabled.

The SSH file tree and SFTP browser include an in-memory transfer queue with per-file progress/speed, Cancel, Retry, and explicit Skip/Rename/Overwrite conflict choices. File operations use structured SFTP v3 packets rather than textual commands or parsed `ls` output. Listings reuse an open subsystem, and transfer channels remain separate from browsing. Regular files are staged before publication; safe remote replacement requires the OpenSSH POSIX-rename extension. Symbolic links and special files are not followed. Folder merges are not atomic, retries restart the job, and a broken connection can leave a remote hidden partial file. See [reliability and transfer safety](docs/RELIABILITY.md).

### Embedded RDP sessions

- RDP desktops rendered directly inside Nethriva tabs
- Bundled FreeRDP 3.33.1 runtime and native Cocoa view bridge
- No separate RDP application or external RDP window
- Network Level Authentication credentials
- Domain-qualified usernames, including `DOMAIN\\user` parsing
- Custom RDP ports
- Correct mouse-coordinate translation inside the tab
- Primary click, secondary click, dragging, pointer movement, and wheel scrolling
- Trackpad two-finger secondary-click menus at the correct remote location
- Direct keyboard focus and input in the embedded desktop
- Automatic keyboard-focus recovery whenever the embedded desktop is clicked
- Opt-in bidirectional Unicode text clipboard redirection, disabled by default
- Native Command-C, Command-X, Command-V, and Command-A mapping to the matching Windows shortcuts
- Paste toolbar action for Mac text and copied Finder files
- Finder file and folder drops directly into the active Windows desktop or folder
- Remote drop-point activation so the desktop or Explorer window beneath the pointer receives the paste
- Standard RDP file-clipboard streaming without creating a duplicate local transfer folder
- File-paste feedback for drag-and-drop and copied Finder items
- Dynamic resolution based on the tab's logical dimensions rather than doubled Retina backing pixels
- Automatic remote resize when the application window changes size
- Automatic remote resize when the sidebar is shown, hidden, or resized
- Continuous drawing and pointer scaling while the remote host applies a new layout
- Per-session interface-size control:
  - Comfortable — 100%
  - Larger — 140%
  - Largest — 180%
- Saved interface scale per connection
- Modern 32-bit H.264/AVC444 graphics pipeline
- Software graphics fallback when modern acceleration is disabled
- Compression and selectable network profiles:
  - Automatic
  - LAN
  - Fast broadband
  - Limited broadband
  - WAN
  - Very slow link
- Remote audio options:
  - Play on this Mac
  - Play on the remote computer
  - Disabled
- Optional microphone redirection
- Optional home-folder redirection
- Optional custom-folder redirection with a native folder chooser
- Optional printer redirection
- Optional smart-card redirection
- Optional USB-device redirection
- Remote Desktop Gateway host and gateway username
- Administrative-session connection option
- Automatic reconnection with a configurable retry limit
- Per-tab connection phase, endpoint, resolution, and interface-scale status
- Disconnect and reconnect controls
- Actionable messages for rejected credentials, unreachable services, remote disconnects, and FreeRDP errors

### Virtualization hosts and VM consoles

- **Virtualization Host** connection type with a platform picker for Proxmox VE, VMware ESXi/vCenter, QEMU/libvirt, Microsoft Hyper-V, XCP-ng/XenServer through Xen Orchestra, and Nutanix AHV through Prism Central
- Searchable VM inventory with name, identifier, host/node, power state, and available guest-tools information
- Optional VM Details panel with available guest IPs, OS, CPU/RAM, tools and host information; credential-free, unsaved SSH/RDP guest shortcuts
- Confirmed snapshot/checkpoint creation, deletion and reversion for VMware, Proxmox, Hyper-V and stopped libvirt VMs; progress where reported and explicit Stop Monitoring without replay
- Experimental interactive vCenter federated sign-in using a registered public OAuth client, system browser/MFA, S256 PKCE, token exchange and SOAP SAML bearer login; administrator setup and live provider acceptance required
- Open a running VM's console in an independent tab without requiring a network address inside the guest
- VM actions selected according to platform and state: start, graceful shutdown/reboot, suspend/resume where supported, reset, and force power-off
- Confirmation before disruptive actions; host permissions and guest support still determine whether a request succeeds
- Mount/eject an existing host-side ISO; VMware's host-provided Tools installer and Nutanix Guest Tools media actions
- Optional guest-tools ISO setting for platforms without a universal tools installer; mounting media does not install software inside the guest
- Direct **VNC Console** and **SPICE Console** connections for separately exposed QEMU or other compatible consoles
- Native TCP, strict TLS-wrapped TCP or secure WebSocket transport, with optional SSH forwarding of a direct TCP console through a saved SSH connection
- Built-in noVNC and SPICE HTML5 assets; no external CDN or console application required
- Fit-to-tab scaling, optional guest display-size updates when the server/guest supports them, view-only mode, input release, and app fullscreen
- Visible **Fit Screen** toolbar button for VNC, SPICE, and VMware consoles; aspect-ratio-preserving auto-fit follows window/sidebar changes without changing the guest resolution
- Independent, opt-in **Resize Guest to Fit (When Supported)** control under **Display & Input**

### Advanced connections, updates and accessibility

- Off-by-default SSH X11 forwarding: untrusted/trusted modes, local XQuartz DISPLAY detection, explicit trusted-X11 warning and a dedicated, non-multiplexed terminal transport; install XQuartz separately
- Sessions menu with next/previous, numbered-tab and close-session shortcuts; keyboard sidebar selection/search/group expansion, selected-row scrolling, VM Return-to-open and explicit accessibility actions
- Mac-authenticated privacy unlocking with Return; auxiliary-window shields remain beside, not inside, SwiftUI hosting graphs
- Manual **Help → Check for Updates…** with publisher Ed25519 manifest and SHA-256/size verification; no automatic installation or bypass of macOS security. Verified downloads remain disabled until a publisher public key is configured
- Universal application-core cross-build and architecture-aware RDP loading. Full universal packaging requires a matching x86_64 FreeRDP bundle; **Intel RDP is not included yet**

See [advanced setup and acceptance](docs/ADVANCED_CONNECTIONS.md) for registration, snapshots, XQuartz, secure VNC, packaging, signed-update publishing and keyboard shortcuts. Live identity-provider/Intel/VoiceOver acceptance is still pending. These additions are included in the 0.13.0 build-30 release; setup-dependent features still need live acceptance.
- **Ctrl+Alt+Del** in VNC, SPICE, VMware WebMKS, and RDP tabs
- Opt-in console text clipboard sharing and explicit **Send Clipboard** action; VM consoles do not inherit RDP's Finder file transfer
- Per-host HTTPS/WSS certificate policy, with valid-certificate verification as the default and explicit fingerprint approval for trust on first use
- Host passwords and API tokens may be stored in Keychain or supplied temporarily for the current host's open tabs
- Session cookies, generated tokens, console tickets, and console passwords stay in memory; closing a tab closes its transports and owned tunnels

Host API versions, guest agents, exposed graphics devices, and permissions affect available capabilities. Plain TCP VNC/SPICE is not encrypted; use SSH forwarding or a secure WebSocket endpoint. VMware requires API-compatible credentials, console privileges, and direct Mac access to the ESXi endpoint returned by the ticket; experimental registered-client federation requires administrator/IdP setup and live acceptance. Hyper-V requires host OpenSSH/PowerShell access and VMConnect access on port 2179. Nutanix console access needs the newer console-token API and an accepted bearer token or authenticated cookie. Full setup details and current limits are in [docs/VIRTUALIZATION.md](docs/VIRTUALIZATION.md).

### Session and process lifecycle

- Optional recovery after sleep or network/interface changes, configured in Settings; off by default
- Interrupted file transfers require explicit Retry; terminal commands and VM operations are never automatically replayed
- Connection Check from the File menu, client context menus, or session toolbars, with DNS/TCP and applicable strict HTTPS checks
- Optional read-only SSH/SFTP login check and copy/export of redacted stage results
- Tab-activation focus guards prevent background sessions from stealing keyboard input
- Background VM inventory parsing/sorting and debounced search filtering

- Every local terminal and SSH tab owns its own pseudo-terminal process
- Every Telnet tab owns an independent TCP connection and protocol-negotiation state
- Every embedded RDP tab owns its own native client context
- VM host tabs own their API session; VM console tabs own their transports, temporary tickets, and any SSH forwarding process
- Every SFTP tab performs operations independently while safely reusing the matching authenticated OpenSSH transport
- Switching tabs does not terminate active sessions
- Closing a tab releases its terminal, Telnet, reusable SSH transport, or RDP client resources as appropriate
- Connection deletion closes tabs associated with that saved connection
- RDP view focus is restored after connection
- RDP resizing is debounced to avoid flooding the remote host during window movement

### Persistence and testing

- Versioned connection persistence through macOS user defaults
- Last-known-good connection backup with automatic recovery and a visible warning if the primary store is damaged
- Backward-compatible decoding for saved connections without newer SSH or RDP fields
- Separate Debug and Release connection stores and Keychain services; neither store is bundled into the app
- Keychain-backed credential abstraction for testability
- Hosted tests use isolated per-process preferences and a separate credential namespace, with no personal/legacy fallback
- Unit coverage for:
  - Default protocol ports
  - Legacy connection compatibility
  - SSH option persistence
  - RDP compatibility defaults
  - Secure RDP argument construction and password redaction
  - Dynamic-resolution argument selection
  - Embedded tab sizing
  - Logical-size handling on Retina displays
  - Per-session RDP scale overrides
  - Windows domain and username parsing
  - Bundled runtime configuration
  - Session-tab identity and selection
  - Connection, credential, and group persistence behavior
  - Telnet negotiation, control-byte filtering, and literal-IAC escaping
  - SFTP secret isolation and control-character rejection
  - Corrupt connection-store recovery
  - Plain and encrypted connection-archive round trips
  - Credential exclusion, group preservation, duplicate handling, and development-data isolation
  - Redacted diagnostic-export behavior
  - VM platform defaults, inventory parsing, input validation, shell/XML safety, and Hyper-V VMConnect argument construction
  - Bundled console JavaScript loading in WebKit and a local VNC handshake with Ctrl+Alt+Del delivery
  - VMware ticket/schema handling, isolated TLS, encrypted WebSocket framebuffer/cursor rendering, and rejection of mismatched ticket certificates
- Native bridge smoke validation for creation, loading, resizing, startup failure handling, shutdown, and code signing
- GitHub Actions checks for tests, an unsigned Release build, and the bundled RDP bridge symbol
- Redacted diagnostic export from the Help menu; connection names, hosts, usernames, credentials, file paths, and session logs are excluded

## Build and run

1. Open `Nethriva.xcodeproj` in Xcode.
2. Select the `Nethriva` scheme and the `My Mac` destination.
3. Choose **Product → Clean Build Folder** after replacing an older project or bundled RDP runtime.
4. Press Command-R.
5. Double-click a saved connection to open its session or VM inventory.
6. For file management, right-click an SSH connection and choose **Open SFTP Browser**.

Use Xcode 26 or newer (Swift tools 6.2 minimum); the currently validated stable toolchain is Xcode 27.2/Swift 6.4.2. On the first build, Xcode resolves pinned SwiftTerm 1.99.3 and its package graph. It may ask once to trust the package's build-information plugin. Headless builds must first run `scripts/prepare-swift-packages.sh` to verify the immutable revision and reviewed plugin source; per-invocation CI approval retains the SwiftPM sandbox and does not change global Xcode settings.

Every Release/archive/new-version build checks all managed components against official upstream. The scheme's online preflight and sandboxed, single-use receipt gate block outdated, unavailable, changed or reused results. Internet access is required for version builds; ordinary Debug builds remain available offline with resolved packages. See [dependency updates](docs/DEPENDENCY_UPDATES.md).

Debug builds started from Xcode use an isolated development connection library and Keychain service. That development data persists across Xcode builds, so pressing Run again shows clients you previously saved in Debug. Release builds on the same Mac likewise reopen that Mac’s existing Release library. Neither library nor its Keychain passwords are embedded in `Nethriva.app` or transferred to a new user with a GitHub release ZIP. A first-time user starts with only Local Terminal. Export files are separate artifacts: do not attach a personal `.nethriva` or `.nethriva-secure` archive to a release.

App Sandbox is intentionally disabled because Nethriva launches local terminal and system SSH/SFTP processes. Local and community Release builds can use Xcode's **Sign to Run Locally** option without a paid Apple Developer account. Local development compilation does not require a paid Apple Developer account. Production security acceptance separately requires Developer ID signing, Hardened Runtime, notarization and the distribution gate described in `SECURITY_HARDENING.md`; an ad-hoc export does not satisfy that acceptance.

## Open-source Release builds

Nethriva can be built and shared without a paid Apple Developer account:

1. Select the Nethriva target in Xcode and open **Signing & Capabilities**.
2. For Release, use **Team: None** and **Signing Certificate: Sign to Run Locally**. If the certificate control is not visible, set **Code Signing Identity** for Release to **Sign to Run Locally** under Build Settings.
3. Select the Nethriva scheme and an Apple-silicon Mac destination.
4. Choose **Product → Archive**.
5. In Organizer, choose **Distribute App → Custom → Copy App**.

The exported `Nethriva.app` is an optimized Release build. Because it is not signed with an Apple-issued Developer ID or notarized, a Mac that downloads the app may block its first launch. A user who has reviewed and trusts the source and release checksum can attempt to open the app once and then approve it through **System Settings → Privacy & Security → Open Anyway**.

Prebuilt ZIP or DMG files belong on the GitHub Releases page rather than in the source repository. Publish a SHA-256 checksum with each binary release. The source repository intentionally excludes local build products, archives, disk images, and the `outputs` working directory.

For a repeatable local package, run `scripts/build-release.sh`. It creates a clean Release application, ZIP, DMG, and SHA-256 files under `release-artifacts/`. See [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) and [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

To package an existing signed Xcode export without rebuilding it, run `zsh scripts/package-app.sh /absolute/path/to/Nethriva.app /absolute/path/to/release.zip`. Packaging preserves library symlinks and executable permissions, extracts the ZIP again, and rejects invalid signatures, missing native runtime dependencies, or inconsistent minimum macOS requirements before producing a verified package and checksum. DMG packaging also verifies the app on the mounted image. After upload, verify the actual downloaded ZIP with `zsh scripts/verify-release-archive.sh /absolute/path/to/download.zip`. Do not recompress a signed bundle with tools that flatten symlinks or lose executable permissions. These checks do not provide Apple notarization or certify every Mac/macOS version.

### First-run checklist

1. Open the built-in Local Terminal to confirm terminal rendering and keyboard input.
2. Create an SSH, Telnet, or RDP connection from the sidebar's **Add** menu.
3. Enter a friendly name, host, port, username, group, and any protocol-specific options.
4. Optionally enter a password. It is saved in macOS Keychain rather than in the connection record.
5. Double-click the connection, select it and press Command-O, or use **Open** from its context menu.
6. For an SSH host, review and accept its fingerprint when OpenSSH asks for first-use confirmation.
7. For remote file management, choose **Open SFTP Browser** or use the file tree beside the SSH terminal.

No Nethriva account, hosted service, or external connection database is required.

## Usage notes

### SSH host trust

New SSH hosts show the standard fingerprint question in the SSH tab. Review the fingerprint and enter `yes` to store the host key. Password input is intentionally invisible; type or paste the password and press Return.

### SFTP host trust

The SFTP browser does not automatically accept an unknown server key. Open an SSH tab for that connection first, verify the fingerprint, accept it, and then reopen or refresh SFTP.

### Telnet safety

Telnet is provided for legacy infrastructure that cannot use SSH. It does not encrypt authentication or session traffic, so use it only on a trusted, isolated management network. Prefer SSH whenever the device supports it.

### RDP sizing

RDP automatically follows the visible session area. Changing the window, sidebar, or interface-size control sends an updated remote display layout. Start with Comfortable; use Larger or Largest when Windows text and controls need more magnification.

### RDP authentication

For a domain account, enter the username as `DOMAIN\\username` or put the domain in the dedicated Domain field. A logon-failure message normally means Windows rejected the username, domain, or password rather than a network or display problem.

If the RDP authentication prompt appears, **Save credentials in Keychain** is optional and off by default. When selected, Nethriva saves the accepted username and domain to that connection and its password to macOS Keychain after the session connects. Cancelled or failed logins are not saved. Gateway and smart-card prompts do not offer this option.

### Keyboard, pointer, and clipboard controls

| Action | Control |
|---|---|
| Open the selected connection | Command-O |
| Open SFTP for the selected SSH connection | Command-Shift-U |
| Paste into a terminal | Command-V |
| Paste into a terminal with a pointing device | Secondary-click or two-finger click |
| Send common edit shortcuts to Windows | Command-C, Command-X, Command-V, and Command-A |
| Open a Windows context menu | Secondary-click or two-finger click inside the RDP view |
| Transfer Finder items to Windows | Copy them and use the RDP paste action, or drag them into the RDP view |
| Resize the remote Windows desktop | Resize the app, resize or hide the sidebar, or change the interface-size control |

### Display privacy

The same Settings window also offers **Reconnect interrupted network sessions after sleep or network changes**, off by default. Recovery may create a new shell or ask for authentication; it never replays commands or resumes interrupted transfers automatically.

Open **Nethriva → Settings…** or press Command-, to choose whether the sidebar and session headers show host addresses and usernames. Username display is off by default in both places. These controls change Nethriva's labels; names you assign to connections and text printed by a remote shell are not altered.

### Typical workflows

#### Organize connections

Create groups from the sidebar Add menu. Right-click a group (or use its ellipsis menu) to add a connection or subgroup, rename the group, expand or collapse it, copy its path, or remove it. Removing a group also removes its subgroups and moves all their connections to Ungrouped; Favorite markers are cleared so every connection appears there, while saved credentials remain unchanged. Renaming a group updates its clients and nested subgroups without changing saved credentials. Nested groups expand and collapse in the sidebar, and the saved hierarchy is included in library exports. Command-click to toggle individual clients or folders; Shift-click the first and last clients to select all visible clients between them, or do the same with folders. Drag any selected row onto a group header or a client in that group to move the selection together. Dragging a folder moves its clients and subfolders too, including empty subfolders. You can also drop clients onto Favorites or Ungrouped; dropping a folder onto Ungrouped moves it to the top level. A folder cannot be moved inside itself or overwrite another folder. Moving a client into a group removes the Favorite marker so it appears in its destination; groups remain alphabetically sorted rather than manually ordered. Type in the sidebar search field or press Command-F to find connections by name, hostname/IP, group path, or port; separate words narrow the results. The selected-connection menu and row context menu offer quick Rename alongside opening, editing, duplication, moving, address copying, SSH-command copying, and deletion actions.

#### Back up or move a connection library

Choose **File → Export Connections…**. A normal `.nethriva` archive preserves connection settings, favorites, groups, credential-profile names, usernames, and domains without passwords. It should still be treated as private. Enable **Include saved credentials** to create an encrypted `.nethriva-secure` archive containing individual and shared profile passwords, protected by a password of at least eight characters. Nethriva cannot recover that password.

Choose **File → Import Connections…** to inspect an archive before applying it. If matching connection or credential-profile identifiers already exist, choose whether to keep or replace them. Imported passwords are written into the active Debug or Release macOS Keychain service.

#### Reuse an administrator account

Open **Manage Credential Profiles…** from the toolbar or File menu. Create a named username and optional Windows domain, then optionally store its password in Keychain. In each SSH, Telnet, or RDP connection, select that profile from the **Credentials** picker. A password change in the profile applies to all linked connections on their next session or reconnect. Profiles cannot be deleted while in use. Linking a connection removes its old individual saved password; saving different credentials from an RDP login prompt detaches only that connection from the shared profile.

#### Connect to a serial console

Connect a USB serial-console adapter, then add a **Serial** connection. Select its `/dev/cu.*` port and the baud rate, framing, flow control, and local-echo settings required by the device. The editor can refresh the available ports. Open the connection in a tab; if the adapter is unplugged, reconnect after it reappears. Serial connections do not use the credential manager.

#### Work with SSH and remote files together

Opening an SSH connection creates a terminal with a remote filesystem tree beside it. Expand only the directories you need, drag local files or folders onto the tree to upload them, drag remote items between folders to move them, or drag a remote item to Finder to download it. The divider can be resized without interrupting the terminal.

#### Use the full SFTP browser

Open the SFTP browser when you need a larger file-management workspace. It supports navigation, directory creation, rename, upload, download, recursive folder transfer, move, and deletion of files or empty directories. It inherits the SSH connection's host, port, authentication, key, jump-host, agent, and compression settings.

#### Use an embedded Windows desktop

Opening an RDP connection places the desktop in the selected session tab. The desktop tracks the usable tab size, including sidebar changes, and can be magnified independently with Comfortable, Larger, or Largest interface scaling. Clipboard text, copied Finder items, and direct Finder drops can be sent to the active Windows desktop or Explorer window.

#### Open a VM console

Add a **Virtualization Host** connection, choose the platform, and enter its management endpoint and credentials. Open it to load the VM inventory; select a running VM and choose **Open Console**, or double-click its name. Use **VM Actions** in the inventory for power or media operations. For QEMU/libvirt and Hyper-V, use **Host SSH** first to verify an unfamiliar SSH host key. Direct VNC/SPICE endpoints can instead be saved as their own connections. See [docs/VIRTUALIZATION.md](docs/VIRTUALIZATION.md) for prerequisites and platform-specific fields.

## Data storage and privacy

- Connections and group names are stored locally in macOS user defaults.
- Passwords are stored as generic-password items in macOS Keychain. Individual passwords are keyed by connection UUID; shared credential-profile passwords are keyed by profile UUID.
- Saved passwords are accessible only while this Mac is unlocked and cannot migrate to another device through a backup.
- Password values are not written into the connection JSON or included in logged FreeRDP command arguments.
- Plain `.nethriva` exports never include passwords, but do contain connection and profile names, usernames, and domains. Password-bearing `.nethriva-secure` exports encrypt the complete archive with password-based AES-256-GCM and are created for current-user access only.
- Xcode Debug builds use development-only preferences and Keychain identifiers; Release builds retain the user's normal application library.
- Xcode's normal Run action uses an optimized Development configuration with the normal Release data profile and local signing permissions for the bundled RDP libraries. Production archives retain exception-free Release signing; local Development builds are not production-signed releases.
- Rebuilding or reinstalling the app does not erase either profile. The project and app bundle do not contain locally saved connections or Keychain passwords.
- Display privacy preferences are saved with the active Debug or Release profile and do not change connection records or exports.
- SSH uses the current macOS user's OpenSSH configuration, keys, agent socket, and `known_hosts` file.
- Temporary SSH multiplexing sockets use identity-scoped hashed names in an unpredictable, owned private directory. Nethriva closes its matching masters when their last tab closes or the app quits; it does not delete other process directories by name or stale PID.
- SFTP passwords travel to the authentication helper through a private pipe; file operations use bounded binary packets, not textual commands.
- A redacted diagnostic report can be exported from the Help menu without including connection identities, endpoints, credentials, paths, or session logs.
- Optional terminal output logs are private local files, off by default and excluded from archives/diagnostics. They can still contain private output despite label filtering; avoid printing credentials and review before sharing. Retention cleanup permanently removes expired app-owned logs.
- RDP defaults to NLA, TLS 1.2 or newer, and **Require Valid Certificate** with macOS system trust and hostname verification. Compatibility settings never silently enable weaker negotiation; ignored verification and legacy RDP require session confirmation.
- RDP clipboard and file sharing are disabled by default. Clipboard, microphone, folders, printers, smart cards, USB devices, and similar redirects remain under per-connection control; existing explicitly saved choices are retained.
- Virtualization API sessions use per-host ephemeral HTTP sessions. Cookies and generated console tokens are not exported or stored in preferences; explicit host credentials use the same Keychain/profile model as other connections.
- VNC/SPICE text clipboard access is off by default. Direct raw TCP is plaintext: saved/provider passwords are not supplied automatically, and a manually entered password requires one-session approval. Prefer verified TLS or secure WebSocket, or a suitable SSH tunnel. A tunnel protects its own leg; an exposed unencrypted final hop remains a risk.
- Nethriva does not provide cloud synchronization, telemetry, or a hosted relay service in this release.

## Troubleshooting

### macOS repeatedly asks for the login keychain password

This macOS dialog asks for the **login keychain password**, not the remote SSH or RDP password. Nethriva reads saved credentials without rewriting them; opening a connection editor checks only whether a password exists. If macOS rejects the password, open Keychain Access and check whether the **login** keychain unlocks with your current Mac login password or a previous one. Do not reset the keychain just to dismiss the prompt: resetting can remove saved passwords. See [Apple's keychain-password guidance](https://support.apple.com/guide/keychain-access/kyca2429/mac).

### SSH tab connects but will not accept a password

Click inside the terminal to give it keyboard focus. Password characters are intentionally not echoed. Type the password and press Return, paste it with Command-V, or use **Send Saved Password** when a Keychain password is available.

### SSH host authenticity prompt keeps returning

Confirm that the host, port, and fingerprint are correct, enter `yes` in the SSH terminal, and ensure the current macOS user can write to `~/.ssh/known_hosts`. A changed host key must be investigated rather than automatically replaced.

### Remote files do not appear

Establish and trust the SSH connection first, then refresh the tree or SFTP browser. Check that the server enables the SFTP subsystem, that the account can execute SFTP, and that it has permission to list the requested directory. Authentication, host-key, timeout, permission, and malformed-response errors are shown in the file browser.

### SSH or SFTP feels slow

Confirm latency and name resolution outside Nethriva, then check jump-host and compression settings. Nethriva reuses authenticated OpenSSH transports, but the first connection still performs DNS lookup, host-key verification, and authentication. Very large directories are faster when navigated through the lazy SSH tree instead of repeatedly refreshing a broad SFTP listing.

### Telnet does not connect or accept input

Confirm that the device exposes Telnet on the configured port and that no firewall blocks it. Click inside the terminal before typing. If the device needs negotiation that it does not advertise correctly, capture a redacted diagnostic report and open a GitHub issue. Remember that Telnet traffic is unencrypted.

### RDP reports logon failure

Verify the username, password, and domain. For Active Directory accounts, use `DOMAIN\\username` or fill the Domain field separately. Confirm that the Windows account is allowed to use Remote Desktop and that Network Level Authentication accepts the supplied account.

### VMware console reports a TLS or ticket error

Rebuild the latest source and reconnect for a fresh ticket. VMware uses an isolated native TLS/WebSocket transport with TLS 1.2 or newer and ticket certificate verification, without an app-wide transport-security exception. The message distinguishes a certificate mismatch, missing ticket identity with system-trust failure, TLS negotiation failure, or a later console connection failure. Share only that message and its numeric TLS/network code, plus host software versions; never share credentials or ticket URLs. Verify direct ESXi reachability and investigate certificate mismatches in vCenter rather than bypassing validation. See [VMware setup and troubleshooting](docs/VIRTUALIZATION.md#vmware-esxi--vcenter).

### VM console connects but the display is blank

Update and rebuild an older 0.13.0 development checkout: an unused SPICE container could push the VNC/VMware canvas below the visible tab even while it decoded pixels correctly. The selected renderer now exclusively occupies the console area, and tests verify canvas visibility as well as decoding. If a current build still shows black, compare the same guest in the host's console and check guest screen blanking; a connected status alone does not prove that the guest is displaying a usable screen.

### RDP pointer or interface size feels wrong

Use a resizable app window and let the connection settle after a layout change. Choose Larger or Largest for more readable Windows controls. Nethriva sends logical tab dimensions rather than Retina backing-pixel dimensions and recalculates the remote layout when the sidebar or window changes.

### RDP clipboard or file transfer does not work

Enable **Share clipboard and enable file transfers** for the connection and confirm that the Windows host or its policy permits clipboard redirection. Sharing is off by default. With the RDP pane focused, copy a Finder item and use the RDP paste action, or drop the item directly over the intended remote desktop or Explorer destination.

### Xcode cannot resolve packages

Check network access, choose **File → Packages → Reset Package Caches**, and build again. Package versions are pinned in `Package.resolved`. After replacing an older project archive, use **Product → Clean Build Folder** so Xcode does not reuse stale products.

## Current limitations

- The bundled RDP runtime is currently built for Apple silicon; an Intel-compatible RDP bundle is not included.
- Recursive deletion of non-empty remote SFTP directories is intentionally disabled.
- SFTP does not automatically trust an unknown SSH host key; approve the host through an SSH tab first.
- Telnet has no transport encryption or server-identity verification and should be limited to trusted management networks.
- Connection and group data are local to the current Mac user and are not synchronized between Macs.
- There is no automatic synchronization or hosted credential-sharing service. Shared libraries use reviewed files/manual revisions; provider references stay local and must be configured on each Mac. Supported external providers are 1Password CLI and Vault KV v2, not every password manager.
- RDP device redirection depends on both FreeRDP support and the remote Windows host's policy and configuration.
- Gateway passwords do not have a separate saved-credential field in the current connection editor.
- Apple Developer ID signing, notarization, automatic updates, and a polished installer remain future deployment work. Local ZIP and DMG packaging is automated for unsigned open-source releases.

## Technology stack

| Area | Technology |
|---|---|
| Application language | Swift |
| Project and build system | Xcode project with Swift Package Manager dependencies |
| Application UI | SwiftUI with focused AppKit integration |
| Terminal emulation | SwiftTerm 1.99.3 |
| SSH terminal transport | macOS OpenSSH and pseudo-terminal process hosting |
| Telnet transport | Network.framework TCP with an embedded Telnet negotiation layer |
| Serial transport | POSIX termios with discovered macOS `/dev/cu.*` devices |
| SFTP operations | macOS SFTP with reusable OpenSSH control connections |
| RDP | Bundled FreeRDP 3.33.1 and an Objective-C/Cocoa bridge |
| VM management | URLSession REST/JSON-RPC/SOAP adapters and system SSH/PowerShell/virsh |
| VM consoles | Bundled noVNC 1.7.0 and SPICE HTML5 in nonpersistent WebKit, native TCP/WSS, or the host's web console |
| Credentials | macOS Security framework and Keychain |
| Connection persistence | Versioned Codable records with last-known-good backup through `UserDefaults` |
| Cryptography support | CryptoKit AES-256-GCM and PBKDF2-HMAC-SHA256 for credential exports, system OpenSSH security, and OpenSSL within the bundled RDP runtime |
| Tests | XCTest plus native RDP bridge smoke validation |

The package lock records the exact revisions used by the project. Third-party notices for the bundled RDP runtime are under `Nethriva/Resources/FreeRDP/ThirdPartyLicenses` and summarized in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Support Nethriva

Nethriva is free and open-source software. If it saves you time and you would like to support its continued development, you can leave a [one-time tip through Ko-fi](https://ko-fi.com/vsharapov) or [sponsor the project through GitHub Sponsors](https://github.com/sponsors/vitalii-sharapov). Support is entirely optional and does not change the features or permissions provided by the Apache License 2.0.

## License and contributing

Nethriva is licensed under the [Apache License 2.0](LICENSE). Third-party components remain under their respective licenses. See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change and [SECURITY.md](SECURITY.md) for safe vulnerability reporting.

## Release notes

### 0.13.0 — build 30

- Fixed SSH control-socket creation on macOS by reserving OpenSSH’s temporary suffix while preserving credential/key/forwarding context isolation.
- Fixed local Xcode RDP loading through an optimized Development run configuration; production archives retain strict Release signing. RDP error messages now have readable light/dark contrast and selectable, scrollable details.
- Added adjustable two-to-four SSH pane groups; new unrelated sessions open alone and selecting a group member restores its sizes.
- Updated the complete managed dependency stack, including SwiftTerm 1.99.3, noVNC 1.7.0 and the FreeRDP/WinPR 3.33.1/OpenSSL 4.1.0 native runtime. Every version build checks current upstream versions.
- Hardened imported credential authority, SSH/terminal/SFTP boundaries, RDP trust/defaults and native resource ownership. See [security evidence and unresolved acceptance](SECURITY_TESTING.md); release status is not production security certification.

- Added reviewed shared connection libraries with personal overrides/conflict merging, credential-free destination changes, asynchronous 1Password/Vault password retrieval, and an authenticated app privacy lock. See [setup and safety limits](docs/SHARING_PRIVACY.md). Lock disconnects sessions rather than leaving hidden clipboard/remote channels running.

- Added safe confirmed multi-session commands, terminal appearance/output search, opt-in private output logging, connection templates/group inheritance, bulk metadata editing and previewed SSH/RDP/CSV/XML migration imports. See [library tools and safety limits](docs/LIBRARY_TOOLS.md).

- Split and detached live sessions, graphical local/remote/SOCKS SSH tunnels, ordered jump hosts, Command-K connection/VM/action search, safe remote text editing, and parameterized command snippets. See [workflow details](docs/WORKFLOWS.md).

- Added virtualization-host connections and searchable VM inventories for Proxmox, VMware ESXi/vCenter, QEMU/libvirt, Hyper-V, Xen Orchestra, and Nutanix AHV.
- Added tabbed VM consoles and direct VNC/SPICE connections, optional SSH forwarding, fit/view-only/input controls, and opt-in text clipboard sharing.
- Added Ctrl+Alt+Del to embedded RDP and VNC/SPICE consoles.
- Added confirmed VM power operations and host-side ISO/guest-tools media actions where supported.
- Added ephemeral host authentication, certificate-policy controls, bundled console dependency notices, setup guidance, and automated console tests.
- Fixed rejection of valid VMware inventory-view references after login and added clearer, redacted SOAP error handling with mock workflow regression tests.
- Replaced the VMware web-page fallback with direct, one-time WebMKS console tickets and bundled noVNC; added isolated console TLS, ticket certificate verification, and reconnect with a fresh ticket.
- Added support for VMware thumbprints with an omitted optional algorithm field and specific, redacted console TLS/ticket failure messages.
- Moved VMware ticket sockets to isolated native TLS/WebSocket networking with TLS 1.2 or newer, avoiding URLSession transport-security restrictions on ticket-authorized private certificates without adding a global security exception.
- Corrected WebMKS URL precedence over separate host/port metadata, supported omitted endpoints for API-confirmed standalone ESXi, and added field-specific ticket validation errors without exposing ticket values.
- Fixed a blank VNC/VMware console caused by an unused SPICE container pushing the rendered display below the tab; added viewport-visibility and renderer-selection regression checks.
- Added a visible **Fit Screen** console button and separated local scaling from optional guest-resolution changes.
- Virtualization adapters require live host acceptance testing; platform/API/guest limitations are documented rather than assumed supported.

### 0.12.1

- Reduced the height of the macOS title bar, session tabs, and RDP controls for a larger usable desktop area.
- Added **Remove Group…** for groups and subgroups. Removal asks for confirmation, removes nested groups, and moves their connections to Ungrouped without deleting saved credentials. Favorite markers are cleared so moved connections remain visible.
- Added tests for nested-group removal, protected groups, and recovery when saving fails.

### 0.12.0

- Added native Serial sessions with available-port discovery, configurable line settings, local echo, paste, and reconnect.
- Added reusable credential profiles for SSH, Telnet, and RDP. Profiles share a Keychain password across linked connections and support password rotation without editing every client.
- Added a separate Credential Profiles manager, connection-editor profile selection, and safe handling when an RDP login prompt saves credentials for a linked connection.
- Extended connection-library import/export to preserve profile definitions and links, with profile passwords included only in encrypted exports.
- Added Telnet login/username prompt assistance alongside saved-password assistance.
- Improved connection organization with nested groups, search, multi-selection, drag-and-drop moves, and quick rename actions.

### 0.11.0

- Added native tabbed Telnet sessions for legacy devices, including option negotiation, resize updates, paste, saved-password assistance, reconnect, and clear plaintext warnings.
- Hardened SFTP password delivery and command validation.
- Added versioned, recoverable connection persistence and stricter device-local Keychain protection.
- Added saved-password removal, explicit SSH multiplex shutdown, stale temporary-directory cleanup, and redacted diagnostic export.
- Replaced the remaining RDP bridge binary and exported names with Nethriva identifiers and scoped OpenSSL provider setup to the embedded bridge.
- Removed the unused embedded SSH dependency path so the production project has a single supported OpenSSH implementation.
- Added GitHub CI, issue templates, release packaging scripts, a release checklist, and a compatibility matrix.
- Added connection-library import/export with preserved group structure, optional encrypted credentials, import preview, and duplicate policies.
- Isolated Xcode Debug connection and Keychain data from the user's Release-profile library.
- Added app-wide Settings with separate sidebar and session header address and username visibility controls.
- Fixed embedded RDP credential and certificate dialogs so prompts no longer depend on missing window resources or crash when a username was not saved.
- Added an opt-in **Save credentials in Keychain** checkbox to the RDP login prompt; successful logins update the saved username/domain and Keychain password, while failed or cancelled attempts are not saved.

### 0.10.0

- Added a complete offline Nethriva help manual bundled with the application.
- Added a dedicated native help window with a navigable table of contents, full-text highlighting, light and dark appearance support, and print-friendly formatting.
- Added Help-menu and toolbar entry points plus the standard Command-? shortcut.
- Added coverage for connection setup, local terminal, SSH, remote file navigation, SFTP, RDP, file transfer, security, troubleshooting, and current limitations.

### 0.9.1

- Added the Nethriva wordmark and complete macOS icon catalog.

## Project structure

```text
Nethriva/
├── App/                       Application entry point and shared state
├── Models/                    Connections, credential profiles, and session-tab models
├── Services/                  Persistence, Keychain, serial, SFTP, and FreeRDP adapters
├── Resources/Help/            Bundled offline HTML help manual
├── Resources/FreeRDP/         Bundled RDP runtime and third-party notices
├── Resources/Consoles/        Bundled VNC/SPICE modules and licenses
└── Views/
    ├── Help/                  Native help-window integration
    ├── Sidebar/               Connection manager and protocol editors
    ├── Settings/              Credential Profiles manager
    └── Sessions/              Terminals, file browsers, RDP, VM inventories, and VM consoles
NethrivaTests/               Model, persistence, lifecycle, and argument tests
Vendor/NethrivaRDPBridge/    Source for the native embedded RDP bridge
docs/                          Architecture and integration notes
scripts/                       Repeatable ZIP and DMG release packaging
```

Additional implementation and packaging details are available in [`docs/INTEGRATION_PLAN.md`](docs/INTEGRATION_PLAN.md). Brand usage and reproducible asset prompts are documented in [`docs/BRAND_ASSETS.md`](docs/BRAND_ASSETS.md).

Durable development context is maintained in [`docs/PROJECT_CONTEXT.md`](docs/PROJECT_CONTEXT.md), with future priorities tracked in [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Command-line build verification

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/prepare-swift-packages.sh /private/tmp/NethrivaPackages
xcodebuild -project Nethriva.xcodeproj \
  -scheme Nethriva \
  -configuration Debug \
  -clonedSourcePackagesDirPath /private/tmp/NethrivaPackages \
  -skipPackagePluginValidation \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The test target also runs directly from Xcode. Restricted automation environments may block macOS package or test services even when the project itself builds normally in Xcode.
