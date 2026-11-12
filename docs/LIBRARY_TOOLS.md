# Terminal and connection-library tools

Roadmap items 15–20 are included in the [0.13.0/build 30 preview](releases/0.13.0.md). Building the app does not publish a new release or bundle your saved clients. Existing clients keep their settings unless you deliberately edit them or enable inheritance.

## 15 — Safe multi-session commands

Open **File → Multi-Session Command**. Select individual open Local, SSH, Telnet or Serial tabs; none are preselected. Enter one line, inspect each target's actual terminal prompt, and acknowledge that these are the intended recipients. **Review Execution** shows the exact command and numbered recipient list; **Execute Once** sends it with Return.

The router rejects control characters, commands over 32 KiB, closed/restarted recipients, and detected authentication/disconnected states. All recipients are checked before sending. This is not live keystroke broadcasting, automatic shell-state detection, or an atomic transaction across hosts. An editor, privileged shell, device mode or unusual login prompt may still accept text differently: inspect every target. Delivery counts mean local input-channel acceptance, not successful command execution. Partial delivery is reported and never retried automatically. Avoid credentials in commands and always use disposable targets for initial testing.

## 16 — Terminal profiles and output search

Use **File → Terminal Profiles & Templates → Terminal Profiles** for named fonts/sizes, Midnight/Light/Green themes, block/underline/bar cursors and 100–10,000 scrollback lines. Save a profile, optionally make it the app default, or choose it in a connection editor. Profiles apply when a native terminal is created or restarted; they do not reconnect existing sessions. Remote applications can change colors/cursors.

**Find Output** above any terminal opens a searchable, read-only in-memory scrollback snapshot. Refresh to include new output; matches include line numbers and selectable text. The snapshot is bounded to 2 MiB, results to 500 lines. Full-screen programs can overwrite buffer contents, and wrapped lines remain separate. It is output search, not a persistent shell-command-history database. Search contents are never saved automatically.

## 17 — Explicit output recording

Recording is off by default, is not inherited, and never resumes automatically. **Record Output** asks for confirmation and records future output only; **Stop Recording** ends it. A visible red **Recording output** indicator remains while active. Disconnect, terminal restart, tab close and app quit end recording.

Only received terminal output is captured—not keyboard/paste input directly—but shells or devices may echo input. Detected credential prompts stop recording, requiring explicit restart after authentication. Plain-text line filtering removes terminal control sequences and omits lines containing sensitive credential labels; oversized lines are omitted. **This is a precaution, not a secrecy guarantee.** Unknown prompts and arbitrary secrets printed without recognizable labels can still be recorded. Avoid authentication and commands that print credentials while recording, and review logs before sharing. RDP/VM video, file contents and command snippets are not recorded by this feature.

Files have random names without endpoints in a private `SessionLogs` folder under the active profile's Application Support directory (separate Debug, Release and hosted-test paths). Directory/file permissions are 0700/0600. Writing runs off the UI thread with bounded buffering; each log stops at 8 MiB or on disk/backpressure failure. Incomplete final lines are intentionally not written. Timestamps mark receipt of completed output lines, not exact remote execution time. Retention defaults to seven days, configurable from 1–90 days. Expired owned logs are removed when recording starts or through **Settings → Remove Expired Logs**; active recordings, symlinks and unrelated files are not removed. This cleanup is permanent, not Trash recovery. Settings also opens the private folder. Logs are excluded from connection archives and redacted diagnostics; they are not encrypted at rest by Nethriva.

## 18 — Templates and inherited group defaults

The same tools window manages named protocol templates and per-group defaults: credential-profile references, protocol ports, SSH jump chains/keepalive, RDP gateway/interface scale, and terminal-profile references. It stores no passwords or executable startup commands.

**Apply Template** in a connection editor confirms copying applicable values into the unsaved draft. Host, name, group and passwords remain unchanged; Save is still required. Templates are one-time copies, not links that silently update clients.

For inheritance, right-click a group and choose **Group Defaults**, set the desired values, then enable specific **Inherit Selected Fields from Group** checkboxes in each connection editor. Existing clients do not opt in automatically. Defaults resolve from the top-level group toward the nearest subgroup; unchecked fields are individual overrides. Missing defaults fall back to the client's own values. Clearing a previously entered jump/gateway creates an explicit empty override. Ports are protocol-specific. Open a new tab to use changed defaults; existing tabs and their Reconnect controls keep their connection snapshots.

Renaming/moving a folder remaps its defaults with the subtree. Removing a group materializes inherited settings into its clients before moving them to Ungrouped, retaining access to the same credential-profile reference. Templates/defaults count as credential-profile uses, so unlink them before deleting a referenced profile.

Templates and group rules remain local to the active profile. Normal connection exports materialize effective values and embed terminal appearance, preserving usable exported clients without requiring those local rules on another Mac. They do not export the template catalog, live inheritance rules, snippet/tunnel definitions or logs. Existing v1 archives remain readable. Archives cannot activate local inheritance rules or refer to local terminal-profile UUIDs; this prevents an imported client from silently acquiring the destination Mac’s group credentials.

