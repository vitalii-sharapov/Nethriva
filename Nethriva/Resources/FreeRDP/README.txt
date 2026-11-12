Nethriva bundled RDP runtime

FreeRDP / WinPR version: 3.33.1
OpenSSL version: 4.1.0
Architecture: Apple silicon arm64; M1 CPU baseline
Minimum macOS version: 14.0
Clients: embedded Cocoa NSView bridge and SDL3 diagnostic fallback

Sources and exact hashes: scripts/native-runtime.lock.json in the source repository.
Native component versions and source hashes: SBOM.cdx.json.
Build settings, bridge-source hashes and binary hashes: PROVENANCE.json.
Recorded patches bound graphics allocations per surface/session and correct optional SDL event labels. See the source lock and patch hashes.
All runtime libraries are built from pinned sources, relocated to this bundle, and ad-hoc signed.
This does not provide Developer ID signing, notarization or live-server acceptance.
