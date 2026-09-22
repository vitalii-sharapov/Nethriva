# Nethriva roadmap

This roadmap records direction rather than promises or deadlines. Priorities should be adjusted from real user reports and reproducible issues.

## Current foundation

- [x] Native SwiftUI/AppKit application shell
- [x] Connection sidebar, groups, favorites, and tabbed sessions
- [x] Local terminal and interactive OpenSSH sessions through SwiftTerm
- [x] Native Telnet sessions for legacy devices with plaintext safety warnings
- [x] Integrated SSH file tree and full SFTP browser
- [x] Recursive upload/download and drag-and-drop file workflows
- [x] Embedded FreeRDP desktop sessions
- [x] Dynamic RDP resolution, pointer, keyboard, clipboard, and file transfer
- [x] RDP audio, device, gateway, certificate, graphics, scaling, and reconnect settings
- [x] Keychain credential storage and local connection persistence
- [x] Connection-library import/export with preserved groups and optional encrypted credentials
- [x] Separate development and release connection data profiles
- [x] Complete offline help manual
- [x] Public source repository, release package, issue tracker, and support links

## Priority 1 — reliability and feedback

- [x] Add reproducible issue templates for bugs and feature requests
- [ ] Expand automated coverage around SSH/SFTP process failure and reconnection
- [ ] Expand RDP regression coverage for focus, scaling, clipboard, and file transfer
- [x] Add clear diagnostic export with automatic redaction of sensitive values
- [x] Document a repeatable manual release acceptance checklist

## Priority 2 — distribution and compatibility

- [x] Automate clean Release builds, ZIP/DMG creation, and SHA-256 generation
- [ ] Add Intel-compatible or universal FreeRDP runtime support
- [x] Add a compatibility matrix for macOS and common SSH/Telnet/RDP server versions
- [x] Add a simple DMG workflow
- [ ] Evaluate an optional update-checking mechanism suitable for open-source distribution
- [ ] Keep Developer ID signing and notarization optional unless project circumstances change

## Priority 3 — connection management

- [ ] Search and filter saved connections
- [x] Import and export non-secret connection metadata and optional encrypted credentials
- [x] Add safe backup and restore guidance
- [ ] Improve keyboard navigation and accessibility coverage
- [ ] Add configurable terminal appearance profiles

## Priority 4 — advanced workflows

- [ ] Evaluate additional SSH capabilities only when they improve on the current system OpenSSH path
- [ ] Add configurable port forwarding and tunnel management
- [ ] Evaluate session logging with explicit opt-in and strong secret redaction
- [ ] Evaluate additional file-conflict and transfer-queue controls
- [ ] Consider a universal packaging pipeline if community demand justifies it

## Non-goals without a separate design decision

- Hosted credential storage or a cloud connection vault
- Telemetry enabled by default
- Publishing private infrastructure details for diagnostics
- Reimplementing SSH, SFTP, or RDP protocols from scratch
- Presenting Telnet as secure or appropriate outside a trusted legacy management network
- Making financial support a requirement for features or use