## 19 — Bulk metadata editing

Command/Shift-select clients in the sidebar, then right-click one and choose **Bulk Edit Selected**. The File-menu tool can also select clients explicitly. Check only the fields to change, enter values, and review the before/after list before **Apply Metadata Changes**. Applicable protocols change; others stay unchanged. Blank ports/profile selections are skipped; blank jump/gateway values explicitly clear them. Updated fields stop inheriting. Individual passwords are not read, overwritten or deleted; a shared profile selection stores its reference only.

Clients are written together as one metadata update. A missing/deleted selection or failed save aborts the edit. Local Terminal cannot be edited this way. The selected identifiers are captured for confirmation; active tabs keep their original snapshots. Close/reopen a session to use updated transport settings.

## 20 — Migration imports

Use **File → Import Other Formats**, select a format and file, inspect the parsed clients/warnings, then confirm the selected additions. Parsing happens off the UI thread. Existing clients/passwords are never overwritten; same-name or same-endpoint clients are unchecked by default and can be explicitly selected to create separate records. Empty XML folders are retained. Imports never contact hosts or execute source configuration. UTF-8 and BOM-marked UTF-16 text up to 4 MiB and at most 10,000 records are supported. Imported passwords/encrypted credential blobs are always ignored; use the existing encrypted Nethriva archive flow for intentional credential migration.

Supported subsets:

- **OpenSSH config:** explicit `Host` aliases; `HostName`, `User`, `Port`, first `IdentityFile`, `ProxyJump`, `ForwardAgent`, `Compression`, `ServerAliveInterval`. Quoting/comments and `key=value` are supported. Earlier global values take precedence. Wildcards, negated hosts, `Include`, `Match`, executable commands, forwards and hostname expansion tokens are not evaluated/imported. Copy keys/config separately if needed; existing Mac SSH config still applies during a session. This is not a complete OpenSSH configuration evaluator. [Configuration reference](https://man.openbsd.org/ssh_config).
- **RDP files:** `full address`, `server port`, `username`, `domain`, `gatewayhostname`, clipboard, supported interface scales, administrative-session and reconnect booleans. Password blobs, authentication exceptions, device redirects, automatic programs and unsupported properties are ignored. Certificate checking defaults strict; clipboard defaults off unless explicitly imported. [Property reference](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties).
- **CSV:** unique `protocol,host` headers required; optional `name,port,username,group,domain,gateway,favorite`. Protocols: `ssh,telnet,rdp,vnc`; quoted commas/doubled quotes are supported. Unknown columns, including passwords, are ignored. Control characters in connection fields are rejected. Example below.
- **Connection-tree XML:** unencrypted `Connections` or `ConnectionTree` root, optional XML namespace, nested `Node Type="Container" Name="…"` (or `Group`) and `Node Type="Connection"` (or `Connection`) records. Attribute allowlist: `Name`, `Protocol` (`SSH2`, `SSH`, `Telnet`, `RDP`, `VNC`), `Hostname`/`Host`, `Port`, `Username`, `Domain`. Only this documented export subset is supported, not every third-party file/version. Passwords and inheritance flags are ignored; fully encrypted files, DTDs/entities and excessive nesting are rejected. [Export-format reference](https://mremoteng.readthedocs.io/en/latest/user_interface/import_export.html).

```csv
name,protocol,host,port,username,group,favorite
Example Device,ssh,device.example.invalid,22,admin,Example/Devices,false
Example Desktop,rdp,desktop.example.invalid,3389,,Example/Desktops,false
```

## Acceptance checks

1. Execute a harmless command on two disposable terminals; confirm the third receives nothing. Close/restart a recipient during review, test authentication prompts and partial rejection, and verify no resend.
2. Create profiles, open Local/SSH/Telnet/Serial terminals, verify font/cursor/theme and search after scrollback wraps/trims. Detach/dock while recording; verify the same tab remains the only recording target.
3. Record synthetic output, inspect timestamps, private permissions, label filtering and 8 MiB/backpressure stop. Stop/restart/disconnect and confirm recording stays off. Use synthetic expired logs to test retention, never a personal transcript.
4. Test parent/subgroup defaults, opt-in/individual overrides, protocol-specific ports, move/rename/remove, failure rollback, shared credentials and appearance export/import on an empty profile.
5. Bulk-edit mixed SSH/RDP/Telnet clients; confirm preview, unchanged unchecked fields, no Keychain prompts, no active-tab changes and failed-save rollback.
6. Import synthetic SSH/RDP/CSV/XML files, empty folders, duplicates, malformed ports/quoting/controls/entities, unsupported fields and ignored password placeholders. Confirm nothing saves before approval and no remote connection is attempted.

Automated tests use synthetic identities, isolated preferences and temporary local files only. Real server/device and exported-file interoperability still need manual acceptance.
