# Dependency updates and version-build gate

Current release version: **0.13.0/build 30**, November 11, 2026. Updated stack: FreeRDP/WinPR 3.33.1, OpenSSL 4.1.0, FDK-AAC 3.0.0, SwiftTerm 1.99.3, noVNC 1.7.0, SPICE commit 85262d0, CMake 4.4.5; the complete native/Swift/console/security-tool locks contain all other pins. Xcode 27.2/Swift 6.4.2 is the current validated toolchain. See [the release record](releases/0.13.0.md) for packaging and known limits.

## What runs before every version build

The scheme's Release/archive pre-action queries official upstream releases/tags (with fresh official Atom feeds and credential-free public git refs when API quotas are exhausted) for every direct/transitive Swift package, native library/build tool, console component, security scanner, CI action and Xcode. It verifies immutable revisions and vendored file hashes. It writes a fresh report with all input hashes and a nonce. The first target build phase, with `ENABLE_USER_SCRIPT_SANDBOXING=YES`, requires all components/toolchain current, complete coverage, unchanged pins, a report at most 15 minutes old and a previously unused nonce. A bounded receipt ledger prevents reusing the same check for another build. Missing/outdated/unavailable results block the build. Direct target builds without the scheme's preflight cannot satisfy the Release gate.

The native builder checks its complete library/tool inventory and Xcode before downloading/building. The security workflow checks the full inventory weekly and on its configured events. This config does not prove remote CI executed or branch protections require it.

Release/runtime security CI uses GitHub's documented `xcode-27` hosted image and explicitly selects Xcode 27.2, including the security script's `DEVELOPER_DIR`. The macos-26/Intel jobs provide Debug compatibility coverage with their available Xcode 26.6; they cannot satisfy a current-toolchain Release receipt. CodeQL alone uses the Intel macos-26 toolchain: its current tracer cannot launch the arm64e system sandbox helper on macOS 27, and its documented Swift support ends at 6.3. The SwiftPM sandbox stays enabled. See [the upstream tracer issue](https://github.com/github/codeql/issues/22742) and [supported compilers](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/). The runner's preview label is narrowly declared for actionlint 1.7.12, whose built-in label catalog predates it. No version/network/receipt check is bypassed.

```sh
python3 scripts/check-dependency-updates.py --require-current-toolchain --report /absolute/private/results/dependencies.json
bash scripts/prepare-swift-packages.sh /absolute/private/package-cache
```

Build through the Nethriva scheme. Ordinary Debug builds may use already-resolved packages offline; they do not create an upstream-current Release receipt. Nothing auto-updates during a build. Apply updates deliberately, review source/license/API changes, retain original artifacts and rerun tests before accepting a new candidate. The installed macOS/system OpenSSH and user-owned external password-manager tools are separate from app-managed dependencies; do not reboot or alter personal credential stores as a build step.

## Local Xcode Run and production archives

The scheme's Run action uses **Development**, an optimized local configuration with the existing development-only library-validation entitlement. It shares the normal Release connection/Keychain profile, preserving the user's expected local library; it is distinct from Debug, which remains isolated. Development also requires the fresh component/toolchain preflight and sandboxed receipt. Hardened Runtime remains enabled. The development entitlement is needed because locally ad-hoc signed native libraries have no Apple Team ID and cannot pass strict library validation in an exception-free Release process.

Archive/Profile retain **Release** with exception-free entitlements. Production still requires appropriately signed nested code, Developer ID and notarization; a Development app must not be published as a production-signed build. Do not add the local entitlement to Release to silence a loader error. A future official signed runtime must use compatible signing identities throughout. The strict distribution verifier rejects the local Development build.

If Xcode reports missing cached Apple framework modules after a toolchain update, use Product → Clean Build Folder and rebuild. If SwiftTerm's plugin fingerprint changed, verify the package revision and source hashes before approving that plugin through Xcode; never disable global plugin validation. The receipt verifier's write argument must match its declared `component-preflight-consumed.json` output. These signing/output invariants have regression coverage.

## Reviewed headless build plugin

SwiftTerm's build-info/terminfo generator is checked against its immutable package revision and the reviewed file hashes in `swift-package-plugins.lock.json`. `prepare-swift-packages.sh` resolves packages and verifies that code before per-invocation `-skipPackagePluginValidation` approval. The SwiftPM execution sandbox remains on; no global Xcode fingerprint setting changes. A new revision or additional build-tool plugin requires review and updated hashes before approval.

## Updating vendored inputs

`native-runtime.lock.json` records verified source archives and build tools. Console `dependencies.lock.json` records exact upstream commits, archive hashes and every bundled library-file hash. Keep library source/licenses byte-identical to upstream; app wrappers remain separate. Update the sandbox read list when the pin graph or vendored file set changes:

```sh
python3 scripts/update-preflight-inputs.py
```

Review the resulting lock/input-list diff. The list grants reads only to verifier code, pins/workflows, and exact console files. The build phase writes only its declared receipt ledger; it does not need network or broader filesystem authority.

## Validation

Thirteen gate/configuration regressions cover mixed tag names, major updates, unverified lookups, changed revisions, CodeQL bundle-versus-action names, stale/changed/incomplete/toolchain-failed receipts, nonce reuse, modified vendored files, the actual sandbox output argument, and local-run/production-archive signing separation. App tests cover actual PTY filtering/input/2 MiB backpressure/termination, terminal snapshots, security boundaries and console/native integration. Native GFX and cursor lifecycle checks run under ASan/UBSan on the updated build. Exact final totals, package/startup results and remaining release gaps are recorded in `SECURITY_TESTING.md` and local project notes; tests do not certify every Mac/OS/server.

Production signing/notarization, remote CI/CodeQL acceptance, unavailable FreeRDP advisory details and broader native/live/platform coverage remain separate release requirements. Existing public/test binaries are not patched by this source update.
