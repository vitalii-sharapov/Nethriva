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
- Verify Telnet offers saved username and password only at their corresponding prompts.
- Open a Serial tab with a disposable USB adapter; verify port discovery, line settings, input, paste, reconnect, and device release on close.
- Create a disposable shared credential profile, link SSH/Telnet/RDP test connections, rotate its password, and verify a new session uses it without changing unrelated credentials.
- Export and import disposable profile-linked connections with and without credentials; verify the plain archive has no password and the encrypted archive restores its Keychain password.
- Verify nested-group search, Command/Shift selection, multi-item drag, folder moves, and quick rename.
- Exercise SFTP list, upload, download, rename, move, drag-and-drop, and unsafe-name rejection.
- Open RDP and verify focus, pointer, dynamic resolution, clipboard, file transfer, audio, reconnect, and shutdown.
- Corrupt a disposable saved-connection record and verify last-known-good recovery.
- Export diagnostics and confirm it contains no names, hosts, users, ports, paths, credentials, or logs.
- Test first launch of the downloaded build on a separate Mac and document **Open Anyway** behavior.
