# Security Policy

## Supported versions

Security remediation targets the latest development source. A fix in a working tree or on a source branch does not establish that a published binary contains it. Consult the specific release's notes and hashes before relying on a fix.

The November 2026 hardening and follow-up fixes are included in the **0.13.0/build 30 preview**. Version 0.12.1 and older test exports are separate artifacts and do not receive these fixes automatically. The preview is ad-hoc signed and unnotarized; it does not satisfy production signing or complete security acceptance. Download manually from the preview release and preserve your connection-library backup before testing. See [the assessment](SECURITY_AUDIT.md), [testing evidence](SECURITY_TESTING.md), and [hardening requirements](SECURITY_HARDENING.md) for scope and unresolved checks.

## Reporting a vulnerability

Please do not disclose an exploitable vulnerability in a public issue. If GitHub private vulnerability reporting is enabled for the repository, use **Security → Report a vulnerability**. Otherwise, open a minimal issue asking the maintainer for a private reporting channel without including exploit details, credentials, hostnames, addresses, or logs containing private infrastructure information.

Include the affected Nethriva version/build, macOS version, connection type, impact, and the smallest safe reproduction description. Prefer synthetic local fixtures. Remove passwords, private keys, tokens, usernames, host inventories, connection exports, ticket URLs, and other sensitive data before sharing diagnostics. Do not probe systems you do not own or have permission to test.

The maintainer will coordinate investigation and any disclosure through the agreed private channel. No response-time or fix-date guarantee is implied. Do not publish exploit details before coordinated review.

General bugs that do not expose sensitive information can be reported through the public issue tracker.
