# Advanced connections and distribution

These are the local implementations and deliberate limits of original roadmap items 24–30. The **0.13.0, build 30 preview** includes these implementations; see [the release record](releases/0.13.0.md). Automated checks do not certify real identity providers, guests, Intel RDP, or a complete VoiceOver workflow. No automatic update installation, credential export, guest modification, or hosted service was introduced.

## VMware federated sign-in (24)

Edit a VMware Virtualization Host and enable **Interactive federated sign-in (vCenter)**. An identity administrator must register a **public/native OAuth client** in the existing vCenter federation configuration, permitting authorization-code flow with **S256 PKCE** and the redirect URI:

```text
nethriva-auth://oauth/callback
```

Enter administrator-approved HTTPS authorization/token URLs, the public client ID, scopes, and optional resource. The default scopes suit typical ADFS registrations; other providers may require different approved scopes. The exchange token type defaults to JWT; choose OAuth Access Token only if the vCenter/provider integration requires that type. Nethriva does not discover or change the identity provider, request a client secret, implement password-grant authentication, disable MFA, or silently retry weaker authentication.

Open the inventory tab and choose **Federated Sign In…**. The system authentication browser handles organization sign-in and MFA. State and the exact callback are checked; token requests use ephemeral, bounded HTTPS with redirects refused. vCenter **7.0.2 or later** must support `/api/vcenter/authentication/token`, issuing a base64 SAML 2.0 bearer assertion. SOAP `LoginByToken` submits the original assertion without rewriting its signed XML. vCenter, not Nethriva, validates the assertion's signature, audience and lifetime. Holder-of-key assertions are not supported by this flow.

Both identity-provider and vCenter certificates must pass macOS system trust. Federation refuses an Ignore/TOFU vCenter policy; install the organization's CA using its approved process. Never bypass certificate errors or disable MFA to make sign-in work.

OAuth tokens are not persisted or refreshed. The SAML assertion stays in connection-scoped memory for at most five minutes (or the returned shorter lifetime), allowing independent console tabs to obtain their own API sessions/tickets. Closing the last related tab, deleting the connection, quitting, or locking clears authorization. Expiry requires another interactive sign-in for a new API session; an already authenticated host session follows the host's session policy. Standalone ESXi uses its own account, not federated sign-in.

Client registration is mandatory and live provider acceptance remains pending. Do not assume every ADFS/Entra/Ping configuration supports the selected native flow. Token/registration errors reveal no raw response body or token.

