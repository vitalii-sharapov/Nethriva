Nethriva bundled RDP runtime

FreeRDP version: 3.31.1
Architecture: Apple silicon (arm64)
Minimum macOS version: 14.0
Clients: embedded Cocoa NSView bridge and SDL3 diagnostic fallback

This self-contained runtime was built from the official FreeRDP 3.31.1
source using the upstream macOS bundle layout. The Nethriva bridge uses the
official FreeRDP macOS client implementation and exposes it to Swift as an
in-process NSView. Third-party license texts are included in ThirdPartyLicenses.
