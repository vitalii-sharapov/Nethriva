# Third-Party Notices

Nethriva incorporates third-party open-source software. Each component remains subject to its own license and copyright notices.

## Swift Package Manager dependencies

The exact dependency versions and source locations are recorded in `Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

- SwiftTerm 1.99.3
- Swift Argument Parser 1.8.2
- Resolved transitive Swift PNG 4.5.2 and h 1.0.1 (Apache-2.0; portable graphics dependencies, not linked by the current macOS renderer)

Xcode retrieves the corresponding license files with each package source checkout.

## Bundled RDP runtime

The current native bundle uses FreeRDP/WinPR 3.33.1 and OpenSSL 4.1.0, rebuilt from pinned source archives. `scripts/native-runtime.lock.json` records exact source URLs and SHA-256 values; the bundle contains `SBOM.cdx.json` and `PROVENANCE.json`. The recorded downstream patch bounds GFX surfaces to 8,192 pixels per dimension, 256 surfaces and 512 MiB aggregate allocation per GFX session. The obsolete SDL diagnostic-label patch is no longer applied because 3.33.1 already has the correct version guard. Patch hashes are included in provenance. `scripts/build-native-runtime.py` builds a staged candidate without replacing source resources or installing an app.

Supporting native components are SDL 3.4.20, SDL_ttf 3.2.2, FreeType 2.15.0, FDK-AAC 3.0.0, OpenH264 2.7.0, Opus 1.6.1, zlib 1.4, libusb 1.0.30, json-c 0.19 and uriparser 1.0.3. The matching LGPL libusb license and source-rebuild information are included; compatible modified dynamically linked components may be substituted and debugged under their applicable licenses. Native source downloads are checked against pinned hashes; detached upstream PGP signatures were not locally verified.

The application bundle includes FreeRDP and supporting libraries. Their redistributable license and notice files are included under:

`Nethriva/Resources/FreeRDP/ThirdPartyLicenses/`

The native bridge under `Vendor/NethrivaRDPBridge/` contains FreeRDP-derived source. Original copyright statements and Apache License 2.0 headers are retained in the applicable files.

## Bundled VM console modules

### noVNC 1.7.0

- Upstream: <https://github.com/novnc/noVNC>
- Pinned revision: `63107bd06d9e1f6136ff21aeda8cd62cbf0d433e` (v1.7.0)
- Source: `Nethriva/Resources/Consoles/noVNC/core/` and `noVNC/vendor/`
- License: Mozilla Public License 2.0, with the component-specific BSD and other notices retained in source and `noVNC/docs/LICENSE*`.
- Original `LICENSE.txt`, `AUTHORS`, source headers, and vendor notices are included in the application resources.

### SPICE HTML5

- Upstream: <https://gitlab.freedesktop.org/spice/spice-html5>
- Pinned revision: `85262d0a4f9c0d9996575e0afa57d680fcf5bd6f`
- Source: `Nethriva/Resources/Consoles/spice/src/`
- License: GNU Lesser General Public License version 3 or later; `COPYING`, `COPYING.LESSER`, original source headers, and README are bundled.

Both libraries are included as unmodified, readable JavaScript source, not an opaque binary. They load as separate modules from the `Consoles` resource directory. The Nethriva-specific transport/UI wrapper is separate in `console.js`. The included module source may be inspected or replaced with a compatible modified version for local builds; the project does not impose a prohibition on debugging those modifications. Redistribution must retain each dependency's notices and satisfy its license obligations. No proprietary VMware console SDK is bundled: VMware consoles use API-issued WebMKS tickets with bundled noVNC.

Dependency provenance is also bundled in `Nethriva/Resources/Consoles/DEPENDENCIES.md`. This notice is informational and does not replace any component's license text.
