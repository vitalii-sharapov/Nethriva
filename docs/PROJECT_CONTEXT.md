# Nethriva project context

This document gives future development tasks a compact, durable understanding of Nethriva. It should be updated whenever architecture, supported platforms, release procedures, or major product priorities change.

## Product

Release checkpoint (2026-11-11): **v0.13.0/build 30 preview**, including the socket-length and local RDP signing/readability fixes. Main/tag/binary publication is a deliberate release operation; the preview is ad-hoc signed and unnotarized, with production/advisory/live-platform acceptance still incomplete. See [the release record](releases/0.13.0.md). Older dated build-27/28/29 evidence below remains historical.

RDP Xcode follow-up (2026-11-11): direct ad-hoc Release Run could not load native libraries under exception-free Hardened Runtime library validation. Run now uses optimized Development with existing local entitlements and the normal Release data profile; Debug stays isolated, Archive/Profile stay strict Release. Development also runs the complete fresh component/receipt gate. The RDP status panel now uses an opaque adaptive background and primary selectable text in a bounded scroll region, replacing low-contrast material/secondary text. Actual hosted canvas loading and signing/build invariants have regressions; see the local follow-up report for acceptance scope. No server login or production-signing acceptance is implied.

Dependency update (2026-11-11, build 29): current source 0.13.0/build 29 uses SwiftTerm 1.99.3, noVNC 1.7.0, SPICE 85262d0, OpenSSL 4.1.0, FDK-AAC 3.0.0 and CMake 4.4.5. Xcode 27.2 was installed from Apple; the native bundle was rebuilt end-to-end with that toolchain, preserving generic arm64/M1/macOS 14 targets. The new terminal API uses app-owned bounded PTY delivery so ingress filtering, prompt observation and recording remain before/after the correct parser boundary. Real local PTY input/output/backpressure tests accompany the upgrade. Every Release/archive build performs a fresh complete upstream check with a sandboxed single-use receipt gate; reviewed plugin hashes allow headless builds without global Xcode security changes. Final results/export locations are in `docs/DEPENDENCY_UPDATES.md` and local project notes. Earlier dated build28 evidence below remains historical. No publication or saved-data reset.

Security hardening checkpoint (2026-11-11): current local source is unpublished 0.13.0/build 28. The source resource bundle now contains FreeRDP/WinPR 3.33.1 with OpenSSL 3.5.9 LTS, source locks, SBOM/provenance, recorded SDL diagnostic-label and bounded-GFX patches, and 18 native binaries targeting generic arm64/M1 and macOS 14. The exact-bundle integrity/version/provider gate passed; final full app regression and production release acceptance are recorded separately in `SECURITY_TESTING.md`. New RDP defaults are NLA, system certificate/hostname verification and clipboard/file sharing off. Import credential authority, private SSH reuse, terminal clipboard/prompt handling, SFTP descriptor boundaries and raw-console password handling were hardened. Existing saved choices/data and old exports remain preserved. No Developer ID/notarized distributable, publication, other-chip certification or live-server acceptance is claimed. See `SECURITY_AUDIT.md` and `SECURITY_HARDENING.md`.

Split workspace follow-up (2026-11-03): session selection is separate from split membership, so newly opened RDP/SFTP/other tabs appear alone and selecting a grouped SSH tab restores its panes and sizes. Explicit Add to SSH Split supports three/four SSH terminals; unrelated types can still be explicitly paired. Twelve-point native divider handles use captured window-coordinate drags to resize only adjacent panes, with equal-size reset and remove-from-split actions. Geometry updates do not replace live hosting roots. Closing/detaching a member preserves the remaining group. Membership/sizing remain session-only. The new-session regression failed before the change; all 205 tests pass after it, including native four-pane handle hit testing, actual divider event/geometry updates, retained surfaces and RDP-single/SSH-group restoration. No saved records/credentials or server settings changed, and no live-server command was needed. Source remains local 0.13.0/build 27, uncommitted/unpublished.