Primary references: [Broadcom federation/MFA registration guidance](https://knowledge.broadcom.com/external/article/387932/domain-user-authentication-to-vcenter-vi.html), [vCenter token exchange](https://developer.broadcom.com/xapis/vsphere-automation-api/latest/api/vcenter/authentication/token/post/), [SessionManager LoginByToken](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.SessionManager.html).

## VM details and guest shortcuts (25)

Select a VM; **Details** toggles its right-hand panel. The adapter displays available host/node, OS, CPU, memory, tools and guest IP information. **Refresh Details** fetches on demand, not for every VM. Missing fields explicitly read **Not reported**. VMware uses guest/net/hardware properties and a host-name lookup; Proxmox uses configuration and optional guest-agent interface information; libvirt reads domain XML and optional agent addresses; Hyper-V uses VM/network-adapter properties; Nutanix uses available v3 resource fields. Some adapters cannot report the guest OS or all addresses. Guest tools/agent and host permissions are required for many fields.

An IP's **SSH** or **RDP** button opens a separate, unsaved guest connection. Management credentials, domains and profiles are **not** copied. Only usable IP literals become shortcuts; loopback, unspecified, link-local, multicast and arbitrary hostname values are refused. Enter the guest's own credentials normally.

## Tasks and snapshots/checkpoints (26)

The inventory displays the current host-operation phase. VMware task polling shows the host's reported percentage; Proxmox/SSH operations show indeterminate progress where no reliable percentage exists. **Stop Monitoring** cancels local observation only. A host operation already accepted may continue; no request is replayed and no rollback or host-task cancellation is implied. Refresh the host to inspect its actual state. Other adapters may acknowledge an asynchronous request without full task polling.

The Details panel offers **Create Snapshot…**, **Revert…**, and **Delete…** for VMware, Proxmox and SSH-managed Hyper-V/libvirt. Every change requires confirmation. Deletion/reversion refresh the selected VM's snapshot inventory and reject a stale identity before issuing the change. Names are limited to letters, digits, hyphens and underscores. VMware deletion does not request recursive child deletion; no force flags are supplied.

- VMware and Proxmox creation excludes guest memory and does not request application quiescing. Treat it as crash-consistent, not a database backup.
- Hyper-V uses the VM's configured checkpoint policy; permissions/storage/guest support determine success.
- libvirt changes require a safely powered-off domain and use conservative default snapshot commands, without forced revert, disk-only/external creation or recursive deletion. Unsupported storage/snapshot modes fail through the host; advanced workflows belong in the host tools.
- Xen Orchestra/Nutanix snapshot management is not implemented in these adapters; the UI says so instead of offering a speculative destructive operation.

Snapshots are **not backups**. Reversion can discard data and change power state; deletion removes a recovery point. Test against disposable guests before production use.

## Standalone VNC/SPICE transports (27)

Edit the console's **Transport**:

- **Direct TCP**: unencrypted, optionally forwarded through a saved SSH connection. Authenticate the SSH host first and verify its fingerprint. Without a tunnel, use only an explicitly trusted isolated network.
- **Secure WebSocket**: a WSS proxy with the configured path, such as `/websockify`; follows the configured console certificate policy.
- **TLS-wrapped TCP**: a TLS listener that encrypts the entire VNC/SPICE stream before protocol negotiation, such as an administrator-configured TLS proxy. Requires TLS 1.2+, system certificate trust and the configured hostname. It never uses Ignore/TOFU, silently downgrades, or reuses management cookies. A native **VeNCrypt-only** or SASL listener is not equivalent to this outer TLS transport.

Legacy VNC authentication alone does not encrypt a desktop. Prefer SSH, strict WSS or a validated TLS listener. Server/guest support still determines clipboard and resizing; local Fit Screen and view-only controls remain separate. Cross-version live VNC/SPICE acceptance is still required.

## X11 and XQuartz (28)

In a connection's **SSH Options**, choose **X11 Forwarding**: Off (default), Untrusted `-X`, or Trusted `-Y`. Install/start XQuartz separately, then use **Detect XQuartz Display** to read the local launch-agent DISPLAY. Installation may require logging out/in. The app does not install XQuartz, change its security preferences, expose a public X11 listener, or run `xhost +`.

The remote SSH server must permit X11 forwarding and have `xauth`. Nethriva uses `/opt/X11/bin/xauth` and accepts only a local DISPLAY/socket. Trusted forwarding lets remote applications interact with other X applications and potentially monitor input; use it only with a fully trusted host. Untrusted forwarding is safer but may not support every XQuartz/application configuration.

X11 terminal sessions disable multiplexing for that transport so an unrelated master cannot inherit/share the forwarded display. The adjacent SFTP browser authenticates/reuses its separate non-X11 transport and may need its own authentication. SFTP explicitly disables X11 forwarding. Changed options apply to a new terminal session.

References: [XQuartz FAQ](https://www.xquartz.org/FAQs.html), [OpenSSH X11 options](https://man.openbsd.org/ssh).

## Universal packaging and verified updates (29)

The application core cross-builds for arm64 and x86_64. **The repository still supplies only an arm64 RDP runtime.** An Intel slice is not proof that FreeRDP/its native bridge can load on Intel. The runtime loader chooses an architecture-specific bundle and reports a clear error instead of attempting to load arm64 libraries on Intel.

The release script defaults to arm64. Universal packaging requires an independently built, license-complete **matching x86_64 FreeRDP 3.31.1/native bridge** bundle with `Frameworks`, `MacOS` and `ThirdPartyLicenses`. Provide its absolute location as `NETHRIVA_INTEL_RDP_ROOT`, then run:

```sh
zsh scripts/build-release.sh 0.13.0 universal
```

The validator checks Mach-O architecture, bridge export, runtime layout and machine-local dependency paths. Universal packaging refuses a missing/mismatched runtime; it embeds Intel resources under `FreeRDP/x86_64`. Live Intel/Rosetta acceptance remains required. CI includes cross-compilation, not certification or automatic publication. No Intel release was created in this development pass.

The packager uses an invocation-owned temporary build directory and refuses existing ZIP/DMG outputs. ZIP/DMG checksums and ad-hoc signature validation remain. `NETHRIVA_RELEASE_OUTPUT` can select a new output directory. None of these steps uploads files.

### Optional publisher-signed update channel

**Help → Check for Updates…** is manual, opt-in networking to the public GitHub release API. The app does not send account credentials, connection metadata or diagnostics. It never installs automatically or removes Gatekeeper/quarantine protection.

Verified downloads require a publisher-held Ed25519 private key, its base64 public key compiled into the app using `NETHRIVA_UPDATE_PUBLIC_KEY`, and `Nethriva-update.json` / raw 64-byte `Nethriva-update.sig` assets on the newer stable GitHub release. With no pinned public key or signed manifest, downloads are disabled; **Official Releases** still opens the normal GitHub page. These are not Apple Developer ID certificates and signing them does not provide notarization.

Publisher setup is explicit, outside normal builds:

```sh
# Choose a private path outside the repository. Never commit or upload this file.
zsh scripts/sign-update.sh --create-key /absolute/private/path/update-signing.key
# Save/back up that key securely; use the printed PUBLIC key for the build setting.
zsh scripts/sign-update.sh 0.13.0 arm64 /absolute/path/Nethriva-0.13.0-macOS-arm64.zip /absolute/private/path/update-signing.key /absolute/path/new-manifest-folder
```

The signing script refuses symlink/public-readable key files and existing outputs, and verifies its own signature. It does not publish. Keep one signing key stable across releases, protect/back it up, and plan key rotation before changing it. The current source has **no publisher key pinned**, so no existing GitHub asset is treated as a verified update. A release's signature must be valid, version newer than installed, asset URL from this repository's GitHub release path, architecture suitable, size bounded and downloaded SHA-256/size exactly matching the signed values. Extract and install the verified ZIP manually.

Downloaded ZIPs are private, non-overwriting files with explicit macOS quarantine metadata. A failure to attach quarantine discards the app-created download instead of bypassing launch approval. The packaging/signing wrappers use a full Xcode installation without changing the system's selected developer tools.

The downloadable app remains locally signed, not Apple-notarized. After reviewing the source, official release and checksum, first launch may require **System Settings → Privacy & Security → Open Anyway**. Do not disable Gatekeeper globally. Publisher update signatures and Apple launch approval are different checks.

## Keyboard and accessibility (30)

- **⌘K** Quick Connect; **⌘F** connection search; **⌘O** open selected connection; **⇧⌘U** selected SSH client's SFTP.
- **⇧⌘] / ⇧⌘[** next/previous session, **⌘1…⌘9** numbered sessions, **⇧⌘W** close current session. **⌘W** retains normal window semantics. Selecting a detached session raises its existing window.
- Focus the sidebar and use **↑/↓** to select, **Shift+↑/↓** to extend selection, **←/→** collapse/expand a selected group, **Return** open a client or toggle a group. Typing begins a name/IP search. Selection scrolls into view.
- **Return** in the VM inventory opens the selected running VM; standard Tab/Shift-Tab/Space operate native buttons/forms. Enable macOS **Keyboard Navigation** if you want Tab to reach all controls, not just text fields.
- Session tabs/close buttons, connection/group selection actions and VM inventory have explicit accessibility labels/actions and selected state. The privacy shield hides underlying accessibility content and uses a plain AppKit sibling container even for auxiliary SwiftUI windows; **Return** starts Mac-authenticated unlocking.
- Terminal profiles provide readable font-size choices; RDP interface scale and console fitting remain separate so app shortcuts do not change guest coordinates or resolution.

This is an accessibility improvement, not full certification: VoiceOver acceptance across every form, split/detached window and remote framebuffer remains pending. Remote GUI accessibility is limited by the remote protocol/server; an RDP/VNC canvas does not expose the guest's complete accessibility tree.

## Acceptance checks

Use synthetic/disposable targets and no personal secrets in test artifacts:

1. Registered native-client MFA success/cancel/expiry, wrong state, trust errors, unsupported token types, last-tab close and lock during every phase. Verify no tokens in preferences/archives/logs.
2. Guest details across running/stopped VMs, missing agent/permissions, multiple IPs and correctly credential-free SSH/RDP shortcuts.
3. Confirm/cancel each snapshot action, stale selection, denied privileges, queued/completed/failed tasks, stop monitoring and reconnect without replay. Verify real host state separately.
4. TCP+SSH, strict WSS and a real TLS-wrapped console; reject wrong hostname, untrusted/expired certificates and non-TLS listener without fallback.
5. XQuartz fresh installation, local DISPLAY detection, trusted/untrusted X apps, missing xauth, disabled server forwarding, separate SFTP authentication and closing the X11 transport.
6. Intel runtime build/license review, clean Intel/Apple-silicon ZIP/DMG installation, matching native dependencies and no personal data; reject incomplete bundles. Never label a cross-build as live Intel RDP acceptance.
7. Disposable update keys/manifests, wrong signature/size/hash/architecture/URL, rollback, cancelled checks/downloads and manual installation. Do not pin a disposable test key in a real release.
8. All listed shortcuts, long sidebar scrolling, split/detached focus, keyboard navigation and VoiceOver with privacy/username display settings respected. Mac authentication is performed by the user.
