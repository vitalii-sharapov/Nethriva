# Nethriva security testing

## v0.13.0 preview — build 30, November 11, 2026

Fresh final suites: **280/280 Debug, 279/279 applicable optimized Release, zero failures/skips**; the explicitly Debug-only isolation case excluded from Release. Thirteen Python gate/configuration regressions passed. Both suites include the temporary SSH socket bind and app-host RDP canvas regressions. Normal optimized arm64 Release build and all 26 managed component/Xcode checks passed. Working-tree/eight-commit history scans and workflow lint passed; four indexed Swift packages had no OSV matches, with native coverage limits unchanged.

Actual build-30 ZIP and mounted DMG passed version/build, signatures, generic arm64/M1/macOS 14 deployment, native source/provenance/provider and archive integrity checks. All ten packaging regressions, exact built console hashes, isolated extracted-app startup, RDP canvas/provider lifecycle, hardened local signing probe, password-free initial packet and synthetic SSH identity fixture passed. No personal connection or server login was used. Production identity verifier rejected the ad-hoc preview as expected; Developer ID/notarization and the other audit acceptance gaps remain open. Remote workflow results are separate from these local passes.

- ZIP SHA-256: `7dca6a1c810977d20b75f8f61225b83e3189074017cd65fb1e834ec40373709a`.
- DMG SHA-256: `9f1a47a0f67870939c2bf63057fba878128e2da9cab189175e89b9df360d1bc3`.
- Local evidence: `/private/tmp/NethrivaPublish-20261111.gcmnpCnC/`. No raw private diagnostics or infrastructure captures are versioned.

The preview release is an explicitly labeled testing distribution, not a production-security acceptance. See [release notes and install/rollback limits](docs/releases/0.13.0.md). Older dated build-27/28/29 records below remain historical and do not describe the build-30 asset hashes.

First remote publication run: secret/dependency scanning and the arm64 security regression job passed. The separate build matrix timed out waiting for module readiness in an unattached WKWebView on both macos-26 runners. Its fixture now attaches the WebView to a window like the application, retains cleanup and assertions, reports navigation/process failures and allows bounded cold startup. Five local repeated fixture runs passed. GitHub's default macos-26 image was also confirmed to use Xcode 26.6; release/security validation now selects 27.2 on the official xcode-27 image, retaining macos-26/Intel Debug checks. Follow-up remote results must be read from the exact tagged commit; the initial failure is not counted as a pass. These changes affect tests/workflows/docs, not the validated build-30 application payload or checksums.

Publication follow-up: both macos-26 Debug matrix jobs passed. The macOS 27.0.1 runner exposed an `InvalidTransition` lifecycle error in the WebMKS fixture. The fixture now orders its owned window onscreen, explicitly controls its lifetime, waits in Swift before synchronous JavaScript geometry evaluation, and labels throwing steps for diagnosis. All framebuffer, geometry, TLS, credential-header and Ctrl+Alt+Del assertions remain. CodeQL uses a compatible Intel analysis host while current-toolchain release/runtime checks remain on Xcode 27.2; no package sandbox is disabled. These test/workflow changes do not alter the frozen build-30 app. Exact final remote results remain required before tagging.

## SSH temporary control-socket regression — November 11, 2026

The reported local `unix_listener ... too long` failure reproduced in a new regression: expanded final socket plus OpenSSH's `.<16 random characters>` suffix used 115 bytes against a 104-byte macOS `sun_path` buffer including NUL. The prior check covered only the final path. The fix retains full SHA-256 context hashes in a locked process-local map and assigns short unique never-reused tokens; OpenSSH endpoint hashing, private inode-bound directories and context-specific shutdown remain. The production path budget now explicitly includes the temporary suffix, yielding 99 bytes in the default namespace. Unregistered tokens are rejected.

