# Nethriva security hardening and release requirements

November 11, 2026 checkpoint carried into the 0.13.0/build 30 release. Final local application/native checks passed. Fourteen findings are verified closed locally; the native-dependency finding is mitigated with current binaries but remains open for unavailable advisory-detail review. Production distribution acceptance remains blocked. [SECURITY_AUDIT.md](SECURITY_AUDIT.md) contains findings; [SECURITY_TESTING.md](SECURITY_TESTING.md) contains actual results and repeatable procedures. Nothing here authorizes publishing or weakening operating-system protections.

## Credential authority and safe defaults

- A record UUID is an identifier, not permission to retrieve an existing secret. Imports validate against the whole existing connection/profile/orphan-credential namespace, remap collisions and preserve original credential-bearing records. Endpoint/protocol/account/domain/gateway/key/auth/trust changes must not silently retarget a saved credential.
- Archive review decisions are local-only `ConnectionImportOptions`; they are never decoded from the archive. Imported sensitive redirection, key paths, agent/X11 forwarding, trust bypass, compatibility modes, provider/federation and tunnel references default to restricted settings until reviewed. Existing profile reuse requires per-target local approval.
- Immutable session snapshots keep subsequent library/group edits from changing live identities. Providers remain scoped references; external values/tokens are volatile and actively expire/cancel across lock, quit, deletion and related-session close.
- Keychain accessibility is `WhenUnlockedThisDeviceOnly`. Privacy gates/epochs protect reads/writes and native session authority. No master encryption key is placed in metadata. This is not a claim of zeroizable Swift memory, global clipboard erasure or defense from same-user arbitrary code.
- New credential archives use CryptoKit AES-256-GCM and CommonCrypto PBKDF2-HMAC-SHA256, 600,000 iterations, fresh 16-byte cryptographic salt and fresh GCM nonce. The minimum new-export password is 15 canonically normalized Unicode scalars, bounded to 65,536 UTF-8 bytes. Existing authenticated v1 archives remain readable with their bounded 10,000–2,000,000 iteration parameter range. Strong password choice still matters for offline theft.
- Plain exports refuse secret payloads but intentionally include documented endpoint/account/profile metadata. Both formats use bounded regular-file reads and private atomic writes. Never bundle a personal export/database or use one as a fixture.

## SSH/SFTP transport and local ownership

OpenSSH remains the cryptographic and host-trust implementation. Terminal first-use trust prompts remain deliberate; background SFTP/VM tools do not approve unknown/changed identities. Do not delete known_hosts or disable checking to recover a failing test.

Control directories are created atomically with unpredictable names and private ownership/modes. Held inode/device checks fail closed on replacement. No launch-time global recursive deletion of other app runs/users is performed. Connection reuse includes explicit credential/key/auth/forwarding context; mutable selected-key/top-level SSH-config metadata creates a fresh socket context while old patterns stay registered for shutdown. Full SHA-256 context hashes map to short, never-reused process-local tokens, retaining OpenSSH's expanded endpoint hash and reserving its 17-byte temporary bind suffix within macOS's socket limit. Tokens are not truncated context hashes; unregistered tokens are rejected. Config-free control operations affect only validated matching owned sockets. User SSH configuration, Include/agent behavior and already established authenticated sessions remain an operator trust boundary.

All host/account/jump/identity options receive validation and explicit option boundaries. Agent forwarding is off unless selected; trusted X11 is explicit and uses its own transport. A forwarded agent permits remote signing/authentication operations, even though it does not reveal the private key itself. Use it only where that authority is intended.

Automatic private-pipe authentication must require actual local OpenSSH ECHO-off credential entry, not password-like server text. A wrong/missing tty state denies transmission. Manual SSH Send Saved Password requires an unlocked live session and observed prompt; it never fires from output alone. Secrets with unsupported control/size framing are rejected rather than converted to terminal commands.

SFTP file operations use binary protocol fields, not shell commands. Recursive upload sources and download destinations stay on held descriptors with no-follow children, regular-file/hardlink/FIFO checks, exclusive staging, source-change detection and atomic publish. Overwrite remains explicit. New downloads are owner-private; remote mode bits cannot expose them to other local users. The selected download parent is resolved once at transfer start; there is no claim of atomic filesystem authority from an earlier UI selection or a distributed tree snapshot. Folder merges are not all-or-nothing transactions, and ACL/ownership preservation is not promised.

Resource policy includes 1 MiB SFTP packets, bounded outstanding/pending requests, 16 MiB listing wire/expanded metadata, 64 MiB aggregate recursive metadata, 100,000 records and depth 64. These are admission limits, not guarantees of a malicious server's honesty or of free disk space for an explicitly requested transfer.