Apple silicon startup follow-up (2026-10-22): Debug/Release arm64 C and Swift builds now explicitly pin the M1 CPU baseline. Package checks require generic ARM64_ALL slices, macOS platform, compatible native minimum OS and portable load/search paths; ten signed packaging/native-fixture checks pass. The rebuilt Release passed all 199 tests, fresh ZIP verification (27 native binaries), isolated LaunchServices workspace startup and RDP/provider/canvas smoke on M5 Pro/macOS 27.0.1. Intended M1–M6 support on hardware-supported macOS 14+ remains distinct from actual chip/OS coverage; M1/M2/M3/M4/M6, older OS versions and independent clean-machine Gatekeeper acceptance remain unverified. An initial restricted command launch aborted during system application registration; the identical binary worked with desktop-service access, and the corrected LaunchServices harness passes. No installation, commit, publication or personal-data reset occurred.

Local acceptance follow-up (2026-10-22): fixed cold SFTP startup on OpenSSH 10 by authenticating a command-free owned system SSH master instead of relying on `sftp` to create one. Private password pipes and host-trust refusal remain; no remote/local startup command or inherited forwarding is run. Uploads refresh local file metadata at both boundaries, fixing stale retained URLs and same-size source-change detection before publication. Both metadata regressions failed before the fix; the full suite now passes 199 tests with zero failures/skips/runtime warnings. Approved disposable-host checks passed cold service login, independent worker/channel reuse, conflict policies, nested literal/Unicode names, 32 MiB integrity, cancellation/retry, special-file refusal and cleanup. These do not certify remaining GUI/device/provider/OS matrices. Source remains 0.13.0/build 27, local/unpublished; existing personal records and dirty development work were preserved.

Nethriva is a free, open-source, native macOS connection manager for local terminal, SSH, Telnet, Serial, SFTP, and RDP sessions. It is written in Swift, uses SwiftUI for the application shell, and integrates focused AppKit views for terminal and remote-desktop behavior.

- Public repository: <https://github.com/vitalii-sharapov/Nethriva>
- License: Apache License 2.0
- Current project version: 0.13.0 (build 30), preview
- Minimum macOS version: macOS 14
- Current bundled RDP architecture: Apple silicon
- GitHub Sponsors: <https://github.com/sponsors/vitalii-sharapov>
- Ko-fi: <https://ko-fi.com/vsharapov>
- Product Hunt listing (user-reported): <https://www.producthunt.com/products/nethriva?launch=nethriva>
- MacUpdate listing: submitted; awaiting moderator review as of 2026-09-23. Verify its status before linking to or describing it as published.

Nethriva is the only public product identity and must be used consistently in all public-facing content.

## Implemented experience

### Workspace and connections

- Native resizable macOS window with a hideable connection sidebar
- Compact title bar, session tabs, and RDP controls to preserve desktop space
- Persistent nested groups, favorites, and saved SSH/Telnet/Serial/RDP connections
- Search by name, host/IP, group path, or port; create, edit, quick-rename, duplicate, multi-select, drag-and-drop move, favorite, and delete actions
- Confirmed removal of a group or subgroup moves all nested connections to Ungrouped while retaining saved credentials
- Import/export with group and credential-profile links preserved, optional encrypted individual and shared Keychain credentials, preview, and duplicate policies
- Separate Debug and Release preferences and Keychain services so development data cannot enter packaged builds
- Independent tabbed local terminal, SSH, Telnet, Serial, SFTP, and RDP sessions
- macOS Keychain-backed saved passwords
- Reusable credential profiles: local name/username/domain metadata, one Keychain password, and per-connection profile references
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
- Keyboard input, paste, resizing, saved-username/password prompt assistance, and reconnect
- Persistent plaintext warnings; intended only for trusted legacy management networks

### Serial