Before fix: one regression failed with the exact 115/104-byte diagnostic. After fix: **279/279 applicable signed Development app tests passed, zero failures/skips**; the explicitly Debug-only isolation case excluded. The regression uses actual `/usr/bin/ssh -G -F none` expansion (no remote connection/user configuration), then actual Darwin AF_UNIX bind/listen at the temporary path. Existing credential/key/auth/forwarding/config-change, SFTP, tunnel, terminal and RDP regressions passed. Normal optimized Development build, thirteen Python checks, fresh component/receipt gate, input/diff and redacted working-tree scan passed. No server login/command, saved-data/Keychain/known-hosts change or manual runtime-directory cleanup. Private evidence: `/private/tmp/NethrivaSSHMuxFix-20261111.fnf5AIo6/`. Existing exports remain unchanged; user retry after rebuilding/relaunching remains live acceptance.

## Xcode RDP follow-up — November 11, 2026

The user's direct Xcode Release run failed before contacting an RDP server: the exception-free Hardened Runtime app could not load ad-hoc native libraries without an Apple Team ID. Run now uses optimized Development with existing local signing/debugger permissions and the normal Release data profile; Archive/Profile remain strict Release, Debug stays isolated. All non-Debug configurations retain the fresh component/receipt gate. No production entitlement or system validation policy was weakened.

Actual normal Xcode Development build succeeded at 17:23. New isolated signed Development test run: **278/278 passed, zero failures/skips**, with the explicitly Debug-only isolation test excluded. This includes actual `EmbeddedRDPSession` initialization/canvas creation inside the app host without a server connection. **13/13** Python gate/configuration regressions passed. A separately hardened ad-hoc probe loaded the exact normal Xcode app's RDP library/providers/canvas; its exception-free negative control reproduced the original validation refusal. Normal app retains Hardened Runtime/local debugger permissions without XCTest temporary exceptions. Production entitlements remain empty. This does not establish production Developer ID/notarization acceptance or a successful remote login.

The status panel now has an opaque appearance-aware background, primary selectable text and a bounded scroll region. Light/dark native previews with synthetic messages were inspected. SwiftUI's image renderer omitted ScrollView contents, so native NSHostingView rendering was used for verification. No infrastructure screenshot or raw private diagnostic was added to source/notes. Redacted working-tree scan and diff/input checks passed. Private evidence: `/private/tmp/NethrivaRDPFollowup-20261111.qwgnJ9Q8/`. Earlier export/Debug/Release evidence below remains historical; no new export/publication occurred.

Recorded checkpoint: November 11, 2026, unpublished 0.13.0/build 29 development source. See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for findings and [SECURITY_HARDENING.md](SECURITY_HARDENING.md) for release rules.

**Final local integrated checks passed; production security acceptance remains blocked.** Successful checks are recorded separately from unavailable coverage and external release requirements.

## Safe test environment

Use a supported Apple-silicon Mac with full Xcode, Python 3 and normal desktop-service access for hosted AppKit/WebKit tests. Tests use the app's hosted-test data profile, fake vaults, generated identities and disposable local files. They must never fall back to the user's Debug/Release library, real Keychain service, SSH keys/config/known_hosts or certificate cache.

All network fixtures bind only `127.0.0.1`/loopback and use synthetic credentials. No LAN, production host, VM power/media operation or real login is needed. Close only fixture-owned processes and listeners. Never disable Gatekeeper, relax global TLS trust, load a root certificate into the user's trust store or run a real infrastructure command to make a regression pass.

Run commands from the repository root. Use a new private result directory for each run; Xcode result bundles must not already exist. Example:

```sh
NETHRIVA_SECURITY_RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/Nethriva-security.XXXXXX")"
chmod 700 "$NETHRIVA_SECURITY_RESULTS"
bash scripts/security-test.sh "$NETHRIVA_SECURITY_RESULTS/debug"
NETHRIVA_TEST_CONFIGURATION=Release bash scripts/security-test.sh "$NETHRIVA_SECURITY_RESULTS/release"
```

`security-test.sh` first verifies the actual source runtime, then runs application/security tests and the local SSH identity fixture. It accepts an optional absolute `NETHRIVA_PACKAGE_CACHE` containing valid pinned checkouts and disables automatic package resolution when provided. It does not reset personal data or install an app. Release testing explicitly excludes the one test whose body requires the Debug configuration; all other tests remain enabled.