## RDP identity, protocol and channels

Default to NLA and system-validated identity. The bridge requires TLS 1.2 or later, installs the private profile-scoped certificate path before session start and validates it without adopting/chmodding an unsafe existing directory. Wrong hostname/chain/pin must fail rather than downgrade. TOFU means a deliberate fingerprint decision with safe persistence, not automatic acceptance of a first-contact attacker.

TLS-only and legacy Standard RDP remain explicit compatibility settings. Ignored verification/legacy use requires per-session consent and must never be described as verified transport. Sensitive home/folder/device/microphone/smart-card/USB/printer redirection is opt-in and reviewed on import. Clipboard synchronization is a separate intentional sharing channel; focus/session guards reduce cross-session leakage but cannot make a compromised destination trustworthy.

Suppress identifying pre-TLS routing cookies on direct connections when no gateway/load-balancing requirement exists. Broker/gateway exceptions must retain necessary routing and be tested separately. Hiding a username in the UI does not itself hide wire metadata.

Native malicious-peer handling must be validated in the actual distributed libraries. The target FreeRDP downstream GFX policy limits dimensions to 8192, surfaces to 256 and aggregate GFX reservations to 512 MiB with accounting on replacement/deletion/close. This does not claim every audio/clipboard/device/codec parser has been fuzzed or every native allocation is covered by the GFX budget.

## Terminal, Telnet and Serial

Remote output cannot read or replace the Mac clipboard through OSC52. A retained forwarding firewall intercepts the managed PTY TerminalView delegate callbacks while normal user Copy/Paste and terminal I/O remain available. Ordinary web/mail links can open from user activation; local/custom-application links require additional review and active-content schemes are refused.

User paste is read once, bounded to 1 MiB, refuses NUL and requires review for line/control characters. The reviewed text is retained and bracketed-paste framing preserved; changing the clipboard during the dialog cannot substitute different text.

PTY, Telnet and Serial ingress buffers incomplete OSC/DCS/APC strings up to 8 MiB and CSI up to 4096 bytes. Oversized sequences are discarded through their terminator without releasing an incomplete sequence to the dependency. Complete sixel input is additionally limited to safe decimal runs, 4096 dimensions, 4 million pixels, 4 million expanded columns and 4096 palette commands before decoding. These bounded safety limits deliberately reject oversized/malformed images while preserving ordinary valid images/escape sequences; they are not an exhaustive image-codec certification.

Telnet remains visibly unencrypted. Explicit saved-credential submission must not be mistaken for wire protection. Serial uses only allowed device paths, no-follow opens, actual character-terminal descriptor checks and bounded queued writes, without root privileges. Local Terminal commands can intentionally start their own network activity; Nethriva cannot retroactively encrypt those commands' protocols.

## Virtualization, consoles and APIs

API sessions default to scoped ephemeral HTTPS with system trust, bounded bodies and safe redirect rules. Federation uses PKCE/state/system HTTPS and connection-scoped expiring volatile authorization; no saved-password fallback. Ticket WSS uses isolated endpoint/port-bound certificate identity or system trust, never management cookies/login headers, and pin mismatch never falls back to Ignore.

JavaScript only requests operations on native-owned descriptors; it cannot choose an arbitrary endpoint. Keep bundled assets, nonpersistent web storage, origin/navigation/message bounds and no external code/CDN requirements. Raw VNC/SPICE must not fetch automatic saved/provider credentials. An explicitly entered plaintext exception is one-session/unsaved and visibly unencrypted. A tunnel protects its own encrypted leg, not an arbitrary unencrypted final hop. VM actions remain deliberate, permission-limited and never automatically replayed by reconnect/recovery.

## macOS platform decisions

The app is not sandboxed. Real shell/PTY execution, system OpenSSH configuration/agent access, local devices, arbitrary user-selected transfers and in-process native plugins need a separate compatibility/entitlement design before App Sandbox can be honestly enabled. No sandbox entitlement was added without that validation, and no claim is made that an entitlement alone isolates the current architecture.

Compensating controls are no privileged helper/root requirement, private storage/IPC, descriptor-based filesystem authority, minimal listeners, gated secret use, independent session lifetimes, guarded parsers and production code-signing policy. Normal application operation initiates outbound connections; explicitly configured tunnels and isolated fixtures are the intentional listeners.

Development retains a native-loading exception where necessary. Release uses `Nethriva.Release.entitlements` with no development runtime exceptions. A production artifact must use Hardened Runtime, sign every nested native binary/provider with the approved Developer ID identity, retain library validation, preserve quarantine and pass notarization/Gatekeeper acceptance. Do not disable SIP/Gatekeeper, strip quarantine or silently bless an ad-hoc build.

