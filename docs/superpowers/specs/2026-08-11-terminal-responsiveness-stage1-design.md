# Terminal Responsiveness, Stage 1: SSH Connection Reuse — Design Spec

**Date:** 2026-08-11
**Status:** Approved for implementation planning
**Scope:** Stage 1 of 2. Stage 2 (Mosh transport) is a separate spec.

## Problem

Every user-visible action in the app is slow in proportion to network latency, and slower
than the latency alone would explain. On a ~150 ms RTT link (typical cellular + Tailscale),
refreshing the session list takes ~2 s and creating a session takes ~5 s.

The cause is not bandwidth and not SSH channel flow control. It is that
`NIOSSHClient.exec` opens a **complete, fresh SSH connection for every single command** —
TCP handshake, key exchange, user authentication, channel open, exec — and tears it down
afterwards. That is roughly 7 round trips of setup to run one `tmux ls`.

| SSH setup step | round trips |
| --- | --- |
| TCP handshake | 1 |
| version string + `KEXINIT` exchange | 1 |
| ECDH key exchange + `NEWKEYS` | 1 |
| service request → accept | 1 |
| publickey auth → success | 1 |
| channel open → confirmation | 1 |
| exec (`wantReply: true`) → output | 1 |
| **total** | **~7** |

The cost is then multiplied again because service methods chain execs sequentially:

| operation | execs today | RTTs @ ~7 each | wall clock @ 150 ms |
| --- | --- | --- | --- |
| `listSessions` | 2 | ~14 | ~2.1 s |
| `createSession` (per attempt) | 5 | ~35 | ~5.2 s |
| `promoteSession` | 2 | ~14 | ~2.1 s |
| `killSession` | 1 | ~7 | ~1.0 s |
| terminal attach | 1 connection | ~7 | ~1.0 s |

`createSession`'s five execs are `listSessions` (2) + `which` + `writeMetadata` +
`newDetachedSession`.

Two smaller effects make the terminal itself feel worse than raw latency:

- **Redundant full-screen tmux repaints.** `TerminalScreen.swift:73-76` sends a
  `window-change` immediately after the PTY was already requested with the same dimensions,
  and `sizeChanged` fires repeatedly across layout passes on keyboard show/hide and rotation.
  Each one makes tmux repaint the entire screen.
- **Per-frame main-thread hops.** Each inbound SSH data frame gets its own
  `DispatchQueue.main.async` + `feed` + redraw (`TerminalScreen.swift:59-61`). At high
  latency, output arrives as fewer, larger bursts, each split across many SSH frames, so one
  logical repaint becomes dozens of dispatches and dozens of SwiftTerm redraws.

### Ruled out by inspection

These were investigated and are **not** contributors; do not spend time on them:

- **Nagle's algorithm.** `TCP_NODELAY` is already set on both the exec and terminal paths.
- **SSH channel flow control.** swift-nio-ssh advertises a 8 MB receive window
  (`Constants.defaultMaximumChannelPacketSize` 128 KB × `channelWindowSizePacketMultiple` 64),
  so the window is not throttling throughput at any realistic RTT.

### Explicitly out of scope for Stage 1

Keystroke echo latency (one full RTT per character, because there is no local echo) and
output freezes from TCP head-of-line blocking are **not fixable within SSH**. They are the
subject of the Stage 2 Mosh spec. Stage 1 must not attempt a partial fix for them.

## Goals

- One authenticated SSH connection per host, reused by both remote commands and the terminal.
- Fewer remote commands per user action.
- No redundant tmux repaints on attach or resize.
- Identical observable behaviour: same errors, same error messages, same retry semantics.
- A transport seam that Stage 2 implements against without touching UI code.

## Non-goals

- Any change to keystroke echo latency.
- Mosh detection, per-host transport preference, or transport UI.
- Changes to the tmux session model, naming conventions, or `~/.ai-remote/` layout.
- Making `AISessionCore` depend on SwiftNIO. It stays NIO-free; all NIO code remains app-layer.

## Architecture

