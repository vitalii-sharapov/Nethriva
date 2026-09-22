# Third-Party Notices

Nethriva incorporates third-party open-source software. Each component remains subject to its own license and copyright notices.

## Swift Package Manager dependencies

The exact dependency versions and source locations are recorded in `Nethriva.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

- SwiftTerm
- Swift Argument Parser

Xcode retrieves the corresponding license files with each package source checkout.

## Bundled RDP runtime

The application bundle includes FreeRDP and supporting libraries. Their redistributable license and notice files are included under:

`Nethriva/Resources/FreeRDP/ThirdPartyLicenses/`

The native bridge under `Vendor/NethrivaRDPBridge/` contains FreeRDP-derived source. Original copyright statements and Apache License 2.0 headers are retained in the applicable files.

This notice is informational and does not replace any component's license text.
