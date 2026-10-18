# AI Session Remote

An iOS app for managing remote hosts and AI coding sessions.

## Requirements

- Xcode 16 or later
- XcodeGen (`brew install xcodegen`)
- An iOS 17 or later device or simulator

## Generate and open

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open AISessionRemote.xcodeproj
```

The project uses the local `AISessionCore` Swift package and targets iOS 17 or later.

## Host prerequisites

Each host must be reachable from the iPhone (the supported setup is a Tailscale-connected
Mac or Linux machine), with:

- Tailscale installed, signed in, and able to resolve or reach the hostname
- `sshd` enabled and accepting the configured user
- `tmux` installed (`brew install tmux` on macOS or `apt install tmux` on Debian/Ubuntu)
- The selected CLI on the SSH user's `PATH`: `claude`, `codex`, or `agent`

The app starts and attaches sessions through SSH; it does not install or configure these
host dependencies.

## Import an SSH key

In the host editor, choose an unencrypted OpenSSH private key from Files. The parser supports
**Ed25519** and **ECDSA P-256/P-384/P-521** keys in the `openssh-key-v1` format. Generate one
with `ssh-keygen -t ed25519 -N ""` or `ssh-keygen -t ecdsa -b 256 -N ""`, then install the
matching `.pub` key in the host user's `~/.ssh/authorized_keys`.

RSA and passphrase-protected private keys are unsupported by the current SwiftNIO SSH crypto
integration and are rejected. Keep the private key on the device protected by its keychain;
never commit it to this repository.

## Build from the command line

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme AISessionRemote \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

For a physical device, select your Apple Development team in the Xcode project signing
settings. A free Personal Team can install a development build on a device for local testing,
but it cannot create TestFlight builds and provisioning typically expires after seven days.
TestFlight distribution requires the paid Apple Developer Program, an App Store Connect app,
and an archive signed with a distribution profile.

## Sessions and metadata

Session names are slugs (`[a-z0-9-]+`) and are namespaced by tool as
`ai/<tool>/<slug>` (for example, `ai/claude/sigma-revenue`). The app creates and attaches
these sessions through `tmux`; it does not rename arbitrary pre-existing tmux sessions.
On the host, session metadata is stored under `~/.ai-remote/` so the app can associate
sessions with their tool, working directory, and display title. This directory is host data
and should be included in backups if that metadata matters.

## Adding hosts from the command line (Mac)

The Mac app can add SSH hosts without the host editor, then exit:

```sh
"/path/to/AI Session Remote.app/Contents/MacOS/AI Session Remote" \
  --add-host "codbexs-macbook-pro" tsetso@100.107.204.56 ~/.ssh/id_ed25519_aisession \
  --add-host "this Mac" me@100.103.53.126:22 ~/.ssh/id_ed25519_aisession
