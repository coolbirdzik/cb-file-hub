# SSH workspace, SFTP and FTPS

The sidebar's **SSH workspace** opens `#ssh`. Network Home also links to it.
`#sftp` uses the same saved SSH hosts, with shortcuts to browse files or open a
terminal in another application tab. Host profiles support names, groups,
host/port, username, password or a managed SSH key.

Hosts and desktop network List mode use the file browser's `AdaptiveFileList`
column layout and shared compact row geometry. A desktop host click selects;
double-click or Enter opens SSH (or browses files in SFTP). The host menu keeps
terminal, file browsing, edit and delete actions available; its address is shown
in a tooltip. Discovered config aliases remain in the connection form only.

SSH/SFTP host collections offer only Grid and List, with a visible toggle beside
search and Grid as the fallback. `GridListCollection<T>`, `GridListViewToggle`
and `GridListViewController` are common components built on the existing browser
collection. The scoped SQLite preference `collection_view_ssh_hosts` persists
the choice without changing file-browser preferences. Both views keep the same
selection and host actions. A fixed management toolbar prevents selection from
moving the double-click target; Grid also shows address and authentication.

## SSH and SFTP

`dartssh2` supplies SSH and SFTP; the vendored `xterm` 4.0.0+cb.1 renders
interactive PTY sessions. The patch in `third_party/xterm/PATCHES.md` binds
text input to `View.of(context).viewId` for Flutter 3.47.2. Upstream 4.0.0
omits it, causing Windows to reject keyboard attachment with "view ID is null"
and then "no client is set". Restart the running app after switching to the
patched dependency. The patch preserves IME input and is not a keyboard-only
fallback.
Terminal tabs resize the remote PTY, retain their session while switching desktop
tabs, and close the transport when their tab is closed or navigates elsewhere.
Reconnect, disconnect, clear, Home and SSH workspace controls remain available.

`SshProfileStore` keeps profiles, passwords, private keys and trusted fingerprints
in `FlutterSecureStorage`. SSH secrets are not stored in `network_credentials`.
Keys can be generated as Ed25519 or imported as OpenSSH/PEM, including encrypted
keys. Import unlocks the key with its passphrase and stores it in the OS vault;
the passphrase is not retained. Public keys can be copied for installation on a
server. Referenced keys cannot be deleted until their hosts are updated.

### Local SSH discovery and connection forms

SSH/SFTP connection dialogs and the SSH workspace scan the current user's
`~/.ssh` automatically (`%USERPROFILE%\.ssh` on Windows). The Hosts list shows
only saved profiles. Discovered hosts are available in the connection dialog's
SSH config selector; selecting one fills HostName, User, Port and an
available IdentityFile. A sole host, or an explicitly supplied matching host,
is filled automatically in a new untouched form. Asynchronous discovery does
not overwrite manual edits or existing saved profiles.

The config reader supports quoted paths, explicit aliases, Host wildcard and
negation defaults, first-value precedence, additive IdentityFile entries,
bounded/cycle-checked Include globs and common identity path tokens. It never
executes config commands. Conditional Match settings are skipped with a notice;
hosts requiring ProxyJump, ProxyCommand or SSH certificates display a notice
because the current connector does not implement those options.

Private-key candidates are recognized by their OpenSSH/PEM headers, including
custom filenames and IdentityFile paths outside `.ssh`. Public keys, known_hosts
and PuTTY `.ppk` files are not imported as private keys. Discovery reads only
headers; choosing a key opens the import dialog with its file preselected.
Encrypted keys ask for a passphrase. Re-importing an existing fingerprint reuses
its vault identity. The original files and SSH config are never modified.

Connection forms use the shared desktop dialog with responsive field rows and
scrolling content. Import private key and Generate Ed25519 key are directly
available beside authentication, and importing/generating selects the resulting
key immediately. The workspace Keys section also lists local files and provides
Copy public key for installing generated keys on servers.

Unknown and changed server fingerprints require an explicit trust decision.
Background connections without an interactive trust callback reject untrusted
keys. Trust is scoped to hostname and port and can be removed from the workspace.

SFTP connections have separate transports per account/host/port. Virtual paths
encode the connection authority and preserve remote file names literally. The
provider supports listing, streaming, download/upload, mkdir, rename and delete.
Directory deletion is non-recursive, so non-empty directories produce a server
error rather than silently deleting their contents.

## FTPS desktop

The existing FTP connection form offers plain FTP, Explicit TLS (default port
21), and Implicit TLS (default port 990). The saved `ftpSecurity` option is
restored when reconnecting. All continue through the shared FTP browser.

FTPS uses desktop `curl` (the Windows system executable, or `curl` on PATH on
macOS/Linux). This supplies TLS shutdown and session handling which Dart's
`SecureSocket` does not provide adequately for strict FTPS upload servers.
Mobile FTPS is not supported by this backend. Plain FTP retains the Dart client.

Both control and data channels require TLS. Certificate verification remains
enabled; there is no plaintext fallback or accept-all certificate option.
Passwords are passed in a curl configuration through stdin, never in command
arguments or a temporary configuration file. Curl's user configuration and
environment proxies are disabled for these direct server connections.
Processes are scoped to operations and terminated on disconnect. Download
progress is incremental; upload progress reports completion.

## Verification

From `cb_file_manager/`:

```powershell
flutter analyze --no-pub
flutter test --no-pub
python -m pip install asyncssh pyftpdlib pyopenssl
flutter test --no-pub --dart-define=CB_SECURE_NETWORK_TEST=true test/services/ssh
```

Loopback tests start temporary SSH and FTP servers, require verified TLS on FTPS,
exercise transfers and file operations, password/key auth, PTY output, changed
host rejection, and independent connections on different ports. They run only
with the explicit define, so ordinary unit tests need no Python packages.

The widget tests cover English/Vietnamese and narrow/wide layouts. Optional
`CB_SSH_CAPTURE=true` captures the SSH workspace fixture into
`build/network-layout-review/ssh-workspace.png` and the connection dialog fixture
into `build/network-layout-review/ssh-connection-dialog.png`.

Restart the application after updating dependencies and the network registry.