## Automated application/security coverage

| Suite | Boundary exercised |
| --- | --- |
| `SecurityImportTests` | Archive UUID/category/orphan-secret collisions, endpoint retargeting, reviewed profile/capability reuse, unchanged benign metadata, rollback, plain/encrypted controls, legacy v1 compatibility, stronger KDF/export rules and filesystem staging. |
| `SecuritySSHTests` | Private control-directory creation/inode/mode changes; identity-scoped reuse and changed-key shutdown registration; argument/jump boundaries; actual OSC52 parser/firewall; prompt-bound manual password action; echo-on/off automatic-secret guard; bounded reviewed paste/links; streaming escape/sixel limits; Serial descriptors; SFTP source/publication races and metadata/framing corpora. |
| `SecurityTransportTests` | Secure RDP defaults/compatibility modes, native trust/certificate storage, unsafe console credential gating, trust/redirect/descriptor controls and related native bridge behavior. |
| `ReliabilityTests` | Actual local system SFTP subsystem operations, pipeline integrity, conflicts/cancellation/source mutation, literal Unicode/shell-looking filenames, special-file refusal and malformed packets/request IDs. |
| `SharingPrivacyTests` | Shared strict allowlists and endpoint isolation, gated credential operations/epochs, provider cancellation, requested-field/redirect/size restrictions and preservation on stale/failed updates. |
| `AdvancedConnectionTests`/`VirtualizationTests` | PKCE/state/callback validation, token lifetime, API/ticket parsing, certificate pin mismatch/missing-pin rejection, no credential forwarding/redirects, local TLS/WSS console behavior and VM identifier/action validation. |
| Existing app/workflow/library suites | Store compatibility/recovery, encrypted archives, session/split lifecycle, command parameters/confirmation, logs, templates, bulk metadata and owned tunnel controls. |

To run only a suite during development, use Xcode's test selector or the same isolated `xcodebuild test` configuration with `-only-testing:NethrivaTests/SecuritySSHTests` (or the intended suite). Do not claim the full gate passed from a selected-suite run.

## Repeatable local penetration checks

### SSH identity and malicious prompts

```sh
python3 scripts/security-ssh-fixture.py
```

This creates throwaway Ed25519 host keys and private configuration/known_hosts files, starts an unprivileged system sshd on loopback and checks unknown-key refusal, changed-key refusal, and correct-key acceptance followed by deliberate authentication refusal. It uses a fictional nonexistent login, no authorized keys/PAM/password authentication and no personal SSH identity/agent/default config. The owned process group and temporary files are removed afterward. Missing executable/fixture capability is a failure/unavailable result, not a passing test.

`SecuritySSHTests.testAutomaticSSHCredentialGuardRejectsSpoofedEchoOnPromptAndSupportsEchoOffAuth` uses a separate private local PTY. An echo-on process prints a password-like prompt and must receive nothing; an echo-off authentication fixture may receive only the dummy value. This validates the exact shared guard without transmitting an actual secret. It is not a general live SSH-server compromise test.

### Terminal escape and clipboard boundaries

Use the actual delegate firewall with a fake clipboard delegate containing dummy bytes. Feed OSC52 query/write variants through SwiftTerm and assert the underlying clipboard callbacks and outbound clipboard response remain unused. Do not seed or inspect the user's general pasteboard for this test.

Exercise valid sequences and UTF-8 at one-byte and varied chunk boundaries, unterminated OSC/DCS/CSI, C1 forms, malformed numeric runs and sixel expansion metadata. Use small configurable budgets to test rejection. Never pass a known overflowing/unbounded sixel payload to the unguarded dependency. Confirm normal user input, Copy/Paste, reviewed multiline input and bounded images still function.

### SFTP files and parser metadata

Use the system local `sftp-server` over private pipes, not an SSH connection to a real account. Create fixture files for spaces, quotes, Unicode, leading hyphens, shell metacharacters, symlinks, hardlinks and FIFOs. Traverse/delete only the private fixture root.

