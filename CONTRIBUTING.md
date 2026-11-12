# Contributing to Nethriva

Thank you for helping improve Nethriva. Bug reports, documentation improvements, testing feedback, and focused code contributions are welcome.

## Before contributing

- The app targets macOS 14 or later; building requires Xcode 26+ with Swift tools 6.2 or newer. The validated toolchain is Xcode 27.2.
- The bundled RDP runtime is currently Apple-silicon only.
- Never commit passwords, private keys, connection exports, host inventories, screenshots containing credentials, or private infrastructure details.
- Preserve third-party copyright and license notices.

## Build the project

1. Fork and clone the repository.
2. Open `Nethriva.xcodeproj` in Xcode.
3. Select the `Nethriva` scheme and `My Mac` destination.
4. Allow Xcode to resolve the pinned Swift packages.
5. Build with Command-B or run with Command-R. Run uses optimized Development with local signing permissions and the normal Release data profile. Debug stays isolated; archives use strict Release.
6. Review and approve changed package plugins only after their pinned source hashes are verified. All non-Debug builds require a fresh complete upstream check; see [dependency updates](docs/DEPENDENCY_UPDATES.md).

For command-line verification:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/prepare-swift-packages.sh /private/tmp/NethrivaPackages
xcodebuild -project Nethriva.xcodeproj \
  -scheme Nethriva \
  -configuration Debug \
  -clonedSourcePackagesDirPath /private/tmp/NethrivaPackages \
  -skipPackagePluginValidation \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

## Submit a change

1. Create a focused branch from `main`.
2. Keep unrelated changes out of the branch.
3. Add or update tests when behavior changes.
4. Build the application and run the test target before submitting.
5. Explain the problem, the solution, and how the change was tested in the pull request.

Changes to the bundled FreeRDP runtime or native bridge should describe the upstream version, target architecture, build flags, and any third-party license changes.
