# Nethriva release acceptance checklist

## Automated checks

- Run the full Nethriva test target.
- Build Debug and Release configurations from a clean Derived Data directory.
- Confirm the bundled Nethriva RDP bridge loads and exports the expected symbols.
- Run the release script and verify both ZIP and DMG SHA-256 files.

## Privacy and packaging

- Confirm no saved connections, credentials, private keys, hostnames, addresses, screenshots, or session logs are present.
- Confirm Keychain data and local UserDefaults data are not inside the app or archives.
- Confirm third-party licenses and notices are included.
- Confirm the downloadable app reports the intended version and build number.

## Manual acceptance

- Open Local Terminal and verify keyboard, copy, paste, resizing, and tab closing.
- Open SSH with key and password authentication; verify host-key prompts and reconnect.
- Open Telnet against a disposable test service; verify negotiation, keyboard input, resize, and reconnect.
- Exercise SFTP list, upload, download, rename, move, drag-and-drop, and unsafe-name rejection.
- Open RDP and verify focus, pointer, dynamic resolution, clipboard, file transfer, audio, reconnect, and shutdown.
- Corrupt a disposable saved-connection record and verify last-known-good recovery.
- Export diagnostics and confirm it contains no names, hosts, users, ports, paths, credentials, or logs.
- Test first launch of the downloaded build on a separate Mac and document **Open Anyway** behavior.