Hold a source/download-directory descriptor, replace its old pathname with a symlink to an outside **synthetic** directory, and verify reads/publication stay with the held original directory and outside sentinel bytes remain unchanged. Verify overwrite uses namespace replacement rather than writes through an outside hardlink. Confirm cancellation/conflict/retry keeps the previous destination and removes owned partial files.

Feed bounded binary packet corpora: oversized headers, truncated values, wrong/duplicate request IDs, invalid UTF-8/control names, excessive attributes/counts, canonical-path amplification and shared metadata-budget exhaustion. A packet limit alone is insufficient; assert rejection before expanded path allocation.

### RDP/console authentication and hostile-peer checks

Synthetic TLS identities are memory-only and never added to Keychain/system trust. A wrong ticket pin, missing pin with an untrusted chain, wrong hostname, redirect or mismatched origin must fail before credential/session use. Known certificate/name failures must not silently switch to Ignore or a lower security mode.

The baseline Direct TCP VNC fixture requested VeNCrypt Plain and recovered dummy username/password from received bytes; the TLS-wrapped untrusted-certificate control received zero application bytes. The fixed default must avoid fetching/supplying saved/provider credentials on that unprotected route. Test the explicitly reviewed unsaved one-session legacy exception separately.

For initial RDP username privacy, collect only the first packet on a loopback listener and stop before TLS/authentication. Supply a synthetic username and **no password**. Compare direct cookie suppression with gateway/load-balancing routing exceptions. Never use a network-wide packet capture of personal traffic.

For graphics budgets and native cursor ownership, use the checked-in bounded tests against a trusted native build workspace:

```sh
python3 scripts/test-native-gfx-budget.py /absolute/trusted-native-build /absolute/new-gfx-results
python3 scripts/test-native-bridge-lifecycle.py /absolute/trusted-native-build /absolute/new-cursor-results
```

The graphics test compiles the actual patched production allocation path under ASan/UBSan; its allocation wrapper caps live bytes at 512 MiB. The cursor test instruments all local bridge sources, exercises actual callbacks and tracks object destruction/retained bitmap lifetime. Linked third-party libraries are not fully instrumented by these tests. Test oversized dimensions/count/reservation rejection, small valid allocation, release on replacement/deletion and aggregate limits. Do not allocate the protocol's multi-gigabyte maximum to prove a guard.

## Runtime/build and supply-chain verification

Rebuild only into a new private staging directory:

```sh
python3 scripts/build-native-runtime.py
python3 scripts/check-native-runtime.py /absolute/path/to/staged/FreeRDP
```

The builder fetches checksum-pinned official sources, applies recorded patches, builds the full bundle and emits `SBOM.cdx.json`/`PROVENANCE.json`. It does not install the application or automatically replace source/release assets. The integrity checker compares lock/provenance/SBOM/file sets, actual loaded versions/providers, source hashes/signatures and generic arm64/macOS deployment requirements. A lock/binary mismatch must fail. Source SHA-256 verification is not a claim that detached publisher PGP signatures were verified.

For a built/extracted trusted artifact:

```sh
zsh scripts/verify-packaged-app.sh /absolute/path/to/Nethriva.app 0.13.0
zsh scripts/test-release-packaging.sh /absolute/path/to/Nethriva.app
swift scripts/smoke-rdp-runtime.swift /absolute/path/to/Nethriva.app
bash scripts/verify-distribution.sh /absolute/path/to/Nethriva.app
```

The first three checks do not establish Developer ID identity/notarization. The last gate separately requires strict signatures, Developer ID Application, Hardened Runtime, no development runtime exceptions, Gatekeeper acceptance and a valid stapled notarization ticket. Its rejection of an ad-hoc test build is expected and must not be bypassed.

Install and run pinned scanners in a private directory:

```sh
python3 scripts/install-security-tools.py --directory "$NETHRIVA_SECURITY_RESULTS/tools"
bash scripts/security-scan.sh "$NETHRIVA_SECURITY_RESULTS/scans" "$NETHRIVA_SECURITY_RESULTS/tools"
```

