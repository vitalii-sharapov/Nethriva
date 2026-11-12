# Nethriva release acceptance checklist

For **v0.13.0/build 30**, use the [preview release record](releases/0.13.0.md). Tag format is `vMAJOR.MINOR.PATCH`; build numbers distinguish different binary payloads. An ad-hoc/unnotarized preview must be marked prerelease and must not be described as production-approved. Retain the prior stable release and existing assets. Production publication separately requires `verify-distribution.sh` and the unresolved security acceptance items.

- Before every new version, run `python3 scripts/check-dependency-updates.py --require-current-toolchain` and apply/review flagged updates. The Release/archive scheme repeats the check automatically; the enabled build-script sandbox requires a fresh, pin-matching, single-use receipt. Missing network/current data blocks that build.
- Verify reviewed package plugins with `bash scripts/prepare-swift-packages.sh /absolute/private/cache` before headless approval. Do not disable global Xcode validation or the SwiftPM sandbox. When dependency files change, regenerate the declared sandbox input file list as described in [DEPENDENCY_UPDATES.md](DEPENDENCY_UPDATES.md).

For original roadmap 24–30, follow [advanced acceptance](ADVANCED_CONNECTIONS.md#acceptance-checks): registered-client MFA/cancel/expiry/trust, credential-free guest shortcuts, confirmed snapshots and non-replayed host tasks, encrypted console transport without downgrade, XQuartz forwarding isolation, matching Intel runtime and clean universal packaging, publisher-signed update validation and keyboard/VoiceOver/privacy focus. Intel RDP and live federation/VoiceOver certification remain pending. Do not publish a test update key or silently call an unverified download verified.

For roadmap 21–23, complete [shared-library/provider/privacy acceptance](SHARING_PRIVACY.md#acceptance-checks) with synthetic files/test vault entries. Validate actual Touch ID/Mac-password unlock, cancelled prompts, restart/sleep/idle locking, detached/auxiliary-window concealment, network/recording shutdown and explicit reopening. Shared publication must contain no usernames/profile/provider references; never package local library-link preferences, provider configuration/tokens, logs or personal shared files. Do not claim all password managers or a hosted team-sync service.

For the current workflow additions, also follow [WORKFLOWS.md](WORKFLOWS.md): test split divider/window/sidebar geometry, inactive visibility, keyboard focus across windows, detach/dock without session restarts, local/remote/SOCKS forwarding policies, multi-hop SSH/SFTP, Quick Connect cached VM actions, safe remote editing/conflicts/cancellation and snippet confirmation/targeting. SSH config forwards are intentionally suppressed on app-owned masters; configured console forwards use isolated controls. Hosted tests and an isolated local-terminal UI smoke pass do not certify real server/device compatibility.

## Automated checks

- Follow [LIBRARY_TOOLS.md](LIBRARY_TOOLS.md#acceptance-checks) for multi-session recipients/stale targets, terminal profiles/search, recording limits/retention, group inheritance/move/removal, bulk previews/save failures and synthetic migration imports. Confirm logs and inherited credential metadata never enter app bundles or diagnostics. Recording/filtering is not a guarantee against private output.

- Run the full Nethriva test target.
- Build Debug and Release configurations from a clean Derived Data directory.
- Confirm the bundled Nethriva RDP bridge loads and exports the expected symbols.
- Run the release script and verify both ZIP and DMG SHA-256 files.
- Run `scripts/test-release-packaging.sh /absolute/path/to/signed/Nethriva.app` with zsh. Its ten checks cover a valid ZIP round trip, overwrite/version/permission/symlink rejection, and signed native fixtures: accept generic arm64/macOS; reject a restricted CPU slice, wrong platform, excessive minimum OS and machine-local runtime search path. CI runs these checks on the Release product; a configured workflow is not a completed remote run.
- Package existing signed exports with `zsh scripts/package-app.sh /absolute/path/to/Nethriva.app /absolute/path/to/release.zip [version]`. This does not rebuild or re-sign the app, so an older packaging repair cannot accidentally include unfinished newer features.
- ZIP packaging must preserve symlinks and Unix executable permissions. Verify the extracted archive with `zsh scripts/verify-release-archive.sh /absolute/path/to/release.zip [version]`, including a fresh download of the exact uploaded asset. Do not unzip/recompress using a tool that materializes library links or drops executable permissions.
- DMG creation uses `ditto`, verifies the staged signature, verifies/mounts the finished image read-only, and verifies the mounted app. Existing release outputs are never overwritten.
- `verify-packaged-app.sh` checks generic arm64 CPU subtypes, macOS platform, portable dependency/search paths, relative runtime dependencies/exports, symlinks, the strict resource seal, executable permissions and bundled binary deployment targets against the declared minimum macOS. Debug and Release pin the arm64 C/Swift compiler CPU baseline to M1. This does not certify every OS/M-series model or replace first-launch testing.
- From a normal Mac desktop session, run `swift scripts/smoke-app-launch.swift /absolute/path/to/trusted/extracted/Nethriva.app`. It uses an empty isolated profile and a new LaunchServices instance, checks completed launch/window creation and brief survival, then closes only that instance. Run on each available hardware/OS combination and record actual results; it does not emulate older chips or certify Gatekeeper approval. Do not launch the executable directly under a restrictive command sandbox and interpret application-registration failure as a chip failure.
- After verifying a trusted extracted release, run `swift scripts/smoke-rdp-runtime.swift /absolute/path/to/Nethriva.app`. This loads its bundled bridge/dependencies, initializes OpenSSL providers and creates/resizes/destroys a native RDP canvas without opening a network connection or reading personal client records/Keychain. CI includes this smoke check; it is not a real Windows-session test.

## Privacy and packaging

- Confirm no saved connections, credentials, private keys, hostnames, addresses, screenshots, or session logs are present.
- Confirm Keychain data and local UserDefaults data are not inside the app or archives.
- Confirm third-party licenses and notices are included.
- Confirm the downloadable app reports the intended version and build number.

## Manual acceptance

- Open Local Terminal and verify keyboard, copy, paste, resizing, and tab closing.
- Open SSH with key and password authentication; verify host-key prompts and reconnect.
- Open Telnet against a disposable test service; verify negotiation, keyboard input, resize, and reconnect.
- Verify Telnet offers saved username and password only at their corresponding prompts.
- Open a Serial tab with a disposable USB adapter; verify port discovery, line settings, input, paste, reconnect, and device release on close.
- Create a disposable shared credential profile, link SSH/Telnet/RDP test connections, rotate its password, and verify a new session uses it without changing unrelated credentials.
- Export and import disposable profile-linked connections with and without credentials; verify the plain archive has no password and the encrypted archive restores its Keychain password.
- Verify nested-group search, Command/Shift selection, multi-item drag, folder moves, and quick rename.
- Exercise SFTP list, upload, download, rename, move, drag-and-drop, and unsafe-name rejection.
- Open RDP and verify focus, pointer, dynamic resolution, clipboard, file transfer, audio, reconnect, and shutdown.
- Corrupt a disposable saved-connection record and verify last-known-good recovery.
- Export diagnostics and confirm it contains no names, hosts, users, ports, paths, credentials, or logs.
- Test first launch of the downloaded build on a separate Mac and document **Open Anyway** behavior.
- Preserve normal quarantine/security checks. An ad-hoc-signed, unnotarized app may still require explicit per-app approval; invalid signatures and missing executable permission are packaging failures, not a reason to remove quarantine or disable Gatekeeper.

## Reliability acceptance

- Follow the complete scenario checklist in [RELIABILITY.md](RELIABILITY.md#suggested-local-acceptance-pass).
- Confirm hosted XCTest uses its process-specific test preferences/credential namespace, never personal Debug/Release stores.
- Test queue progress, conflict resolution, cancellation, safe file publication, directory navigation while transferring, and explicit retry after interruption.
- Verify opt-in recovery after sleep, network loss, and interface/VPN changes; manually disconnected sessions must not reopen. No commands, transfers, or VM operations may silently replay.
- Verify Connection Check cancellation, safe results, unknown/self-signed trust failures, optional login, and redacted report contents.
- Test keyboard focus across terminal/RDP/console tabs and confirm background connections cannot steal input.
- Record actual sanitized macOS/server versions in the compatibility worksheet. A configured CI matrix is not a completed run or live-server certification.

## Virtualization acceptance (0.13.0)

- Use disposable VMs and least-privilege test accounts; record sanitized host and guest versions in `COMPATIBILITY.md`.
- Verify inventory, filtering, refresh, failed login, strict certificates, TOFU approval, changed fingerprints, and rejected permissions for each platform.
- Verify running VM console startup, tab preservation, keyboard focus, two-finger secondary click, pointer alignment, sidebar/window resizing, and disconnect/reconnect.
- Verify Ctrl+Alt+Del in VNC, SPICE, VMware WebMKS, RDP, and Hyper-V VMConnect.
- Verify view-only blocks input, input release returns focus, and clipboard access stays off unless enabled. Test supported guest-agent clipboard/resize paths separately from local scaling.
- Verify confirmed start, shutdown/reboot, suspend/resume where offered, reset, and force-off only on disposable guests; inspect queued host tasks.
- Verify existing CD/DVD selection, valid/invalid host ISO paths or IDs, Tools/NGT mounting, eject, and missing guest-agent/media failures. Do not confuse media mounting with guest installation or local upload.
- Verify libvirt TCP/UNIX socket forwarding and direct VNC/SPICE SSH forwarding; close the last associated tab and confirm owned tunnels terminate without affecting unrelated sessions.
- Verify VMware direct WebMKS tickets, ESXi DNS/port reachability, certificate verification/rejection, keyboard/pointer, fitting, and reconnect with a fresh ticket. Use API-compatible credentials or the explicitly configured registered-native-client federation flow; the latter still needs live IdP acceptance. Verify Hyper-V SSH and port 2179 separately; verify Nutanix host API versions and WSS authentication.
- Verify temporary logins, session cookies, generated API tokens, and console tickets are absent from preferences, plain/encrypted library exports, diagnostics, and packaged apps.
- Verify third-party JavaScript source, dependency provenance, MPL/BSD/LGPL license texts, and original notices ship in both Debug and Release.
