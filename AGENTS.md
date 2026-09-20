# Nethriva project guidance

This repository is the durable source of truth for Nethriva development. Read `README.md`, `docs/PROJECT_CONTEXT.md`, and `docs/INTEGRATION_PLAN.md` before making architectural, release, or security-sensitive changes.

## Product identity

- The product name is **Nethriva**.
- Use Nethriva consistently as the only public product identity.
- Do not introduce alternative product names or private test identities in public documentation, release notes, UI text, assets, or repository metadata.
- The public repository is `https://github.com/vitalii-sharapov/Nethriva`.

## Safety and privacy

- Never commit or publish saved connections, client names, usernames, passwords, private keys, hostnames, IP addresses, connection exports, Keychain data, local application databases, screenshots of private infrastructure, or diagnostic logs containing those details.
- Credentials belong only in macOS Keychain at runtime. Do not place them in connection models, process arguments, logs, fixtures, documentation, or release artifacts.
- Use fictional, non-routable examples in tests and documentation.
- Preserve third-party licenses and notices for Swift packages, FreeRDP, and bundled runtime libraries.

## Development workflow

- Inspect `git status` before editing and preserve unrelated user changes.
- Keep changes focused and add or update tests when behavior changes.
- Use `apply_patch` for source and documentation edits.
- Build through the `Nethriva` scheme for `My Mac`. The bundled RDP runtime currently targets Apple silicon and macOS 14 or later.
- Verify meaningful changes with the smallest relevant tests and a full application build when practical.
- Do not publish, tag, or replace release assets unless the user explicitly requests it.

## Architecture boundaries

- SwiftUI owns the application shell, connection management, tab state, and configuration UI.
- AppKit hosts terminal and embedded remote-desktop surfaces where native focus, input, drag-and-drop, and view lifecycle control are required.
- SwiftTerm renders local and SSH terminal sessions.
- macOS OpenSSH and SFTP provide the active SSH/SFTP transport and reuse the user's existing SSH configuration, keys, agent, and host trust.
- FreeRDP is integrated through the bundled native Cocoa bridge; do not reimplement RDP in Swift.
- Connection metadata is local. Passwords are stored in macOS Keychain.
- Keep local terminal, SSH, SFTP, and RDP session lifecycles independent so switching tabs does not terminate active sessions.

## Public support links

- GitHub Sponsors: `https://github.com/sponsors/vitalii-sharapov`
- Ko-fi one-time tips: `https://ko-fi.com/vsharapov`
- Support is optional and must not change functionality, access, licensing rights, or contributor treatment.

## Important references

- `README.md` — public capabilities, build instructions, usage, and release notes
- `docs/PROJECT_CONTEXT.md` — current technical and product state
- `docs/INTEGRATION_PLAN.md` — subsystem implementation and packaging details
- `docs/ROADMAP.md` — prioritized future work
- `CONTRIBUTING.md` — contribution workflow
- `SECURITY.md` — vulnerability-reporting policy
- `THIRD_PARTY_NOTICES.md` — bundled dependency notices