```

- Each key must be an unencrypted Ed25519 or ECDSA key. It is stored in the app's Keychain, the same as when you pick it in the editor. The Mac app is signed with a local certificate (`scripts/ensure-mac-signing-identity.sh`) so that prompt does not come back on every rebuild. After this signing change, click Always Allow once for keys already stored.
- If a host with the same user, hostname and port already exists, its key is replaced instead of adding a duplicate.
- Open the app normally afterwards.

## Todo conversations

Each todo in todo-server can have one Claude conversation on the computer assigned to its
section (Sp / I / Si / P). todo-server only stores the mapping; the app SSHes to the computer
and runs a helper there. Install the helpers on every computer that hosts conversations:

```sh
scripts/todo/install.sh --hub-url http://100.118.255.23:8080 --token "$TODO_API_TOKEN"
scripts/todo/install.sh --dry-run      # show what would change
scripts/todo/install.sh --uninstall    # remove scripts, hooks and the tmux line
```

The installer is safe to re-run. It sets up:

- `~/.ai-remote/bin/ai-todo-open <tmux_name> <cwd> <session_id> [claude|codex]`: the command
  the app runs. It attaches to the todo's tmux session if it is running. Otherwise:
  - Claude (the default) starts `claude --session-id <id>`, or `claude --resume <id>` once the
    conversation exists in `~/.claude/projects`, so a reboot or a closed conversation picks up
    where it left off.
  - Codex runs `codex resume <id>` for a linked, existing Codex conversation. It exits 94 if
    there is none, because Codex can't start a new conversation with a chosen id.
- `~/.ai-remote/bin/ai-todo-sessions`: lists, deletes and prunes this computer's Claude Code and
  Codex conversations, so the app can link existing ones to todos.
  - `list --json [--tool claude|codex] [--limit N]` prints the newest first, with title, folder,
    prompt count, and whether it is running (and in which tmux session). Empty Claude
    transcripts and Codex sub-agent threads are skipped.
  - `delete <claude|codex> <id> [--permanent]` removes a Claude conversation's files, or archives
    a Codex one (`codex delete` with `--permanent`). It refuses while the conversation is running.
  - `prune --older-than DAYS [--tool T] [--yes]` targets conversations unused for DAYS that aren't
    running or linked to a todo. It asks todo-server which ones are linked, and refuses if it
    can't reach it. Without `--yes` it only lists what it would delete.
- `~/.ai-remote/bin/ai-todo-limits --tool claude|codex|cursor [--session ID]`: the limits for that
  tool's login on this computer. The chat shows a 5-hour, weekly, or monthly figure only when
  that login has one. Tokens stay on the computer; the script prints percents and reset times.
- `~/.ai-remote/bin/ai-todo-hook`: Claude Code hooks merged into `~/.claude/settings.json`.
  `UserPromptSubmit` posts `busy`, `Notification` posts `waiting`, and `Stop` posts `idle` to
  `POST /api/conversations/status`. Only sessions named `ai/claude/todo-*` report.
  - Claude's "waiting for your input" notification after it has finished counts as `idle`, not `waiting`.
  - `PostToolUse` puts the status back to `busy` after you answer a permission prompt. It posts only when the last status sent wasn't already `busy`, which it checks in `~/.ai-remote/hook-state/`.
  - Existing settings and hooks are kept, and the file is backed up before each change.
  - The hook runs in the background with a 3 s limit and always exits 0, so a slow or
    unreachable hub never blocks Claude.
- `~/.ai-remote/bin/ai-todo-codex-notify`: Codex's `notify` program, set in `~/.codex/config.toml`.
  - When a turn completes, it posts `idle` (with `"tool":"codex"`) for conversations in tmux sessions named `ai/codex/todo-*`.
  - Codex allows only one `notify`. If one is already configured, `install.sh` leaves it alone and explains how to proceed.
  - `install.sh --chain-codex-notify` wraps an existing `notify` so both run. `--uninstall` puts the original back.

To build a Release Mac app, run `scripts/build-mac-release.sh`, which prints the `.app` path.
- `~/.ai-remote/todo-hub.conf` (mode 600): `TODO_HUB_URL` and `TODO_API_TOKEN` for the hook.
- `~/.ai-remote/tmux.conf`, sourced from `~/.tmux.conf`. Run `tmux source-file ~/.tmux.conf`
  to apply it to a running server. It sets:
  - no Esc delay;
  - `window-size latest`, so the iPhone and Mac can share a session;
  - extended keys, so Shift+Enter reaches Claude;
  - OSC 52 clipboard, mouse, focus events, true color and 50k lines of scrollback.

`scripts/todo/test-todo-scripts.sh` runs everything offline in a sandbox with a temp `HOME`,
fake `claude` and `codex` binaries, a fake hub and a private tmux socket.

## Non-goals

This project does not provide push notifications, a background daemon or always-on service,
or App Store distribution. It is a foreground iOS client for manually managed SSH hosts.

## SSH (`NIOSSHClient`)

`App/AISessionRemote/Services/NIOSSHClient.swift` implements `SSHExecuting` on top of
[`apple/swift-nio-ssh`](https://github.com/apple/swift-nio-ssh).

- **Private keys**: `swift-nio-ssh` has no OpenSSH/PEM parser of its own (CryptoKit can't decrypt
  passphrase-protected keys, so upstream only exposes raw-key initializers — see
  [apple/swift-nio-ssh#94](https://github.com/apple/swift-nio-ssh/issues/94)).
  `OpenSSHPrivateKeyParser.swift` parses the `openssh-key-v1` binary format (the default output
  of `ssh-keygen` since OpenSSH 7.8) to fill that gap. Only **unencrypted Ed25519 and ECDSA
  (P256/P384/P521)** keys are supported; RSA and passphrase-protected keys are rejected with a
  clear error. Generate a compatible key with `ssh-keygen -t ed25519 -N ""`.
- **Host key trust (TOFU)**: `TOFUHostKeyStore` accepts a host's key on first connection and
  pins its SHA-256 fingerprint in `UserDefaults`, keyed by `host:port`; later connections must
  match exactly or the connection fails. This is a v1 stopgap, not a hardened implementation:
  the fingerprint map lives in `UserDefaults` (not Keychain), so it could be wiped/restored
  along with app data, and there's no UI yet to inspect or reset a stored fingerprint. A
  follow-up should move it to the Keychain and add a "forget this host" action.
- **Error mapping**: `SSHRemoteError` has no generic protocol/handshake case. Failures before
  the TCP connection is established (DNS, refused, timeout) map to `.unreachable`; anything
  that fails after TCP connects (handshake, host key rejection, user auth, channel setup) maps
  to `.authenticationFailed`. A non-zero remote exit code is not an error — `exec` always
  returns a normal `SSHExecResult`, and callers like `SessionService` decide if that's a
  failure.
- **Bounded execution / no hangs**: `NIOSSHHandler` is paired with `SSHConnectionErrorHandler`
  (closes the channel on `errorCaught`), matching `apple/swift-nio-ssh`'s own client example.
  Without it, a rejected TOFU host key or failed auth can otherwise leave the connection open
  with nothing to close it, hanging `exec()` forever. Two additional NIO-scheduled deadlines
  back this up: `handshakeDeadlineSeconds` (default 15s, bounds SSH handshake through
  session-channel-open) and `execTimeoutSeconds` (default 30s, bounds the remote command). Both
  only ever force-close a channel, never complete a promise directly, so they can't race a
  "real" completion into a double-fulfillment crash. `ReachabilityProbe` constructs its own
  `NIOSSHClient` with much tighter deadlines (5s/8s/5s) since a reachability check should fail
  fast, and `HostsListView.refreshReachability()` probes all hosts concurrently so one
  unreachable host can't stall the rest.
- **Not yet exercised against a live host**: this was built and proved via `xcodebuild` compile
  only; no manual Tailscale-host `exec`/reachability test was run in this environment. The
  `ExecOutputHandler`/`ReachabilityProbe` flow follows the exec pattern from
  `apple/swift-nio-ssh`'s own `NIOSSHClient` example (session channel → `ExecRequest` →
  capture stdout/stderr/exit status), but should be validated against a real host before
  shipping.
- **Tests**: `App/AISessionRemoteTests` (an `AISessionRemoteTests` unit-test target hosted by
  the app) covers `TOFUHostKeyStore.evaluate` and `OpenSSHPrivateKeyParser` happy/error paths.
  `xcodebuild ... build-for-testing` succeeds, but this environment can't run them
  (`CoreSimulatorService` is unavailable), so they haven't been executed — only compiled.
