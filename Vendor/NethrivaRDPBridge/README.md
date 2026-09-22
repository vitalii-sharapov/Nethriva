# Nethriva Cocoa RDP bridge

This directory contains the small Objective-C bridge used to host FreeRDP's macOS `MRDPView` inside a Nethriva tab. The view, input, clipboard, cursor, and client files are derived from the official FreeRDP 3.31.1 `client/Mac` implementation under its Apache-2.0 license. `NethrivaRDPBridge.m` supplies the narrow C interface loaded by Swift.

Nethriva-specific changes keep the view constrained to its SwiftUI/AppKit container, scale drawing and pointer coordinates during live resize, send Display Control monitor-layout updates after the available tab area changes, exchange clipboard text as Windows Unicode data, and translate familiar macOS editing shortcuts into their Windows equivalents.

Authentication and certificate prompts are built with AppKit alerts inside the host app. They do not rely on MacFreeRDP nib files or an RDP tab already having a parent window; a blank saved username opens a username/password prompt instead of attempting to present a nil sheet.

The RDP-server credential alert includes an opt-in Keychain checkbox. The bridge holds that candidate only for its session and hands it to Swift after FreeRDP connects; Swift persists the password under the saved connection's Keychain identifier and updates username/domain metadata. Unchecked, cancelled, and failed attempts are not persisted. Gateway and smart-card prompts are excluded.

The compiled arm64 library is stored at:

```text
Nethriva/Resources/FreeRDP/Frameworks/libNethrivaRDP.dylib
```

It links against the self-contained FreeRDP libraries in the same `Frameworks` directory. Rebuild it with Xcode's `clang`, the matching FreeRDP generated headers, and these source files; use `@loader_path` as its runtime library search path. The full FreeRDP and linked-library license texts ship under `Nethriva/Resources/FreeRDP/ThirdPartyLicenses`.

The `NethrivaRDP` symbol prefix and `libNethrivaRDP.dylib` filename are private implementation identifiers used by the bundled native runtime.
