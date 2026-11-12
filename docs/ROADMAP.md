# Nethriva roadmap

This roadmap records direction rather than promises or deadlines. Priorities should be adjusted from real user reports and reproducible issues.

## Current foundation

- [x] Native SwiftUI/AppKit application shell
- [x] Connection sidebar, groups, favorites, and tabbed sessions
- [x] Local terminal and interactive OpenSSH sessions through SwiftTerm
- [x] Native Telnet sessions for legacy devices with plaintext safety warnings
- [x] Native Serial sessions with local adapter discovery and configurable line settings
- [x] Integrated SSH file tree and full SFTP browser
- [x] Recursive upload/download and drag-and-drop file workflows
- [x] Embedded FreeRDP desktop sessions
- [x] Dynamic RDP resolution, pointer, keyboard, clipboard, and file transfer
- [x] RDP audio, device, gateway, certificate, graphics, scaling, and reconnect settings
- [x] Keychain credential storage and local connection persistence
- [x] Reusable Keychain-backed credential profiles for SSH, Telnet, and RDP
- [x] Nested groups, connection search, multi-selection, and drag-and-drop organization
- [x] Connection-library import/export with preserved groups and optional encrypted credentials
- [x] Separate development and release connection data profiles
- [x] Complete offline help manual
- [x] Public source repository, release package, issue tracker, and support links
- [x] Virtualization-host adapter foundation, searchable inventories, and tabbed VNC/SPICE/host web consoles in 0.13.0
- [x] Confirmed VM power/media actions, optional console SSH forwarding, and Ctrl+Alt+Del controls

## Priority 1 — reliability and feedback

- [x] Add reproducible issue templates for bugs and feature requests
- [x] Expand automated coverage around SSH/SFTP authentication failure, cancellation, structured transfers, and recovery state
- [ ] Complete live RDP regression coverage for focus, scaling, clipboard, and file transfer (automated state/focus/sizing checks expanded)
- [x] Add clear diagnostic export with automatic redaction of sensitive values
- [x] Document a repeatable manual release acceptance checklist
- [x] Add Connection Check, explicit transfer retries/conflicts, opt-in network recovery, and background inventory work
- [x] Isolate hosted test data and configure macOS 14/15/26 CI (remote runs pending publication)
- [ ] Validate every virtualization adapter on live host/guest versions before claiming certified compatibility
- [ ] Expand VNC/SPICE authentication, resize, pointer, clipboard, cancellation, and reconnection regression coverage

## Priority 2 — distribution and compatibility

- [x] Automate clean Release builds, ZIP/DMG creation, and SHA-256 generation
- [ ] Add Intel-compatible or universal FreeRDP runtime support
- [x] Add a compatibility matrix for macOS and common SSH/Telnet/RDP server versions
- [x] Add a simple DMG workflow
- [ ] Evaluate an optional update-checking mechanism suitable for open-source distribution
- [ ] Keep Developer ID signing and notarization optional unless project circumstances change

## Priority 3 — connection management

- [x] Search and filter saved connections
- [x] Import and export non-secret connection metadata and optional encrypted credentials
- [x] Add safe backup and restore guidance
- [ ] Improve keyboard navigation and accessibility coverage
- [x] Add configurable terminal appearance profiles and bounded output search
- [x] Add previewed bulk edits, templates, opt-in group inheritance and migration imports

## Priority 4 — advanced workflows