Gitleaks reports are fully redacted. Review detector exclusions rather than suppressing findings broadly; source/tests stay scanned while generated binaries/build caches are excluded. Actionlint is executed with shellcheck/pyflakes disabled, so its pass is not a pass from those unavailable analyzers.

OSV receives the Swift lock and native CycloneDX SBOM. The final result indexed four resolved Swift-package repository URLs, but native generic/GitHub purls were partly unsupported or misclassified as GitHub Actions. Report those coverage gaps; a successful exit is not a native vulnerability-free verdict. Compare the exact native versions/build features with primary upstream advisories before release. `check-native-upstream.py` delegates to the complete native-library/tool release monitor and fails on drift or unavailable responses. The full version-build check covers all 26 managed components plus Xcode; neither monitor is a CVE scanner.

`.github/workflows/security.yml` schedules scans, isolated macOS regressions and Swift CodeQL security-extended analysis. Its final acceptance job fails failed/skipped dependencies. Local workflow lint or installation is not proof that GitHub executed it or that repository branch/release protections require it.

## Final executed evidence — November 11, 2026

Host: M5 Pro, macOS 27.2; Xcode 27.2/Swift 6.4.2, arm64 destination, generic M1 CPU baseline/macOS 14 deployment contract. No other chip or supported older OS was executed. Private results: `/private/tmp/NethrivaDependencyUpdate-20261111.shma530i/` (local, not an uploaded artifact).

| Check | Actual final result |
| --- | --- |
| Final Debug | **278 executed, 278 passed, 0 failed, 0 skipped**, `Debug-Final.xcresult`. |
| Final optimized Release | **277 executed, 277 passed, 0 failed, 0 skipped**, `Release-Final.xcresult`; only the explicitly Debug-only isolation test excluded. |
| Security-specific suites | 45 import/credential, 21 SSH/terminal/SFTP and 7 transport methods included in the complete runs; additional existing privacy/integration regressions also executed. |
| Normal optimized app | Build passed with testability off, generic arm64 and macOS 14 minimum. Temporary development-signed copy only; installed app untouched. |
| Native integrity | Final source bundle: actual FreeRDP/WinPR 3.33.1/OpenSSL 4.1.0, 18 binaries, lock/SBOM/provenance/patch/bridge hashes, strict signatures, portable closure/deployment and loaded providers passed. |
| Native build scope | Full checked-in native builder completed end-to-end from verified sources under Xcode 27.2/SDK 27.2, including current CMake, dependencies, core, bridge, licenses, staging and final integrity gate; validated candidate promoted with backups. |
| Native GFX | Actual patched production `gfx.c` passed bounded ASan/UBSan: oversized/zero/duplicate rejection before allocation, real 8192² allocation, 512 MiB aggregate, 256 entries, delete/refund/reuse. Repeatable script passed (`GFX-Sanitizers/`). No multi-gigabyte allocation executed. |
| Native cursor ownership | Actual source callbacks passed ASan/UBSan: 200 create/set/free cycles, 800 tracked object releases, retained bitmap validity, invalid dimensions (`Cursor-Sanitizers/`). Bridge instrumented; linked third-party libraries are not comprehensively instrumented. |
| Native static analysis | All eight local Objective-C bridge translation units completed Clang analysis. Five ownership warnings corrected; 13 dead-store warnings remain in MRDPView (no established security impact). No full upstream C/C++ analysis or completed CodeQL run claimed. |
| Direct initial RDP packet | Actual final bridge, loopback/password-free: 38 bytes, empty routing cookie, no synthetic username; connection closed before TLS. Native transport failure logs are expected from the deliberately closed fixture, not a login pass. |
| Console credentials | Final integrated actual native/noVNC VeNCrypt Plain regression withheld automatic credentials. Historical baseline leaked dummy credentials; untrusted outer TLS control sent zero application bytes. |
| SSH host identity | Three isolated generated-key cases passed: unknown/changed keys refused, correct key reached intentional authentication refusal. No real login/account commands. |
| Automatic credential prompt | Actual shared echo-on spoof refusal and echo-off authentication fixture passed in final suite. The legacy positive fixture was corrected to disable local echo, not exempted from the guard. |
| Terminal/SFTP | Final integrated actual parser/delegate/filesystem checks passed. Earlier supplemental actual-source terminal run: 10,038 deterministic checks; held-directory swap checks passed. These are not broad fuzz campaigns. |
| Packaging/compatibility | All ten checks passed, including ZIP round trip, lost permissions/symlink flattening, wrong version, incompatible CPU/platform/minimum OS and machine-local search path rejection. Actual optimized app plus 18 runtime binaries (19 Mach-O files). |
| Startup/RDP smoke | Temporary signed app launched an isolated empty profile, opened workspace and stayed running; only fixture instance closed. Native providers/canvas/resize/destroy passed without a remote login. |
| Existing exports | November 3 build-27 ZIP/DMG SHA-256 unchanged from baseline; installed app and existing exports not replaced. |
| Secret scanning | Final application working tree and eight inspected commits clean with redacted Gitleaks 8.30.1. Legacy ignored build cache excluded; seven exact public checksums narrowly allowed only in their provenance/console manifests. Nonfunctional synthetic private-key detector control still detected. No other refs/unreachable history certification. |
| Dependency scans | OSV 2.7.1 received four resolved Swift packages and 13 native SBOM components; no indexed Swift matches in the final run. Six native components filtered and others misclassified: **no native clean-scan claim**. |
| Public native release monitor | All 26 managed components and Xcode 27.2 current in actual fresh API/feed/public-ref checks; real API quota throttling exercised. Eleven current release-linked advisory details unavailable (404); applicability review remains open. |
| Workflow policy | Local actionlint passed; shellcheck/pyflakes disabled. Pinned actions, scheduled scans and Swift CodeQL configured; remote execution/required-check enforcement not established. |
| Production distribution | Strict gate rejected temporary ad-hoc app: Developer ID Application signing required. No production signing/notarization, approved publisher key or clean-machine Gatekeeper acceptance achieved. |
| Broad native fuzzing | Not completed: installed compiler lacks libFuzzer runtime, and a separate broader native-fuzz subtask was stopped by an automated safety check. Deterministic/ASan unit tests do not replace it. |
| Live/platform matrix | No M1/M2/M3/M4/M6, Intel native RDP, older supported OS, live IdP/provider/hypervisor/device matrix or hostile real RDP peer certification. |

