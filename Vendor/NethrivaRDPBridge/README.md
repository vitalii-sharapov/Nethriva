# Nethriva Cocoa RDP bridge

This directory contains the small Objective-C bridge used to host FreeRDP's macOS `MRDPView` inside a Nethriva tab. The view, input, clipboard, cursor, and client files are derived from the official FreeRDP 3.31.1 `client/Mac` implementation under its Apache-2.0 license. `RemoteDeckRDPBridge.m` supplies the narrow C interface loaded by Swift.

Nethriva-specific changes keep the view constrained to its SwiftUI/AppKit container, scale drawing and pointer coordinates during live resize, send Display Control monitor-layout updates after the available tab area changes, exchange clipboard text as Windows Unicode data, and translate familiar macOS editing shortcuts into their Windows equivalents.

The compiled arm64 library is stored at:

```text
Nethriva/Resources/FreeRDP/Frameworks/libRemoteDeckRDP.dylib
```

It links against the self-contained FreeRDP libraries in the same `Frameworks` directory. Rebuild it with Xcode's `clang`, the matching FreeRDP generated headers, and these source files; use `@loader_path` as its runtime library search path. The full FreeRDP and linked-library license texts ship under `Nethriva/Resources/FreeRDP/ThirdPartyLicenses`.

The `RemoteDeckRDP` symbol prefix and `libRemoteDeckRDP.dylib` filename are retained as a private compatibility ABI for the already-built native runtime. They are not user-facing product branding.