- Native POSIX serial-device sessions rendered in SwiftTerm tabs
- `/dev/cu.*` adapter discovery and refresh, plus manual device path entry
- Saved baud, data bits, parity, stop bits, flow control, and local echo
- USB adapter removal/error reporting and per-tab reconnect
- Serial settings persist in connection records without usernames or passwords

### Remote files and SFTP

- Compact, resizable remote filesystem tree beside each SSH session
- Lazy directory expansion and reusable authenticated OpenSSH control connections
- Dedicated SFTP tab for detailed file management
- Upload, recursive folder upload, download, recursive folder download, rename, move, folder creation, and safe deletion
- Drag local items into remote folders, move remote items between folders, and drag remote items to Finder

### Embedded RDP

- FreeRDP 3.33.1 with an in-process native Cocoa bridge and OpenSSL 3.5.9 LTS
- RDP desktops rendered inside Nethriva tabs
- NLA by default with TLS 1.2 minimum, system certificate/hostname verification, and domain-qualified usernames
- Optional save-on-success checkbox in the RDP authentication prompt; passwords go to Keychain and usernames/domains to connection metadata
- Correct mouse, trackpad, keyboard, focus, pointer scaling, and logical Retina sizing
- Dynamic resolution after app-window and sidebar changes
- Per-connection interface scaling
- Opt-in bidirectional Unicode clipboard and Finder file/folder transfer, disabled by default
- Audio, microphone, folder, printer, smart-card, USB, gateway, certificate, administrative-session, network-profile, graphics, and reconnect controls
- Sensitive redirection capabilities remain opt-in
- Ctrl+Alt+Del toolbar action, also used by Hyper-V VMConnect consoles

### Virtualization (new in 0.13.0; live host validation pending)

- Virtualization Host connections: Proxmox VE, VMware ESXi/vCenter, QEMU/libvirt, Hyper-V, Xen Orchestra, and Nutanix AHV through Prism Central
- Searchable inventory, independent console tabs, confirmed lifecycle operations, and host-side ISO/guest-tools media requests
- Direct VNC/SPICE connections, opt-in text clipboard, view-only, fitting, input release, and optional SSH forwarding
- Bundled unmodified noVNC 1.6.0 and SPICE HTML5 modules hosted by nonpersistent WebKit; native TCP/WSS transports controlled by Swift
- VMware uses `AcquireTicket(webmks)` with bundled noVNC over direct WSS, not a host web page or proprietary SDK; Hyper-V reuses FreeRDP VMConnect on port 2179
- VMware ticket endpoints use a separate cookie/HTTP-credential-free session, reject redirects, and verify the ESXi leaf certificate against the API-issued SHA-256/legacy SHA-1 thumbprint or PEM certificate. Missing pins require system trust. Tickets remain native/in-memory; reconnect requests a fresh ticket. Interactive federation now has an experimental registered-client PKCE/MFA/token-exchange/SAML bearer flow, requiring administrator setup and live acceptance; successful inventory credentials can authorize console tickets independently of web SSO.
- REST/JSON-RPC/SOAP over per-host ephemeral HTTP sessions; SSH helpers use private input pipes and safe quoting/encoded PowerShell
- Certificate verification defaults strict; optional fingerprint-based first-use trust; tokens/tickets remain in memory
- Automated module loading and a synthetic VNC connection with Ctrl+Alt+Del passed; actual hypervisor/guest compatibility remains unverified
- Detailed setup, prerequisites, protocol limits, and source references: `docs/VIRTUALIZATION.md`

## Architecture map

```text
Nethriva/App                 Application entry point and shared state
Nethriva/Models              Connection and session-tab models
Nethriva/Services            Persistence, Keychain, SSH/SFTP, and RDP services
Nethriva/Views/Sidebar       Connection library and editors
Nethriva/Views/Sessions      Terminal, Telnet, Serial, file, tab, and RDP surfaces
Nethriva/Views/Settings      Credential Profiles manager
Nethriva/Views/Help          Native offline-help host
Nethriva/Resources           Assets, help, FreeRDP, and VNC/SPICE console modules
Vendor/NethrivaRDPBridge     Objective-C/Cocoa FreeRDP bridge source
NethrivaTests                XCTest coverage
```

