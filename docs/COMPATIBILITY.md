# Compatibility

Nethriva requires macOS 14 or later. The bundled RDP runtime currently supports Apple silicon.

## Apple silicon startup baseline

The intended hardware range is M1, M2, M3, M4, M5 and M6, including their variants, running a macOS version supported by that Mac and no earlier than macOS 14. Debug and Release explicitly use the M1 code-generation baseline for arm64 C and Swift sources; no newer-chip CPU flag is required. This follows Apple's [arm64 build architecture](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary). The native dependency bundle is rebuilt from pinned sources with that baseline; this still does not prove execution on every chip/OS.

Release verification requires a generic `ARM64_ALL` slice and the macOS platform in every bundled arm64 binary, checks each minimum OS against the app declaration, rejects nonportable dependency/search paths, validates the RDP dependency closure, and verifies the extracted package's signature, links and executable permissions. A generic header and deployment target are structural checks, not hardware emulation.

The October 22, 2026 local acceptance machine is **M5 Pro, macOS 27.0.1**. M1/M2/M3/M4/M6 hardware and macOS 14/15/26 execution remain unverified. Keep these separate from the intended support range; never mark a chip or OS as tested from compilation alone. Notarization and clean-machine Gatekeeper first-launch acceptance also remain separate.

Use `scripts/smoke-app-launch.swift` against a trusted extracted app in a normal Mac desktop session. It starts a separate process through LaunchServices with Nethriva's empty hosted-test profile, waits for completed launch and a workspace window, checks that it stays alive, and closes only that test instance. It never opens a connection or copies saved credentials. Desktop-service access is required; a restricted command sandbox is not an equivalent launch environment.

November 11, 2026 dependency update: the 0.13.0/build 30 preview is built/tested on M5 Pro/macOS 27.2 with Xcode 27.2/Swift 6.4.2. Managed packages/runtime are current at that check. Xcode 26+ is required for Swift tools 6.2; the app/native deployment minimum remains macOS 14. Other chips/older OS versions, physical devices and live host/provider matrices remain unverified.

Hosted publication follow-up: the macOS 26 arm64 Debug job passes. Earlier full Intel runs and its latest synthetic console test pass, but its latest four-native-pane test fails; Intel app-core acceptance remains incomplete. The macOS 27.0.1 virtual machine fails the actual rendered WebMKS pixel check (background instead of frame), despite successful connection/geometry/input assertions. The causes remain open; local macOS 27.2 passes. These are virtual-machine/app-core results, not additional physical-chip or Intel-RDP certification. The preview retains the failing tests and discloses incomplete CI acceptance in [the release record](releases/0.13.0.md).

## Connection coverage

| Area | Current coverage |
|---|---|
| Local terminal | macOS login shells through SwiftTerm |
| SSH/SFTP | macOS OpenSSH authentication; structured SFTP v3 over the SSH subsystem. Real local system SFTP-server transfers tested; remote version acceptance tracked separately |
| Telnet | RFC-style option negotiation over TCP, including echo, terminal type, suppress-go-ahead, and window size |
| Serial | macOS `/dev/cu.*` adapters with configurable baud rate, framing, flow control, and local echo; test against the specific USB console cable and target device |
| RDP | FreeRDP 3.33.1 with Windows NLA, dynamic resolution, clipboard, and file transfer |
| VNC | Bundled noVNC 1.7.0; TCP, TCP+SSH, WSS or system-validated TLS-wrapped TCP; synthetic local RFB 3.8 handshake and Ctrl+Alt+Del tested; broader live transport acceptance pending |
| SPICE | Bundled SPICE HTML5; native TCP or WSS; WebKit module loading tested; guest interaction not yet validated |

## New virtualization adapters — live testing pending

