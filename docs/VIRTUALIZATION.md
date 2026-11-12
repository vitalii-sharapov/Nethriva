# Virtualization hosts and consoles — 0.13.0

Included in the [build-30 preview](releases/0.13.0.md). Platform/version-specific live acceptance remains pending.

These integrations add VM discovery, console tabs, and focused management actions. They are not a replacement for a host's complete administrative UI. The adapters are new: automated tests exercise parsing, safety boundaries, console loading, and a local VNC connection, but live acceptance testing against each host version is still required.

## Start here

1. Add a connection and select **Virtualization Host** as its protocol.
2. Choose the platform. Enter a hostname/IP only, not a full URL. The platform supplies its usual management port; change it if your host uses another port.
3. Supply host credentials or a reusable credential profile. Passwords and API tokens belong in the password field/Keychain, never the host name, group name, or ISO field.
4. Choose a certificate policy for HTTPS platforms. **Require Valid Certificate** is the default. For a private self-signed host, verify the fingerprint with your administrator before approving **Trust on First Use**. Do not use **Ignore Certificate Warnings** on an untrusted network.
5. Open the connection. For SSH platforms, use **Host SSH** to verify an unknown host key first. Refresh the inventory after completing that session.
6. Select a running VM and click **Open Console**, or double-click its name. Each console opens in its own tab and survives switching tabs.
7. Use **VM Actions** in the host inventory for power/media requests. Refresh to inspect the resulting state. A submitted API task may still be running; check the host task log if needed.

**Credentials…** reconnects with a temporary login. **Save credentials in Keychain** is off by default. Temporary credentials are retained only while this host's tabs are open, never included in exports or diagnostics. Saving into a shared profile changes that profile for every linked connection. A console password prompt is distinct from the management login and remains in memory only.

## Platform requirements

| Platform | Management access | Console path | Important requirements |
|---|---|---|---|
| Proxmox VE | HTTPS REST, usually 8006 | VNC over authenticated WSS; containers use the host web console | VM console and appropriate VM power/config permissions; accessible node; realm-qualified login |
| VMware ESXi / vCenter | HTTPS SOAP `/sdk`, usually 443 | Direct WebMKS ticket over WSS, bundled noVNC in a tab | API-compatible login, VM ConsoleInteract privilege, reachable ESXi ticket host/port; no VMRC or second web login |
| QEMU / libvirt | SSH, usually 22; host `virsh` | VNC/SPICE TCP or UNIX socket forwarded through SSH | Host key already trusted, SSH credentials/agent, permission to use the chosen libvirt URI, configured graphics device |
| Microsoft Hyper-V | Windows OpenSSH and Hyper-V PowerShell, usually 22 | Embedded FreeRDP VMConnect on 2179 | Host OpenSSH installed, account authorized for Hyper-V and VMConnect, management firewall rules |
| XCP-ng / XenServer | Xen Orchestra HTTPS/WSS JSON-RPC, usually 443 | Xen Orchestra's authenticated VNC proxy | Connect to **Xen Orchestra**, not the bare hypervisor; account must operate the VM and create a short-lived API token |
| Nutanix AHV | Prism Central HTTPS, usually 9440 | Console-token WSS API | v3 inventory and v4 action APIs; console-token feature requires v4.2+ capability plus accepted bearer authentication or session cookie |

### Proxmox VE

Use `user@pam` or `user@pve`. API token mode uses `user@realm!token` as the username and the token secret as its password. Some server versions/permission combinations restrict console-ticket creation to password-authenticated sessions. If inventory works but console creation is denied, use a least-privilege password-authenticated account and inspect the server's permissions.

The inventory includes QEMU VMs and LXC containers. QEMU desktops use bundled noVNC; LXC uses the host's console UI, which may ask for web sign-in. ISO attachment expects a storage volume such as `local:iso/installer.iso` and an existing CD/DVD device. The app does not create or replace a disk drive automatically.

### VMware ESXi / vCenter