## Data and security rules

- Connection metadata is stored in a versioned local record with a last-known-good backup; groups remain local through `UserDefaults`.
- Passwords are device-local generic-password items in macOS Keychain keyed by connection UUID and available only while the Mac is unlocked.
- Shared profile passwords are Keychain items keyed by profile UUID. A linked connection stores only the profile UUID, not a password copy.
- Passwords must never appear in stored connection JSON, logs, tests, documentation, release metadata, or external RDP process arguments.
- Plain connection exports must reject credentials. Credential-bearing exports must encrypt the complete archive with authenticated encryption and a password-derived key.
- Debug builds must remain isolated from Release preferences and Keychain identifiers. Never add an automatic fallback that reads personal Release data into Debug.
- App display privacy settings apply to Nethriva labels. Remote shell output and user-provided connection names are outside their scope.
- SSH uses the current macOS user's configuration, keys, agent, and `known_hosts` file.
- SFTP authentication passwords must use the private input pipe; never reintroduce password environment variables. File operations use bounded binary SFTP packets and reject unsafe path components/control characters; expect receives only the fixed authentication handshake, never user file commands.
- Telnet is unencrypted. Never describe it as protecting credentials, server identity, or session data.
- RDP credentials are passed to the embedded client in-process.
- VM API passwords/tokens use Keychain when saved; temporary login and generated tickets/cookies must never enter connection metadata, diagnostics, or exports.
- TCP VNC/SPICE is plaintext unless tunneled. Console clipboard access is opt-in and distinct from RDP file transfer.
- Certificate behavior is configurable per RDP connection; valid-certificate enforcement is the strictest option.
- Never commit real client records, usernames, addresses, keys, credentials, or infrastructure screenshots.

## Build and verification

Release packaging now preserves symlinks/Unix executable permissions and strictly verifies both the extracted ZIP and the app on the mounted DMG. `package-app.sh` can package a previous signed Xcode export without rebuilding current source; `verify-release-archive.sh` rechecks downloaded assets, and `test-release-packaging.sh` rejects lost permissions, flattened links, wrong versions and overwrite. A native RDP smoke script loads the extracted runtime/providers and creates/resizes/destroys its canvas without network or credentials. The public 0.12.1 asset was found to lose executable permissions and flatten 28 sealed links; a repaired local package uses the original unchanged 0.12.1/build 26 export, not the unfinished 0.13.0 work. Local preparation is not publication or notarization. See RELEASE_CHECKLIST.md; remote CI, clean-machine first launch and actual M1 acceptance still require verification.

Open `Nethriva.xcodeproj`, select the `Nethriva` scheme and `My Mac`, then build or run. Command-line verification:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Nethriva.xcodeproj \
  -scheme Nethriva \
  -configuration Debug \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Run the `NethrivaTests` target for model, persistence, lifecycle, Telnet negotiation, Serial settings/discovery, shared credential profiles, SFTP hardening, connection archives, data-profile isolation, diagnostic redaction, argument-construction, and RDP sizing coverage. Native bridge changes also require smoke validation of bridge creation, runtime loading, sizing, startup-failure handling, shutdown, and signing behavior. GitHub Actions repeats the tests, creates an unsigned Release build, and validates the bundled bridge export.

Virtualization tests cover models, safe host/shell/XML inputs, inventory parsing, a mocked VMware login/inventory workflow, SOAP fault classification/redaction, Hyper-V arguments, bundled WebKit modules, and a local synthetic VNC server. VMware session-scoped inventory views use bracketed managed references; the VMware-specific validator accepts these without loosening other platforms' identifiers. SOAP HTTP 500 faults are parsed into safe errors rather than exposing raw host response text. Passing these does not validate a real VMware, Proxmox, Hyper-V, libvirt, Xen Orchestra, or Nutanix deployment. Mark manual interoperability results explicitly; never advertise untested API versions as verified.

