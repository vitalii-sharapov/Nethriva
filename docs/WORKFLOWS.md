# Workspace and SSH workflow tools

These features are included in the [0.13.0/build 30 preview](releases/0.13.0.md). Saved personal clients and Keychain passwords are not included in builds.

## Split panes and detached sessions

Right-click a session tab and choose **Show beside current session**, **Stack below current session**, or **Detach to Window**. Drag the wide handle between panes to give either adjacent session more room. Double-click a handle, or choose **Equal Pane Sizes**, to balance the group. Resizing keeps the existing sessions connected and preserves their terminal history.

An SSH split can contain **two, three or four SSH terminal sessions**. Open another SSH session, right-click its tab and choose **Add to SSH Split**. It joins the saved split in the existing side-by-side or stacked arrangement; each divider adjusts only its two neighboring panes. A newly opened RDP, SFTP, local terminal, or other session opens in a single pane. New SSH tabs also open alone until explicitly added. Selecting any tab already in the split returns to the whole group with its sizes preserved. Other session types can still be paired explicitly using **Show beside current session**.

**Remove from Split** shows that session alone while keeping the remaining group when at least two panes remain. **Single Pane** on a split member dissolves its group without closing sessions. **Return to Workspace** docks a detached window as a single session. Closing a detached window docks it; the tab's close button actually ends its session. Detaching or closing one member preserves the other panes. Clicking a pane makes it the keyboard target. SSH's file tree is hidden in split panes to give terminals room; use a dedicated SFTP tab for side-by-side file browsing. Split membership, sizes and detached windows are session-only, not restored automatically after quitting.

## SSH tunnels

Choose **File → SSH Tunnels**. Save a configuration with an SSH connection, direction, and ports, authenticate that host in an SSH tab, then click **Start**. Supported directions:

- Local: a loopback port on this Mac forwards to a service reachable from the SSH host.
- Remote: a loopback port on the SSH host forwards to a service reachable from this Mac.
- SOCKS: a loopback SOCKS proxy on this Mac uses the SSH host for outbound connections.

Listen ports must be 1024–65535. The server must permit forwarding; remote exposure also depends on its `GatewayPorts` policy. The manager does not probe the destination or promise it is healthy just because a forward was accepted. **Stop** removes the selected managed forward. Active tunnels hold a lease on the authenticated master even when its terminal tab closes; quitting closes app-owned masters. No automatic tunnel start or retry occurs after launch/network loss. If an acknowledgement is interrupted, the state is shown as uncertain and requires an explicit Stop decision before restarting. A lost/stale socket or server interruption may require reconnecting SSH first.

App-owned SSH masters deliberately clear forwarding rules inherited from `~/.ssh/config`; configure forwards in this manager instead. Config keys, aliases, authentication, host trust, and jump settings still apply. Control requests use the resolved private socket and `-F none`, so unrelated config forwarding rules are not imported or cancelled. Optional SSH-forwarded VM consoles use the same isolated explicit control path (including Unix-socket consoles); authenticate their selected SSH host first. Stopping a console removes its particular forward without exiting other users of that master. No passwords enter arguments or configuration files. Tunnel definitions stay in the active data profile and reference a saved connection ID; they are not included in connection-library exports yet.

SSH/SFTP reuse and tunnels share a short private control-socket namespace. Socket naming reserves OpenSSH's temporary creation suffix within macOS's path limit, while retaining separate authentication/key/forwarding contexts. After updating from a build that reports `unix_listener: path ... too long`, relaunch the rebuilt app and reopen the failed SSH tab. No server setting, saved-password reset, or manual socket-directory deletion is needed.

## Ordered jump hosts

In an SSH connection editor, choose **Configure Jump Chain** beside the Jump Host field. Add saved SSH host addresses or enter `user@bastion.example.invalid:2222`/SSH-config aliases, then reorder up to eight hops. The first entry is reached first. IPv6 addresses require brackets. Saving keeps the existing comma-separated OpenSSH `ProxyJump` representation, also used by SFTP.

Selecting a saved host copies its address, username and port—not its Keychain password or per-connection key settings. Configure per-hop keys/authentication in `~/.ssh/config` or use your agent; terminal authentication remains interactive. Agent forwarding is not implicitly enabled. Do not paste passwords into hop fields.

## Quick Connect

