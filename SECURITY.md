# Security Policy

## Supported versions

Security remediation targets the latest development source. A fix in a working tree or on a source branch does not establish that a published binary contains it. Consult the specific release's notes and hashes before relying on a fix.

The **0.13.1/build 31 release** updates VMware console certificate verification. SHA-1-only tickets require normal macOS certificate and hostname validation. Install 0.13.1 to receive this fix. The app is locally signed and has no Apple notarization. See the [release notes](docs/releases/0.13.1.md), [assessment](SECURITY_AUDIT.md), and [test evidence](SECURITY_TESTING.md) for details.

## Reporting a vulnerability

Please do not disclose an exploitable vulnerability in a public issue. If GitHub private vulnerability reporting is enabled for the repository, use **Security → Report a vulnerability**. Otherwise, open a minimal issue asking the maintainer for a private reporting channel without including exploit details, credentials, hostnames, addresses, or logs containing private infrastructure information.

Include the affected Nethriva version/build, macOS version, connection type, impact, and the smallest safe reproduction description. Prefer synthetic local fixtures. Remove passwords, private keys, tokens, usernames, host inventories, connection exports, ticket URLs, and other sensitive data before sharing diagnostics. Do not probe systems you do not own or have permission to test.

The maintainer will coordinate investigation and any disclosure through the agreed private channel. No response-time or fix-date guarantee is implied. Do not publish exploit details before coordinated review.

General bugs that do not expose sensitive information can be reported through the public issue tracker.