```text
        App layer (SwiftNIO)                         AISessionCore (NIO-free)

  ┌──────────────────────────────┐            ┌─────────────────────────────┐
  │ SSHConnectionPool  (actor)   │            │ SessionService              │
  │  host → one live connection  │◄───────────│  uses SSHExecuting          │
  │  coalesce · lease · evict    │            │                             │
  │  retry-once-on-stale         │            │ RemoteScriptOutput.parse    │
  └──────────────┬───────────────┘            │ TmuxCommandBuilder          │
                 │ vends child channels        │ SessionMetadata (+template) │
      ┌──────────┴──────────┐                 └─────────────────────────────┘
      ▼                     ▼
┌───────────────┐   ┌──────────────────┐
│ NIOSSHClient  │   │ SSHTerminalSession│──conforms──► TerminalTransport
│ (SSHExecuting)│   │  (PTY channel)    │              (Stage 2 seam)
└───────────────┘   └──────────────────┘
```

New files under `App/AISessionRemote/Services/SSH/`:

| file | responsibility |
| --- | --- |
| `SSHConnectionPool.swift` | actor; host → one authenticated connection; coalescing, leases, eviction, stale retry |
| `PooledConnecting.swift` | protocol: open an exec channel, open a PTY channel, close. The seam the pool's tests fake |
| `PooledSSHConnection.swift` | the real `PooledConnecting`: one authenticated parent channel vending child channels, issuing leases |
| `TerminalTransport.swift` | protocol the terminal depends on; Stage 2's seam |

Modified: `NIOSSHClient.swift` shrinks to an `SSHExecuting` adapter over the pool.
`SSHTerminalSession.swift` stops dialing and asks the pool for a PTY channel.

## Component: SSHConnectionPool

```swift
actor SSHConnectionPool {
    init(dial: @escaping (HostConnectionConfig) async throws -> PooledConnecting,
         clock: any Clock<Duration>)

    func connection(for config: HostConnectionConfig) async throws -> any PooledConnecting
    func warm(_ config: HostConnectionConfig)      // fire-and-forget; failures stay silent
    func closeAll()
}
```

The dial closure and clock are injected so that every behaviour below is unit-testable with
no network and no waiting.

**1. In-flight coalescing.** Concurrent callers arriving during a dial await the same `Task`.
A list refresh racing an attach produces one handshake, not two.

**2. Pool key.** Derived from `hostID`, `host`, `port`, `username`, and a SHA-256 of
`privateKeyPEM`. `HostConnectionConfig` is `Equatable`/`Sendable` but not `Hashable`, so the
key is a separate `Hashable` value type. Including the key material means editing a host or
rotating its key invalidates the cached connection instead of silently reusing a connection
authenticated as the previous user.

**3. Lease counting.** Every open exec or PTY child channel holds a lease. When leases reach
zero a 60 s idle timer starts; on expiry the connection closes and the pool drops the entry.
Acquiring a lease cancels a pending timer.

**4. Retry-once-on-stale.** A cached connection can be dead without the app knowing —
Wi-Fi↔cellular handoff, Tailscale re-route, iOS suspension. If opening a child channel on a
cached connection fails, the pool evicts the entry, dials fresh, and retries **once**. Only a
second failure reaches the user. Without this, pooling would trade slowness for spurious
"Could not reach the host" errors, which is a worse product than the slowness.

**Lifecycle.**

- `SessionsListView.onAppear` calls `warm(config)` — fire-and-forget. Warm failures are
  silent; the subsequent real action reports them, so a warm attempt never produces an error
  the user did not provoke.
- `UIApplication.didEnterBackgroundNotification` → `closeAll()`. iOS suspends sockets, and a
  half-dead socket costs a full connect timeout on next use, so closing eagerly is faster.
- `UIApplication.didBecomeActiveNotification` → `closeAll()`, so the next action dials fresh
  rather than discovering deadness slowly.

**Socket options.** Keep `TCP_NODELAY`. Add `SO_KEEPALIVE` plus Darwin's per-socket
`TCP_KEEPALIVE` at ~20 s idle, to hold NAT/Tailscale mappings open and surface a dropped
terminal in seconds rather than minutes.