The source remains portable generic arm64 with an M1 CPU baseline and macOS 14 deployment target. This is a build contract, not execution certification on M1/M2/M3/M4/M6, every supported macOS or Intel RDP. Universal core compilation does not provide an independently validated Intel native runtime.

## Dependency and distribution policy

1. Pin exact Swift revisions, native source versions/hashes, build tools and GitHub action commits. Retain third-party licenses. Native target is FreeRDP/WinPR 3.33.1 with OpenSSL 4.1.0 and the coherent component set in `scripts/native-runtime.lock.json`; no one-dylib swap or version-label-only repair is acceptable.
2. Build in a new owned private staging directory from approved HTTPS sources. Verify locked source hashes before extraction/build; record every downstream patch, bridge-source hash, architecture/deployment flag and native-file hash in provenance. Detached publisher signatures were not independently verified in the recorded build and must not be claimed verified.
3. Review upstream advisories at every dependency update and before every release. Weekly scheduled scans are supplementary: OSV native purl coverage is incomplete, and Swift CodeQL does not analyze the full C/C++/Objective-C attack surface. The complete upstream preflight covers all managed native/Swift/console/tool/action dependencies and Xcode. Every Release/archive requires a fresh, input-matching, single-use receipt; unavailable or outdated data blocks the build. Official Atom feeds plus credential-free public git refs handle API throttling without cached-success reuse. This is not a complete CVE scanner and does not auto-update pins. Continue manual advisory review, including unavailable current release-linked details.
4. Validate actual library versions/providers and complete Mach-O file/dependency/signature sets with `check-native-runtime.py`; compare staged and final extracted artifacts. SBOM/provenance mismatches block the build. Ad-hoc hashes prove local integrity of a candidate, not publisher authenticity.
5. Keep scanner reports private/redacted. Never whitelist application source/tests broadly to silence a finding. CodeQL and secret/dependency checks must execute successfully; linting workflow YAML is not remote execution evidence.
6. PR jobs receive no signing/notarization/publishing credentials. Default GitHub permissions are read-only; elevated security-events permission belongs only to the analysis job. Avoid `pull_request_target` execution of untrusted code. Configure required branch/release checks in repository settings; a YAML acceptance job alone does not prove enforcement.
7. Check verified update manifests with a pinned publisher public key, exact asset hash/size/repository/architecture and quarantine. No publisher key means verified download remains disabled. Keep private signing keys outside source/build fixtures. No auto-install or macOS bypass is introduced.
8. For production, verify approved publisher/team identity, Developer ID, Hardened Runtime, no runtime exceptions, Gatekeeper and stapled notarization on the actual artifact. Checksums/download HTTPS alone do not protect against a compromised publishing account or source-lock change. Independently verifiable build provenance/attestations remain additional work, not an achieved guarantee.
9. Review the official site's links and release-account permissions separately with the website owner. Do not deploy website or infrastructure changes under application testing authority.

## Release acceptance and residual exceptions

A release is blocked while a confirmed High/Critical finding is unresolved or verification is pending, while the actual bundle differs from its security-reviewed lock/provenance, or while required distribution controls fail. Local final integration/native promotion passed. Current advisory-detail review, production signing/notarization and remote CI/CodeQL acceptance remain incomplete; **Nethriva is not declared security-ready**.

Every Medium/Low finding needs an explicit fixed, pending or accepted-with-conditions disposition in the audit register. Legacy plaintext transport, deliberate trust bypass, operator-owned SSH Include/agent behavior, recording sensitivity, unsandboxed same-user authority, gateway compatibility and unavailable fuzz/device/platform testing are documented limitations rather than silent passes. Preserve all saved connections, Keychain items, user-selected files, existing known_hosts/certificate records and unrelated work while hardening. No commit, push, tag, release replacement or public disclosure is authorized by the presence of these documents.

Native cursor ownership now uses bitmap-owned planes and balanced cache/view ownership. Retained AppKit cursors keep their bitmap alive after protocol cache removal. Bounded regression instrumentation covered 200 create/set/free cycles and 800 object releases; unrelated linked libraries were not thereby fully instrumented.

The SwiftTerm 1.99.3 upgrade requires owned PTY delivery: its convenience process view bypasses the previous output override. Nethriva filters before parsing, bounds queued output with backpressure, preserves user-input delivery/termination order, and uses public copied snapshots. Actual PTY input/output and 2 MiB delivery regressions passed. Xcode build-script/SwiftPM execution sandboxes remain enabled. See `docs/DEPENDENCY_UPDATES.md` for the complete standing build policy.