Nethriva uses the vSphere Web Services API for inventory, power operations, and media requests. **Open Console** requests a one-time `webmks` ticket and connects directly to its ESXi WebSocket endpoint using bundled, open-source noVNC. It does not open vCenter's website, ask for another web login, install VMRC, or redistribute VMware's deprecated HTML Console SDK. The VM must be running and the account must have `VirtualMachine.Interact.ConsoleInteract`.

The Mac must resolve and reach the ESXi address and console port returned by the ticket, not only the vCenter management address. VPN/DNS/firewall restrictions can allow inventory but prevent the console. Reconnect obtains a fresh ticket after failure, expiry, or migration; tickets cannot be reused for a second socket.

When a ticket supplies a WebSocket URL, that URL is the console endpoint even if the separate host/port metadata uses another alias or route. The URL must still be secure WSS without embedded user credentials or a fragment, and its certificate is verified. Without a URL, Nethriva uses the ticket's host/port. Only an API-confirmed standalone ESXi server (`HostAgent`) may omit its already-known endpoint; Nethriva never substitutes vCenter's address for an unspecified ESXi target. Ticket-validation errors identify a fixed field label, never its value: report that label and host versions, not the raw SOAP response or ticket URL.

The ESXi certificate is verified against the identity returned by the authenticated API: SHA-256 is preferred, legacy SHA-1 tickets are supported, and newer PEM certificates are supported. If no supported identity is returned, normal system certificate validation is required. API cookies and HTTP credentials are never forwarded to ESXi; console redirects are refused. Trust the vCenter/API certificate carefully because it authorizes this ESXi identity; ignoring API certificate warnings weakens that trust chain.

Tickets may omit the optional hash-algorithm field; Nethriva recognizes strictly validated SHA-1/SHA-256 digest lengths in that case. Unknown algorithm labels are not guessed. Console errors distinguish a ticket/certificate mismatch, missing ticket identity with system-trust failure, TLS negotiation failure, and a connection failure after verification. Numeric TLS/network codes are safe to report; ticket URLs, credentials, and raw server errors are not. A certificate mismatch must be resolved on the host/vCenter, never bypassed by changing the management certificate policy.

VMware ticket sockets use Network.framework's native TLS/WebSocket transport with TLS 1.2 or newer. This allows the ticket's exact certificate identity to authorize private ESXi certificates without disabling App Transport Security across Nethriva. Host API traffic and other consoles retain their existing security policies. Missing ticket pins still require a valid, trusted certificate for the exact ESXi hostname. Redirects and extra HTTP credential requests are not followed; only the binary WebSocket protocol and validated API-origin header are supplied.