- [x] Replace VMware web-page fallback with direct WebMKS tickets, bundled noVNC, isolated WSS transport, and certificate identity validation
- [ ] Validate VMware WebMKS on live ESXi/vCenter versions, add interactive ADFS/MFA API token acquisition, and improve Nutanix version-specific console authentication from live reports
- [ ] Add host-task progress and cancellation UI for long-running virtualization operations
- [ ] Evaluate console audio, advanced SPICE channels, and file transfer only with explicit permissions and compatibility testing
- [ ] Evaluate additional SSH capabilities only when they improve on the current system OpenSSH path
- [x] Add configurable local/remote/SOCKS SSH tunnel management with explicit lifecycle controls
- [x] Add split panes, detached live sessions, ordered jump chains, and Command-K connection/cached-VM/action search
- [x] Add remote UTF-8 text editing with safe publish/conflict handling and previewed parameterized snippets
- [ ] Complete live workflow acceptance across real SSH/device/desktop servers; extend workflow library export and terminal appearance/accessibility
- [x] Add per-terminal opt-in timestamped output logs, visible recording, private permissions, bounds and retention; label filtering is not guaranteed secret redaction
- [x] Add confirmed multi-session commands with explicit recipients, preflight and no replay
- [ ] Complete live acceptance for roadmap 15–20; extend migration formats, template/rule catalog exports and output-search navigation as needed
- [x] Add ephemeral transfer queues with progress/speed, Cancel/Retry, and Skip/Rename/Overwrite choices
- [x] Add universal application-core cross-build and packaging validation that requires a matching Intel RDP bundle
- [ ] Build and accept the matching x86_64 RDP runtime before publishing a universal release

## Original ranked backlog — items 21–30

Items 1–23 have local implementations and still need broader live acceptance; the original numbering is kept here so future requests stay unambiguous. See [sharing/provider/privacy setup](SHARING_PRIVACY.md) for the supported paths and deliberate limits of 21–23.

21. **Implemented locally:** reviewed file-based shared libraries, personal overrides and field-level three-way merging. No credentials/usernames; manual refresh/new revisions, not a cloud service.
22. **Implemented locally:** 1Password CLI desktop integration and HTTPS Vault KV v2 per-profile password retrieval. Other providers and provider login/renewal workflows remain future work.
23. **Implemented locally:** persistent privacy lock with Mac authentication, native window shields and credential gating; optional sleep/idle lock. Locking disconnects sessions/recordings/tunnels; live Touch ID/provider acceptance remains pending.
24. **Local experimental flow:** registered native OAuth/S256 PKCE browser MFA, vCenter token exchange and SAML bearer SOAP login. Administrator registration/system trust required; live provider acceptance pending.
25. **Implemented locally:** selected VM details and credential-free guest SSH/RDP shortcuts. Missing agent/API fields are explicit; adapter coverage differs.
26. **Implemented locally:** VMware reported task percentages, indeterminate supported-host progress and confirmed VMware/Proxmox/Hyper-V/stopped-libvirt snapshot operations. No task replay/forced recursive deletion; XO/Nutanix snapshots remain unsupported.
27. **Implemented locally:** standalone TCP+SSH, WSS and strict TLS-wrapped TCP consoles. VeNCrypt-only/SASL modes and wider live interoperability remain future work.
28. **Implemented locally:** opt-in trusted/untrusted X11, local XQuartz DISPLAY detection, security guidance and isolated terminal transport. Live XQuartz acceptance pending.
29. **Partial delivery:** universal core cross-build, architecture-aware runtime selection, validated packaging and optional signed-update checks/downloads. A matching Intel RDP runtime, live Intel acceptance and a publisher-owned pinned update key are still required; none were invented or published.
30. **Implemented local improvements:** session shortcuts, sidebar/VM keyboard navigation and scrolling, accessibility selection/actions and native privacy-window polish. Full VoiceOver/remote-canvas acceptance remains pending.

See [advanced connections and distribution](ADVANCED_CONNECTIONS.md) for the exact supported paths, setup and remaining acceptance work. Items 24–30 are not blanket certification of every provider, hypervisor, transport or architecture.

## Non-goals without a separate design decision

- Hosted credential storage or a cloud connection vault
- Telemetry enabled by default
- Publishing private infrastructure details for diagnostics
- Reimplementing SSH, SFTP, or RDP protocols from scratch
- Presenting Telnet as secure or appropriate outside a trusted legacy management network
- Making financial support a requirement for features or use
