# Contributing to Nethriva

Thank you for helping improve Nethriva. Bug reports, documentation improvements, testing feedback, and focused code contributions are welcome.

## Before contributing

- Use macOS 14 or later and a current Xcode installation.
- The bundled RDP runtime is currently Apple-silicon only.
- Never commit passwords, private keys, connection exports, host inventories, screenshots containing credentials, or private infrastructure details.
- Preserve third-party copyright and license notices.

## Build the project

1. Fork and clone the repository.
2. Open `Nethriva.xcodeproj` in Xcode.
3. Select the `Nethriva` scheme and `My Mac` destination.
4. Allow Xcode to resolve the pinned Swift packages.
5. Build with Command-B or run with Command-R.

For command-line verification:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Nethriva.xcodeproj \
  -scheme Nethriva \
  -configuration Debug \
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
