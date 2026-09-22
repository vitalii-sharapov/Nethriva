# Nethriva project context

This document gives future development tasks a compact, durable understanding of Nethriva. It should be updated whenever architecture, supported platforms, release procedures, or major product priorities change.

## Product

Nethriva is a free, open-source, native macOS connection manager for local terminal, SSH, Telnet, SFTP, and RDP sessions. It is written in Swift, uses SwiftUI for the application shell, and integrates focused AppKit views for terminal and remote-desktop behavior.

- Public repository: <https://github.com/vitalii-sharapov/Nethriva>
- License: Apache License 2.0
- Current project version: 0.11.0 (build 24; not yet published)
- Minimum macOS version: macOS 14
- Current bundled RDP architecture: Apple silicon
- GitHub Sponsors: <https://github.com/sponsors/vitalii-sharapov>
- Ko-fi: <https://ko-fi.com/vsharapov>

Nethriva is the only public product identity and must be used consistently in all public-facing content.

## Implemented experience

### Workspace and connections

- Native resizable macOS window with a hideable connection sidebar
- Persistent custom groups, favorites, and saved SSH/Telnet/RDP connections
- Create, edit, duplicate, move, favorite, and delete actions
- Import/export with group preservation, optional encrypted Keychain credentials, preview, and duplicate policies
- Separate Debug and Release preferences and Keychain services so development data cannot enter packaged builds
- Independent tabbed local terminal, SSH, Telnet, SFTP, and RDP sessions
- macOS Keychain-backed saved passwords
- Complete bundled offline help manual
- Native Settings window with separate sidebar and session header visibility controls for addresses and usernames; usernames default to hidden

### Local terminal and SSH

- SwiftTerm rendering with real pseudo-terminal processes
- macOS login shell for local sessions
- macOS OpenSSH for SSH compatibility
- Password, keyboard-interactive, public-key, agent, identity-file, jump-host, keepalive, and compression support
- Correct terminal focus, resize behavior, selection, Command-V paste, and secondary-click paste
- Standard OpenSSH `known_hosts` trust behavior

### Telnet

- Network.framework TCP transport rendered through SwiftTerm
- Echo, suppress-go-ahead, terminal-type, and window-size option negotiation
- Keyboard input, paste, resizing, saved-password assistance, and reconnect
- Persistent plaintext warnings; intended only for trusted legacy management networks

### Remote files and SFTP

- Compact, resizable remote filesystem tree beside each SSH session
- Lazy directory expansion and reusable authenticated OpenSSH control connections
- Dedicated SFTP tab for detailed file management
- Upload, recursive folder upload, download, recursive folder download, rename, move, folder creation, and safe deletion
- Drag local items into remote folders, move remote items between folders, and drag remote items to Finder

### Embedded RDP

- FreeRDP 3.31.1 with an in-process native Cocoa bridge
- RDP desktops rendered inside Nethriva tabs
- NLA credentials and domain-qualified usernames
- Optional save-on-success checkbox in the RDP authentication prompt; passwords go to Keychain and usernames/domains to connection metadata
- Correct mouse, trackpad, keyboard, focus, pointer scaling, and logical Retina sizing
- Dynamic resolution after app-window and sidebar changes
- Per-connection interface scaling
- Bidirectional Unicode clipboard and Finder file/folder transfer
- Audio, microphone, folder, printer, smart-card, USB, gateway, certificate, administrative-session, network-profile, graphics, and reconnect controls
- Sensitive redirection capabilities remain opt-in

## Architecture map

```text
Nethriva/App                 Application entry point and shared state
Nethriva/Models              Connection and session-tab models
Nethriva/Services            Persistence, Keychain, SSH/SFTP, and RDP services
Nethriva/Views/Sidebar       Connection library and editors
Nethriva/Views/Sessions      Terminal, Telnet, file, tab, and RDP surfaces
Nethriva/Views/Help          Native offline-help host
Nethriva/Resources           Assets, help, and bundled FreeRDP runtime
Vendor/NethrivaRDPBridge     Objective-C/Cocoa FreeRDP bridge source
NethrivaTests                XCTest coverage
```

## Data and security rules

- Connection metadata is stored in a versioned local record with a last-known-good backup; groups remain local through `UserDefaults`.
- Passwords are device-local generic-password items in macOS Keychain keyed by connection UUID and available only while the Mac is unlocked.
- Passwords must never appear in stored connection JSON, logs, tests, documentation, release metadata, or external RDP process arguments.
- Plain connection exports must reject credentials. Credential-bearing exports must encrypt the complete archive with authenticated encryption and a password-derived key.
- Debug builds must remain isolated from Release preferences and Keychain identifiers. Never add an automatic fallback that reads personal Release data into Debug.
- App display privacy settings apply to Nethriva labels. Remote shell output and user-provided connection names are outside their scope.
- SSH uses the current macOS user's configuration, keys, agent, and `known_hosts` file.
- SFTP passwords must use the private input pipe; never reintroduce password environment variables. Reject control characters in textual SFTP commands.
- Telnet is unencrypted. Never describe it as protecting credentials, server identity, or session data.
- RDP credentials are passed to the embedded client in-process.
- Certificate behavior is configurable per RDP connection; valid-certificate enforcement is the strictest option.
- Never commit real client records, usernames, addresses, keys, credentials, or infrastructure screenshots.

## Build and verification

Open `Nethriva.xcodeproj`, select the `Nethriva` scheme and `My Mac`, then build or run. Command-line verification:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Nethriva.xcodeproj \
  -scheme Nethriva \
  -configuration Debug \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Run the `NethrivaTests` target for model, persistence, lifecycle, Telnet negotiation, SFTP hardening, connection archives, data-profile isolation, diagnostic redaction, argument-construction, and RDP sizing coverage. Native bridge changes also require smoke validation of bridge creation, runtime loading, sizing, startup-failure handling, shutdown, and signing behavior. GitHub Actions repeats the tests, creates an unsigned Release build, and validates the bundled bridge export.

## Distribution

The source and the current locally signed Apple-silicon release are hosted on GitHub. A paid Apple Developer membership is not required for source builds or local-signing distribution. Because the downloadable build is not Developer ID signed or notarized, users may need to approve its first launch through **System Settings → Privacy & Security → Open Anyway** after reviewing the source and checksum.

Release artifacts must not contain saved connection databases, Keychain material, local logs, Derived Data, or private test information. Publish application archives on GitHub Releases rather than committing binaries to the source tree.

## Current direction

The core SSH, Telnet, SFTP, local terminal, embedded RDP, help, GitHub release, issue tracker, GitHub Sponsors, and Ko-fi workflows are operational. Current priorities are stability, broader compatibility, and community-driven improvements. See `docs/ROADMAP.md` for the maintained priority order.