Press **Command-K** or choose **File → Quick Connect**. Search saved connections by name, host/IP, port or group, cached virtual machines by VM/node/host name, and tools such as SSH Tunnels, Command Snippets and Help. Select with arrow keys and Return, double-click, or click Open. VM results come only from inventories already loaded in this run; the palette does not scan hosts, log in automatically, or trigger power actions. Endpoint display follows privacy settings; user-chosen connection/VM names remain visible.

## Edit a remote text file

Right-click a regular file in the SSH tree or SFTP browser and choose **Edit Remote File**. A movable editor loads UTF-8 text up to 2 MiB. Links, special files, NUL-containing/binary data, and larger files are refused. Edit and click **Save** (Command-S). Before publishing, Nethriva re-reads and hashes the current remote content; if it changed—even to different content of the same length—saving stops. Reload (with confirmation to discard local edits), or explicitly confirm **Overwrite Changed File**.

Save stages a unique file and atomically replaces the destination only when the SFTP server supports POSIX rename. It preserves ordinary permission bits but not ownership, ACLs, extended attributes, timestamps or setuid/setgid flags. Unsupported safe replacement fails without deleting the original. Reading/checking/publishing is not a distributed lock: another writer can change the file during the final check-to-rename interval. Use a version-controlled workflow for coordinated editing of important configuration files.

Edited contents are held in memory. A private temporary directory is used only during Save and removed afterward; cancellation/process failure can leave a remote `.partial` file. There is no autosave or automatic retry. **Cancel Operation** preserves local edits and stops a pending read/save; cancellation cannot undo a publish already accepted by the server, so verify the remote file before retrying. Window close and application quit ask before discarding unsaved edits; while a read/save is pending, finish or cancel it first. Closing an SSH tab does not close its separate editor. Explicit editor operations use the selected connection's runtime Keychain credentials; no file contents/passwords enter diagnostic exports or connection archives.

## Command snippets

Choose **File → Command Snippets** to create named/grouped snippets. Use unquoted `{{parameter}}` placeholders; parameter values are shell-quoted by default. Templates and values are literal data: substitution is one pass and never evaluates a shell command itself. Preview the expanded text and select an open Local Terminal, SSH, Telnet or Serial tab.

**Insert** sends a single line without Return. Multiline insertion is refused because embedded newlines can execute commands immediately. **Run** sends the text followed by Return, with confirmation enabled by default (and always required for multiline/control-character content). Disabling shell quoting is useful for device CLI syntax, but makes parameters executable syntax: review the preview carefully. A closed or detected credential-waiting terminal refuses insertion. This is terminal text injection, not a reliable shell-state detector or a transaction: commands can affect the selected host immediately.

Snippets and tunnel configurations persist only in the active local data profile; they are not part of connection-library import/export. Do not store passwords, tokens or private keys in snippets: templates are not an encrypted secret vault. Damaged workflow archives are retained and saving is disabled rather than silently replacing them; a previous local copy is retained on successful updates. Snippet execution is never replayed on reconnect.

## Local acceptance checks

Roadmap 15–20 adds separate confirmed multi-session commands, terminal profiles/search, opt-in recording, templates/group inheritance, bulk editing and migration imports. See [LIBRARY_TOOLS.md](LIBRARY_TOOLS.md) for the complete workflow and safety/acceptance guide.

Use disposable accounts and synthetic files:

1. Move a live local/SSH/RDP/VM session into a split, detach it, resize, dock it, and close it. Verify one connection, stable terminal history, correct focus and remote sizing.
2. Start/stop local, remote and SOCKS forwards; check duplicate/busy ports, server refusal, close-last-terminal leases, app quit and network loss. Confirm configured SSH forwards are not started implicitly.
3. Test two-hop key/agent authentication and SFTP; invalid hop ports/format should be rejected.
4. Use Command-K with connection, IP, group, cached VM and action searches; keyboard selection should open the intended result.
5. Edit a small UTF-8 file; modify it separately, verify conflict refusal and explicit overwrite. Check unreadable/oversized/binary/link files and unsupported safe-rename servers.
6. Preview/insert/run parameterized snippets in a disposable shell/device CLI. Verify quoting, missing parameters, multiline confirmation, closed targets and credential prompts.

Automated tests use isolated data profiles and a local system SFTP server, never personal clients. Live server/device acceptance remains separate.