| Platform | Required access / API | Verification status |
|---|---|---|
| Proxmox VE | HTTPS API, VM console/power/config privileges, node VNC WSS endpoint | Parser tests; live host pending |
| VMware ESXi/vCenter | vSphere SOAP `/sdk`; one-time WebMKS WSS ticket and bundled noVNC; direct ESXi reachability required | Mock API/ticket checks and local encrypted console tests; experimental registered-client PKCE/MFA/token-exchange login tested synthetically, live provider acceptance pending |
| QEMU/libvirt | SSH, trusted host key, virsh permissions, configured VNC/SPICE graphics | Inventory/XML tests; live virsh/tunnel/guest-agent flow pending |
| Hyper-V | Windows OpenSSH, Hyper-V PowerShell, VMConnect 2179 | Inventory/encoded-command/FreeRDP argument tests; live VMConnect pending |
| XCP-ng/XenServer through Xen Orchestra | XO JSON-RPC and authenticated VNC proxy | Parser tests; live token/proxy/power/media flow pending |
| Nutanix AHV through Prism Central | v3 inventory, v4 actions, newer console-token API and accepted WSS cookie/bearer authentication | Parser/task-value tests; experimental, live host/API version validation pending |

No exact hypervisor version is certified by these unit tests. Guest-agent support and host policy determine resizing, clipboard, graceful shutdown, media, and enhanced-console capabilities. See [VIRTUALIZATION.md](VIRTUALIZATION.md) for setup and limits; record sanitized successful/failed manual results here before strengthening compatibility claims.

## Expanded verification workflow

GitHub Actions tests on xcode-27 (Xcode 27.2), macos-26 and macos-26-intel. Only xcode-27 performs current-toolchain Release/package/universal-core checks; older images provide compatible-toolchain Debug regression coverage. Their default Xcode 26.6 is not treated as current release validation. Check the exact release commit’s workflow results; configuration alone is not proof of successful remote execution or older-OS testing. Minimum deployment target is not proof of testing every macOS release. Apple-silicon FreeRDP remains the only bundled runtime; Intel jobs do not add Intel RDP support.

The universal application core has been cross-built for arm64/x86_64 locally. Packaging refuses a universal release without a separately validated, matching Intel RDP bundle. No live Intel/Rosetta RDP result is recorded. VM details/snapshot support varies by adapter, and X11 needs XQuartz plus host support. See [ADVANCED_CONNECTIONS.md](ADVANCED_CONNECTIONS.md); synthetic tests and configured CI are not live identity-provider, hypervisor or VoiceOver certification.

Structured SFTP integration tests run against `/usr/libexec/sftp-server` using temporary synthetic files, not a remote account. They cover literal names, recursive folders, pipelined upload/download, conflict choices, atomic file publication, cancellation, and symlink refusal. Safe overwrite needs `posix-rename@openssh.com`; a server lacking that extension can still use non-conflicting or renamed uploads. Authentication still uses system OpenSSH and a fixed SFTP authentication bootstrap.

The user reports that VMware inventory/console/display fitting now works, but sanitized ESXi/vCenter versions and a complete acceptance pass have not been recorded. Treat this as user-reported success, not certification of all VMware versions.

Use the [manual acceptance pass](RELIABILITY.md#suggested-local-acceptance-pass) and record results here:

| App/build | macOS/architecture | Sanitized server/product version | Scenarios | Result/evidence |
|---|---|---|---|---|
| Local 0.13.0 development | Current development Mac, arm64 | Local system SFTP server | Structured listing/transfers/conflicts/cancellation | Automated tests; no remote authentication certification |
| Local 0.13.0 development | Version not recorded | VMware versions not recorded | Inventory/console/fitting | User reports working; formal manual pass pending |
| Pending | macOS 14 / 15 / 26 | Disposable SSH, Windows RDP, network device, hypervisor targets | Auth/input/transfers/recovery/resize | Not tested; fill only after actual runs |

Before reporting compatibility results, remove real hostnames, addresses, usernames, credentials, and infrastructure screenshots. File reproducible results through the GitHub issue templates.