Historical integration evidence remains preserved: initial 259/257 and later 275/273 executed/passed. Outdated certificate/restore defaults, clipboard opt-in and echo-off fixture expectations were corrected. Two temporary fixture edits failed compilation and were corrected; final results above supersede them. None of the failures was hidden by dropping an applicable test.

Fourteen grouped findings are verified closed locally; NETH-05's previously affected native baseline is replaced and tested, but its full current advisory acceptance remains open. No Critical finding or complete arbitrary-code-execution exploit was established. Production acceptance remains blocked as described in [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

Dependency-gate validation: 11 Python regressions passed; app suites now 278 Debug/277 applicable optimized. Actual Release builds executed the online pre-action and sandboxed offline receipt verifier. Initial sandbox input declarations were corrected to exact file paths; no sandbox was disabled. An export attempt was correctly stopped by API throttling; a fresh official Atom/public-ref fallback was added and verified, including annotated tag peeling and unavailable-fallback rejection. No stale-success bypass or personal token is required. Reviewed build-info plugin source/revision hashes precede per-invocation headless approval.

Final build-29 export: `Nethriva Releases/Dependency Update 0.13.0 - 2026-11-11/`. Both ZIP and mounted DMG passed signatures/native/deployment checks; the app extracted from the actual ZIP passed all ten packaging regressions, exact console-source hashes, isolated startup, RDP canvas/provider smoke, password-free initial-packet inspection and synthetic SSH trust checks. ZIP SHA-256: `46c804ddc91cd3bdbdfa5b799916bfcd7c942ab22bd5901602c8ef48ba637e3c`. DMG SHA-256: `a9de7e1c0a47ae95d3a98eea7013c57f2a6e28427f01d404aef60417dbd11b49`. This is a local ad-hoc development export, not a notarized public release or M2 execution result.