**Liveness note.** swift-nio-ssh's `NIOSSHHandler` exposes only `createChannel` and
`sendTCPForwardingRequest` publicly — there is no generic global-request API, so
`keepalive@openssh.com` is unavailable. TCP keepalive plus retry-once-on-stale is the
substitute, and is why the retry behaviour is mandatory rather than a nicety.

### Accepted trade-off: one connection per host

Control commands and the terminal PTY share a single connection, so a burst of terminal
output can head-of-line-block a `tmux ls`. This is accepted because it is precisely what
OpenSSH `ControlMaster` does, control commands are small and infrequent, and Stage 2 moves
the terminal off SSH entirely — making the contention temporary by construction. The fix, if
it ever bites, is a second "interactive" connection per host keyed by purpose.

## Component: framed remote script output

Merging commands requires per-section exit codes, because existing error mapping depends on
them (`isNoServerError`, `isDuplicateSessionError`, `.binaryMissing`). One tested type in
`AISessionCore` carries the convention:

```text
<<<S:ls>>>
…stdout+stderr of tmux ls…
<<<X:ls:1>>>
<<<S:status>>>
…status file dump…
<<<X:status:0>>>
```

```swift
enum RemoteScriptOutput {
    struct Section { let text: String; let exitCode: Int32 }
    static func parse(_ stdout: String) -> [String: Section]
}
```

A section whose sentinel is absent is reported as missing rather than silently empty, so a
truncated payload fails loudly instead of looking like an empty session list.

## Component: merged commands

**`listSessions`: 2 execs → 1.** `tmux ls` and the status dump in one script, each framed
with its own exit code. The `ls` section's text feeds the existing `isNoServerError` check so
"no tmux server → empty list" is unchanged, and a failing status dump remains non-fatal.

**`createSession`: 5 execs → 2 per attempt.** One `listSessions`, then a single script:

```sh
p=$(command -v claude) || exit 90
mkdir -p ~/.ai-remote/sessions
printf '{"tool":"claude",…,"cli":["%s"]}' "$p" > ~/.ai-remote/sessions/<file>
tmux new-session -d -s '<name>' -c '<cwd>' -- "$p"
```

Exit 90 maps to `.binaryMissing`. tmux's own stderr still flows through, so duplicate-name
detection and the three-attempt retry loop are untouched.

**Metadata templating.** `SessionMetadata.cli` holds the resolved binary path, which is only
known on the host, so the JSON cannot be fully built client-side. `SessionMetadata` gains a
template encoder emitting JSON with one `%s` slot for `cli` and **every literal `%` elsewhere
escaped to `%%`**. Without that escaping a session titled `100% done` corrupts the metadata
file. This is the single riskiest line in the spec and is covered by a dedicated test.

**`promoteSession`: 2 execs → 1.** Rename and metadata write in one script.

## Component: terminal render path

- **Drop the redundant attach resize.** Send `window-change` after connect only when the live
  size actually differs from the dimensions the PTY was requested with.
- **Debounce `sizeChanged`** on a ~150 ms trailing edge and skip when the size equals the last
  value sent.
- **`TerminalOutputCoalescer`** — the NIO thread appends into a lock-guarded buffer; a
  main-thread display-link drain empties the whole buffer in a single `feed(byteArray:)`.
  Extracted as a plain class with an injected scheduler (no `CADisplayLink`, no SwiftTerm) so
  it is unit-testable.
- **Suppress the connecting overlay for the first ~250 ms**, since a warm pool makes attach
  fast enough that the overlay would otherwise flash.

## Error handling

Behaviour is unchanged by construction, and this is verified rather than assumed: the
existing `SessionServiceTests` cases for no-server, duplicate-name, and missing-binary must
pass **unmodified** against the merged commands.

New failure paths introduced by pooling:

| condition | behaviour |
| --- | --- |
| dial fails | existing `.unreachable` / `.authenticationFailed` mapping, unchanged |
| channel open fails on cached connection | evict, re-dial, retry once |
| retry also fails | propagate the underlying error |
| warm dial fails | swallowed; no UI |
| connection dies with a terminal attached | existing disconnect overlay, unchanged |

## Testing strategy

XCTest throughout, matching the existing layout.

**Pool** (fake dial + test clock, no network): concurrent `connection(for:)` produces exactly
one dial; a changed key PEM produces a second dial; leases reaching zero then advancing 60 s
closes the connection, and taking a lease first cancels it; a first channel-open failure
produces one eviction, one re-dial and a success; a second failure propagates.

**Round-trip regression guards** via the existing `FakeSSHExecutor`, which already records
commands — `listSessions` issues exactly 1 exec, `promoteSession` exactly 1, and
`createSession` exactly 2 **per attempt** (asserted as 2 on the happy path, and 2 × N after N
duplicate-name retries, since its retry loop re-lists each time). These fail loudly if a
convenience `exec` is ever added back to a hot path, which is the failure mode most likely to
silently undo this work.

**`RemoteScriptOutput.parse`** — missing sections, empty sections, non-zero section exit
codes, and payload text that itself contains a sentinel-looking line.

**`SessionMetadata` template** — round-trips through `printf`, and a title containing `%`
survives intact.

**`TmuxCommandBuilder`** — string assertions for the merged builders alongside the existing
`TmuxCommandBuilderTests`.

**`TerminalOutputCoalescer`** — N appends produce 1 flush with bytes in original order.

**Manual acceptance** (add to `docs/superpowers/plans/manual-acceptance.md`): Network Link
Conditioner at 150 ms on a device, stopwatch against the target table below. Unmeasured
performance numbers in a spec are wishes, so this step is required before calling Stage 1
done.

## Success criteria

At ~150 ms RTT with a warm connection:

| action | today | target |
| --- | --- | --- |
| session list refresh | ~2.1 s | ~0.3 s |
| new session | ~5.2 s | ~0.6 s |
| attach to session | ~1.0 s | ~0.3 s |
| kill session | ~1.0 s | ~0.3 s |

Plus: no behaviour or error-message changes, and the full existing test suite passing.

## Stage 2 seam

```swift
protocol TerminalTransport: AnyObject {
    var onOutput: ((ArraySlice<UInt8>) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func connect(cols: Int, rows: Int) async throws
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    func disconnect()
}
```

`SSHTerminalSession` conforms; `TerminalCoordinator` holds the protocol rather than the
concrete type. Stage 2 adds `MoshTerminalTransport` beside it with no change to
`TerminalScreen`.

Mosh bootstraps by running `mosh-server new -s -c 256 -- tmux attach -t <name>` over SSH and
parsing `MOSH CONNECT <port> <key>` from its output — which is an ordinary `exec`. Stage 1's
pool is therefore Stage 2's bootstrap channel, and a prerequisite for Mosh connecting quickly.

Stage 1 deliberately ships **no** `mosh-server` detection, transport preference, or UI.

## Stage 2 preview (not in scope)

Recorded here so the Stage 2 spec starts from findings already made:

- Distribution is personal / TestFlight / device only — already a non-goal of App Store
  release in the v1 spec — so vendoring Mosh's GPLv3 client is acceptable.
- Mosh 1.4.0 requires **protobuf** (which now pulls in **abseil**) and **ncurses/tinfo**, for
  both client and server. iOS needs protobuf + abseil cross-compiled for device and simulator,
  and Mosh's `Display` terminfo lookups either ported or replaced with a fixed
  `xterm-256color` capability set.
- `STMClient` owns its own `select()` loop, puts the local tty in raw mode via `tcsetattr`,
  and handles `SIGWINCH` — so it wants a real pty, not pipes. The workable shape is
  `openpty()`, a patched `mosh_main` on a background thread with the slave as stdin/stdout,
  and the app reading/writing the master with `ioctl(TIOCSWINSZ)` on resize.
- Predictive echo then arrives for free: Mosh emits it as ordinary escape sequences that
  SwiftTerm renders.