**ADFS/SSO:** Web SSO and API authentication are separate. If inventory loads with API credentials, the console can request a ticket without visiting ADFS. An experimental registered-native-client browser/MFA flow now supports S256 PKCE, vCenter 7.0.2+ token exchange and SAML bearer SOAP login; administrator configuration and system-trusted HTTPS are mandatory. See [advanced federation setup](ADVANCED_CONNECTIONS.md#vmware-federated-sign-in-24). Real provider acceptance remains pending; do not disable federation or MFA to accommodate this client.

If an earlier 0.13.0 development build reports an unexpected response immediately after login, rebuild with the latest source: VMware's session-scoped inventory-view references were incorrectly rejected. SOAP failures now distinguish rejected credentials, insufficient privileges, and expired API sessions; other response errors identify the failing operation without exposing host response text. Correct credentials alone do not guarantee VM inventory permissions. When reporting a remaining failure, include the operation/error and ESXi or vCenter version, not credentials or raw session tokens.

Use Nethriva's **Ctrl+Alt+Del**, **Fit Screen**, view-only, release-input, and fullscreen controls. Fit scales the existing framebuffer; changing guest resolution and clipboard support still depend on the server/guest. No VMRC-style device redirection or Finder file transfer is promised. **Mount Guest Tools…** asks ESXi/vCenter to mount its Tools installer; install it in the guest OS yourself. **Mount ISO…** expects `[datastore1] iso/installer.iso` and an existing CD/DVD drive.

Reference: [vSphere VM API](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.VirtualMachine.html), [WebMKS/RFB ticket protocol](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.VirtualMachine.TicketType.html), [ticket host and certificate fields](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.VirtualMachine.Ticket.html), [optional thumbprint algorithm field](https://developer.broadcom.com/xapis/vsphere-web-services-api/latest/vim.vm.CertThumbprint.html), [HTML Console SDK status](https://developer.broadcom.com/sdks/vmware-html-console-sdk/latest/).

Transport reference: [Apple's manual trust and ATS requirements](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication), [native WebSocket options](https://developer.apple.com/documentation/network/nwprotocolwebsocket/options).

### QEMU / libvirt

Choose `qemu:///system` or `qemu:///session`. Management commands run as the SSH account using the host's installed `virsh`; Nethriva does not install host software or silently use sudo. The VM's XML must expose a VNC or SPICE graphics port or UNIX socket. Nethriva obtains that endpoint and forwards it through an owned loopback SSH tunnel. Before opening the console, authenticate a **Host SSH** tab so that a key/agent or reusable master is available for the noninteractive tunnel.

For a QEMU instance without libvirt, save a direct **VNC Console** or **SPICE Console** connection instead. Discovery and power/media actions require a management layer; an arbitrary raw QEMU console cannot provide them by itself. TLS-only native SPICE ports, SASL-only authentication, and unusual graphics configurations need a compatible proxy or further integration.

There is no universal QEMU equivalent of VMware Tools. Install the QEMU guest agent, SPICE agent, or virtio drivers appropriate for the guest and host. Configure a **Guest-tools ISO / VDI** with an existing absolute host ISO path if you want a mount shortcut. Graceful lifecycle and display/clipboard functions depend on the relevant guest support.

### Hyper-V

Enable Windows OpenSSH Server on the host and allow the chosen account to use Hyper-V PowerShell. Commands are sent as encoded PowerShell, not a Linux shell script. VM consoles use the VM GUID with FreeRDP `/vmconnect` on port 2179, not the guest's usual RDP service on 3389. The Mac must be able to reach both management SSH and VMConnect. Host configuration, authentication, and VMConnect policy can restrict access even if inventory succeeds.

Modern Windows integration services normally come through Windows Update. Linux guests have their own kernel/tools support. Nethriva does not offer an automatic universal tools installation. A configured host-side ISO can be mounted into an existing DVD device; enter a Windows host path, not a Mac path. Verify Enhanced Session/VMConnect behavior on your actual host version.

**Restart Guest** uses guest shutdown followed by start, not the hard-reset `Restart-VM` command. **Force Reset** is explicitly disruptive. See Microsoft's [Stop-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm) and [Restart-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/restart-vm) references.

### Xen Orchestra / XCP-ng / XenServer

Configure the Xen Orchestra endpoint and account, rather than an XAPI endpoint on the hypervisor itself. JSON-RPC authenticates the inventory session and creates an in-memory token with a one-hour expiry for the VNC proxy. Closing attempts token revocation and closes the sockets; expiry is the safety limit if revocation cannot finish after a network loss.

ISO operations accept the ISO VDI UUID already known to Xen Orchestra. Guest-tools media is an ISO selected by the administrator; availability depends on the installation. The app does not upload an ISO or install guest packages.

Reference: [Xen Orchestra server source and APIs](https://github.com/vatesfr/xen-orchestra/tree/master/packages/xo-server/src).

### Nutanix AHV / Prism Central

Use Prism Central, not a guest IP. Inventory uses the v3 VM API; advanced operations use the v4 VM APIs. Different Prism releases can expose different portions of these APIs. Power-off is distinct from guest shutdown, and suspend/resume is not offered by this adapter.

Newer console-token support returns a one-time console ticket plus a WebSocket URI. The WebSocket also needs an accepted session cookie or bearer token; Basic credentials alone are not assumed sufficient. If using bearer authentication, enable **Use bearer token instead of password** and place the token in the password field. If inventory works but the host does not expose a console-token endpoint, update the host or use its own console until supported. This integration is experimental pending live host validation.

ISO attachment expects a Prism image UUID and an existing CD-ROM. The Guest Tools action asks the host to insert NGT media; installation still happens inside the guest.

Reference: [Nutanix console-token requirements](https://www.nutanix.dev/2026/05/01/vm-console-external-access/), [official VM SDK reference](https://developers.nutanix.com/api/v1/sdk/namespaces/main/vmm/versions/v4.0/languages/python/ntnx_vmm_py_client.api.vm_api.html).

## Direct VNC and SPICE connections

Select **VNC Console** (default 5900) or **SPICE Console** (default 5930). Enter the exact exposed console port; these protocols have no universal port assignment for every VM. Choose TCP or Secure WebSocket; the WebSocket field is a path such as `/websockify`, not a complete URL.

TCP is plaintext by itself. Use it only on a trusted isolated network or select a saved SSH connection for forwarding. With SSH forwarding, the target address is interpreted on the SSH host; use `127.0.0.1` for a console bound to that host's loopback interface. The SSH host must already be trusted and authenticated through keys, agent, or an open SSH master. Closing the console terminates its owned tunnel without closing unrelated SSH sessions.

TLS certificate controls apply to WSS, not raw TCP. Native VNC/SPICE TLS ports are not interchangeable with WSS proxies. No VNC/SPICE service is opened on the Mac's public network interface.

## Console controls and limits

- **Ctrl+Alt+Del** sends the remote key sequence in VNC/SPICE, VMware WebMKS, and RDP. It is disabled in view-only mode.
- **Fit Screen** is a visible VNC/SPICE/VMware toolbar button. It locally scales the whole display into the available tab, preserving proportions, and enables auto-fit after window/sidebar changes. It does not request a new guest resolution. Turn off **Fit to Screen Automatically** under **Display & Input** for actual-size viewing.
- **Resize Guest to Fit (When Supported)** is a separate, session-only, opt-in control under **Display & Input**. It requests guest display changes only when supported by the VNC server or SPICE guest agent and not in view-only mode. It is off by default; local scaling works without it. Host-provided web consoles use their own controls, and Hyper-V follows the embedded RDP sizing path.
- **View Only** prevents local mouse/keyboard input. **Release Keyboard** returns focus to Nethriva; click the console to return input to the guest. **Toggle Full Screen** affects the app window.
- **Share Text Clipboard** is opt-in. **Send Clipboard** offers Mac text to the remote clipboard; paste it inside the guest with the appropriate guest shortcut. Remote clipboard updates reach the Mac only while sharing is enabled. SPICE clipboard support needs a guest agent.
- Direct VM consoles do **not** implement RDP's Finder file/folder drops, USB redirection, printers, microphone, or guaranteed audio. Use an RDP/SSH/SFTP connection to the guest for those established workflows.
- ISO/media fields reference files or objects on the virtualization host. Dropping a local ISO into the console does not upload or attach it.
- Power requests operate on the host. Force-off/reset may lose guest data; graceful requests require guest cooperation. Test disruptive operations only on disposable VMs.
- Nested credentials, MFA interactive flows, federation to another web origin, migration races, and host API differences may need further work. Report redacted platform/version information and exact symptoms, not secrets or console ticket URLs.

## Security and troubleshooting

HTTP API sessions and embedded website storage are nonpersistent and scoped to the host. Passwords enter SSH helpers through private pipes rather than process arguments or secret environment variables. Shell values are quoted, option-like endpoints rejected, and XML entity expansion disabled. Authentication errors are reported without echoing response bodies or URLs that could contain tickets.

If inventory fails, check DNS/port, certificate policy, host account permissions, and supported APIs. If only the console fails, verify graphics configuration, console permissions, SSH master availability, gateway/proxy WebSocket support, and console-specific authentication. If media mounting fails, check the host path/object ID and existing CD/DVD device. Do not disable host verification or weaken permissions just to hide an error.

If a VNC/VMware console says **Connected** but is blank, rebuild older 0.13.0 development sources: the unused SPICE host previously occupied a full viewport above the noVNC canvas. The renderer host is now exclusive and tested for actual on-screen geometry, not only decoded pixels. With that fix, compare a remaining black screen against the host console and check guest screen blanking before assuming a transport or authentication problem.

Record live results in [COMPATIBILITY.md](COMPATIBILITY.md) with sanitized host version, guest OS, and successful/failed operations. Follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) before publishing a binary.