Direct VMware console follow-up (2026-10-09): all 91 tests passed, including SOAP schema negotiation and ticket validation, a synthetic TLS/WebSocket RFB framebuffer/VMware cursor and Ctrl+Alt+Del path, transport isolation, and certificate mismatch rejection. TLS fixtures are generated locally and imported only into process memory (those tests skip on macOS 14, which lacks memory-only PKCS#12 import). No private host or real credentials were used. Live vCenter/ESXi WebMKS acceptance remains pending.

TLS diagnosis follow-up: the user reported a console rejection, but the previous message grouped cancellation and handshake errors with certificate failures. Added optional-algorithm thumbprint parsing, shared session/task challenge handling, locked per-transport trust outcomes, and redacted stage-specific errors. All 94 tests passed, including live synthetic SHA-1/omitted-algorithm TLS acceptance and strict wrong/missing-pin rejection; Debug and Release builds succeeded. The actual deployment's failure cause is still unconfirmed; user must rebuild and report the new safe error if it persists. No host or personal credentials were accessed.

Matched-pin TLS follow-up: a subsequent safe error established that the ticket pin matched before URLSession failed with -1200. ATS restrictions are a plausible cause, not a verified host diagnosis. VMware ticket sockets now use native Network.framework TLS/WebSocket, minimum TLS 1.2, exact ticket pins or normal chain/hostname validation when absent, strict header isolation, and no redirects. No global ATS exception or automatic insecure fallback was added; API/other console paths remain unchanged. All 95 tests pass, including the actual native transport, hostname-based pin acceptance, wrong/missing-pin rejection, blocked redirects, rendering, and input. Real ESXi/vCenter retest remains necessary.

Ticket-parser follow-up (2026-10-11): fixed rejection of API-supplied WebSocket URLs whose separate host/port metadata differs, following VMware's documented URL precedence. Added fallback for omitted standalone ESXi endpoints only after API-confirmed HostAgent, never for vCenter. Invalid tickets now report fixed field labels without values. All 98 tests pass, including URL precedence, endpoint fallback boundaries, field-error redaction, and encrypted console rendering/input with differing metadata; Debug and Release builds succeed. The private host's rejected field is not confirmed; user rebuild/retest remains required. Source remains 0.13.0 build 27, local and unpublished.

Blank-console follow-up (2026-10-11): live UI inspection observed working VMware inventory and a Connected RFB console with a black tab. Found an app layout defect: the full-height, unused SPICE host preceded noVNC's appended container, placing its decoded canvas below the viewport. Hide that host by default and reveal it only for SPICE. The viewport regression failed before the fix; all 98 tests now pass with visible-canvas and VNC/SPICE mode assertions. Debug and Release builds succeed; upstream assets remain unmodified. User must rebuild the active Xcode app and confirm the live guest display. No credential values, private screenshots, or host identities were added to source or docs. Do not treat decoded-pixel tests alone as proof of visible rendering.

Fit Screen follow-up: visible VNC/SPICE/VMware toolbar action enables/reapplies aspect-ratio-preserving local auto-fit without reconnecting or changing guest resolution. Display & Input separates auto-fit from opt-in guest resizing, which defaults off. All 99 tests pass, including repeat button action/state and encrypted-console fitting after viewport shrink with unchanged framebuffer dimensions. Source remains 0.13.0 build 27, local/unpublished; real host display sizing still needs user acceptance.

## Distribution

The source and the current locally signed Apple-silicon release are hosted on GitHub. A paid Apple Developer membership is not required for source builds or local-signing distribution. Because the downloadable build is not Developer ID signed or notarized, users may need to approve its first launch through **System Settings → Privacy & Security → Open Anyway** after reviewing the source and checksum.

Release artifacts must not contain saved connection databases, Keychain material, local logs, Derived Data, or private test information. Publish application archives on GitHub Releases rather than committing binaries to the source tree.

## Current direction

Original roadmap 24–30 now has local feature work: experimental registered-client VMware browser federation; VM details/credential-free guest shortcuts; reported task progress and confirmed snapshots for VMware/Proxmox/Hyper-V/stopped libvirt; strict TLS-wrapped standalone consoles; opt-in XQuartz/X11 with isolated terminal transport; manual publisher-signed update validation; universal-core build/validated packaging infrastructure; session/sidebar/VM keyboard navigation and accessibility actions. Auxiliary-window privacy shields now use a plain sibling container instead of adding to a SwiftUI-managed hosting view. Details, adapter limits and acceptance: `ADVANCED_CONNECTIONS.md`.

The matching Intel FreeRDP bundle is not present, so universal release packaging deliberately refuses to proceed without one. No publisher update key was created/pinned and no release was publisher-signed or published; verified downloads remain disabled. Live native-client MFA, XQuartz, Intel RDP and full VoiceOver acceptance are pending. Source stays **0.13.0 build 27**, local/unpublished. No personal clients, passwords, Keychain or IdP/host were accessed. The empty-profile preview could not be targeted by UI tooling and was closed, rather than selecting an installed/private instance.

Verification (2026-10-12, 24–30): **196 tests passed**, zero failures/skips/runtime warnings. This includes complete synthetic PKCE→token exchange→SAML SOAP login, callback rejection, no password fallback, actively erased token expiry, snapshot request flags/stale identities/progress, guest-address/resource bounds, X11/master isolation, keyboard ordering, signed-manifest tampering/URL/version checks and private/quarantined non-overwriting downloads. Debug and optimized universal application-core builds passed; both arm64/x86_64 slices were inspected. The arm64 ZIP/DMG packaging pipeline, ad-hoc signature checks and both checksums passed in a temporary output folder; universal packaging rejected the absent Intel runtime before building/publishing. Signing utility type-check and shell/plist validation passed. This is not a published release or live provider/Intel/VoiceOver certification.

Roadmap 21–23 now has local implementations: file-based shared network libraries with strict username/credential-free DTOs, baseline/UUID mapping, manual refresh/revision publication and field-level conflicts; per-profile 1Password CLI/Vault KV v2 references kept outside archives with async bounded reads and memory-only Vault tokens; and a persisted Mac-authenticated privacy lock with native all-window shields/credential gates. Changed shared destinations create fresh credential-free clients, leaving former clients independent. Locking closes live tabs/recordings, cancels remote-editor operations, clears temporary credentials, stops forwards and closes owned SSH masters without deleting the runtime control directory. Unsaved editor buffers remain hidden in memory; reopen sessions explicitly after unlock. No private vault, Keychain or host was used. Live provider/Touch ID acceptance is still needed. See `SHARING_PRIVACY.md`; source remains 0.13.0 build 27, local/unpublished.

Verification (2026-10-12, 21–23): all 180 tests pass, zero failures/skips. Coverage includes shared allowlist/IDs/three-way conflicts/deletions/stale previews/save failures/private overrides, inherited credential freezing, provider cancellation across lock/unlock, synthetic KV v2 requests/oversize/redirect rejection, native sibling-window/accessibility concealment, persisted lock and failed/stale authentication, repeated-lock shutdown ordering and retained SSH runtime-directory reuse. Hosted data and provider/authentication mocks remain isolated; no real provider, personal credential or host was accessed. Interactive GUI smoke was blocked by the Mac screen lock, and its agent-launched empty-profile instance was closed. Live GUI/provider/Mac-authentication acceptance is still outstanding.

Roadmap 15–20 adds confirmed multi-session commands, terminal font/theme/cursor/scrollback profiles and bounded output snapshots/search, explicit private output recording/retention, metadata-only templates and per-field opt-in group inheritance, previewed atomic bulk connection metadata updates, and bounded background SSH/RDP/CSV/connection-tree XML migration imports. `LibraryTools` stores versioned metadata in the active preferences profile with corruption preservation; connection exports materialize inheritance and embed appearance, not template/group-rule catalogs. Renaming/moving groups remaps rules; removing a group materializes client settings before relocation. Logs use separate profile-specific Application Support directories and are excluded from diagnostics/archives; filtering cannot guarantee secrecy. Active transport snapshots remain unchanged; reopen a tab to use changed defaults. See `LIBRARY_TOOLS.md`. Version remains 0.13.0 build 27, local/unpublished; no personal clients/credentials were accessed or reset.

Verification (2026-10-12): all 160 tests passed with zero failures/skips; Debug test build and optimized Release build succeeded. Isolated GUI smoke verified two-recipient command review/delivery, output search, recording start/stop and a private synthetic log, CSV import/group preservation, mixed-protocol bulk previews/apply, and tool/Settings controls. GUI smoke exposed empty first sheet previews; immutable item-based review payloads fixed them, and repeated first-presentation checks passed. Credential prompts stop recording and old capture generations cannot stop new sessions. Archives reject live inheritance/local appearance references to avoid acquiring destination credentials. Session inheritance is frozen before opening, preserving live SSH identity/shutdown keys after default edits. Ungrouped remains a valid defaults/bulk destination even when absent from saved groups. Logs/test fixtures remain outside source; no private client/credential was reset or published. Original backlog 21–30 is now in `ROADMAP.md` for numbered follow-ups.

Reliability work for priorities 1–8 is local: structured SFTP v3/OpenSSH, independent transfer queues with explicit conflicts/cancel/retry, bounded background file/inventory work, opt-in interrupted-session recovery, Connection Check with redacted reports, tab-aware focus and consistent disconnect/reconnect/Fit controls, hosted-test data isolation, and an expanded macOS CI/acceptance workflow. No private server or account was used for new tests. Version remains 0.13.0 build 27; no publication authorized. Full live macOS/server/device acceptance is still pending; see `RELIABILITY.md` and `COMPATIBILITY.md`.

Workflow priorities 9–14 are implemented locally: retained native surfaces for two-pane/detached sessions, authenticated-master local/remote/SOCKS tunnel controls, ordered ProxyJump editor, Command-K saved-connection/cached-VM/action palette, bounded UTF-8 remote editing with hash conflict checks and atomic SFTP publish, and parameterized preview/Insert/Run snippets. App-owned masters intentionally clear inherited forwarding rules; use the manager. Workflow definitions are local and not yet exported; no command/forward/save is silently replayed. Native move, real SSH device/desktop and forwarding policy acceptance still needs user testing. No client database reset, credential publication or project push/tag/release was performed. See `WORKFLOWS.md`.

Workflow verification (2026-10-12): all 134 tests pass, including repeated native detach/dock and split viewport/visibility checks, local SFTP editor conflicts/explicit overwrite/permissions/cancellation-buffer preservation, isolated tunnel arguments and rejected/uncertain-forward lifecycle, snippet quoting/limits, jump-chain validation, workflow persistence and bundled help. An isolated empty-data-profile UI smoke test verified Command-K/action search, two live local terminal panes, keyboard targeting, retained output after detach/dock and confirmed snippet execution. No private screenshots or clients were added to the repository. Optional VM SSH forwards now use isolated authenticated-master controls so suppressing inherited forwarding rules cannot erase their explicit forward. File/browser/desktop lifetimes retain their models until tab close; split mode hides rather than discards the SSH tree.

Verification: all 118 tests passed with zero skips/runtime warnings; Debug test build and optimized Release build succeeded. The synthetic authentication regression exposed fast EOF error classification and case-insensitive host-trust prompt matching defects in the old helper; both are fixed and tested. Real host/OS combinations remain separate manual acceptance work.

The core SSH, Telnet, Serial, SFTP, local terminal, embedded RDP, help, GitHub release, issue tracker, GitHub Sponsors, and Ko-fi workflows are operational. Current priorities are stability, broader compatibility, and community-driven improvements. See `docs/ROADMAP.md` for the maintained priority order.
