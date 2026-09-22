# Compatibility

Nethriva requires macOS 14 or later. The bundled RDP runtime currently supports Apple silicon.

| Area | Current coverage |
|---|---|
| Local terminal | macOS login shells through SwiftTerm |
| SSH/SFTP | macOS OpenSSH and SFTP; common Linux, BSD, network-device, and hypervisor servers |
| Telnet | RFC-style option negotiation over TCP, including echo, terminal type, suppress-go-ahead, and window size |
| RDP | FreeRDP 3.31.1 with Windows NLA, dynamic resolution, clipboard, and file transfer |

Before reporting compatibility results, remove real hostnames, addresses, usernames, credentials, and infrastructure screenshots. File reproducible results through the GitHub issue templates.
