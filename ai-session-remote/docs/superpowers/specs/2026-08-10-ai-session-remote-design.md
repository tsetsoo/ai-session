# AI Session Remote — Design Spec

**Date:** 2026-08-10  
**Status:** Approved for implementation planning  
**Working name:** AI Session Remote

## Problem

Control Claude Code, Codex CLI (ChatGPT CLI), and Cursor CLI (`agent`) sessions on multiple Tailscale-reachable hosts from an iPhone — without babysitting a generic SSH client. Primary use is task-oriented (start work, check back, send follow-ups, interrupt) with a real terminal when needed.

## Goals (v1)

- Native SwiftUI iPhone app
- Multi-host SSH over Tailscale (key auth, Keychain)
- Hosts-first navigation: Hosts → Sessions → Terminal
- Auto-manage **tmux** sessions for all three CLIs
- Pull-only session discovery (no push notifications)
- Stable conventions so a future host agent can plug in without rewriting the phone UX

## Non-goals (v1)

- Push notifications
- Host-side daemon/agent
- App Store distribution (personal Team / TestFlight / device only)
- Controlling Cursor’s desktop GUI
- Full multi-pane tmux UI
- Shared / team host configs

## Approach

**Hybrid (approach 3):** Ship a pure Swift SSH + tmux client now. Keep a naming/metadata contract that a later optional host agent can expose as structured status (and eventually push).

## Architecture

```text
┌─────────────────────┐     Tailscale      ┌──────────────────────────┐
│  iOS app (SwiftUI)  │ ──── SSH/PTY ────► │  Host (sshd + tmux)      │
│  • Host list        │                    │  • ai/<tool>/<slug>      │
│  • Session list     │                    │  • claude / codex / agent│
│  • Embedded terminal│                    │  • ~/.ai-remote/ (opt)   │
└─────────────────────┘                    └──────────────────────────┘
         │                                              │
         │  later                                       │  later
         ▼                                              ▼
   same Hosts→Sessions UI                    optional host agent API
```

**Layers (v1):**

1. **iOS app** — UI, Keychain keys, SSH client, terminal renderer
2. **SSH + tmux** — source of truth for running sessions
3. **Convention contract** — session names + optional JSON metadata for future agent

## Data model

### Host (persisted on phone)

| Field | Notes |
|-------|--------|
| id | UUID |
| displayName | e.g. `scraper-droplet` |
| hostname | Tailscale MagicDNS name or `100.x` IP |
| port | Default 22 |
| username | SSH user |
| privateKeyKeychainRef | Keychain reference; never store raw key in UserDefaults |
| defaultPaths | Optional project path bookmarks |
| cliBinaries | Optional overrides: `claude`, `codex`, `agent` command names (default to those) |
| lastReachableAt | Optional, for UI |

### Session (discovered live; not authoritative offline)

| Field | Notes |
|-------|--------|
| hostId | Parent host |
| tmuxName | Full tmux session name |
| tool | `claude` \| `codex` \| `cursor` |
| slug / title | From name or metadata |
| cwd | From metadata or best-effort |
| status | `running` \| unknown (v1: mainly “exists in tmux”) |

### Tmux naming contract

```text
ai/<tool>/<slug>
```

Examples:

- `ai/claude/sigma-revenue`
- `ai/codex/overnight`
- `ai/cursor/portfolio`

**Rules:**

- App-created AI sessions always use this pattern
- Refresh: `tmux ls` → show matching sessions; non-matching under collapsed “Other” (or hide)
- New session: `tmux new-session -d -s ai/<tool>/<slug> -c <cwd> -- <cli…>` then attach
- Attach: reattach existing tmux session over SSH PTY
- Disconnect / backgrounding the app leaves the tmux session running
- If `tmux` is missing: block AI session create; show install hint; allow separate plain-SSH escape hatch

### Optional metadata (write now, read optional)

On create, write:

```text
~/.ai-remote/sessions/<tmux-name>.json
```

Where `<tmux-name>` has `/` replaced by `__` (e.g. `ai__claude__sigma-revenue.json`).

Suggested fields: `tool`, `cwd`, `title`, `started_at`, `cli` (exact argv).  
v1 may list sessions from `tmux ls` alone; metadata improves cwd/title and unlocks a future agent.

## UI

### Screens

1. **Hosts** — list with Tailscale reachability indicator, add/edit host, session count when last refreshed
2. **Sessions (per host)** — rows colored/labeled by tool; **New** opens sheet; tap attaches
3. **Terminal** — full-screen VT/PTY attached to tmux; back detaches (does not kill); menu: detach, kill session, best-effort copy
4. **New session sheet** — tool → path (bookmark or typed) → slug/title → Start
5. **Host editor** — hostname, user, port, import/replace key, default paths, optional CLI binary overrides
6. **Plain SSH** (escape hatch) — open an interactive shell on the host without creating an `ai/…` tmux session (available from host screen menu)

### Interaction notes

- Extra soft keys for CLI TUIs: Ctrl-C, Tab, Esc (and keyboard)
- Pull-to-refresh on hosts and sessions
- No push; user opens app to check

## Tech stack

| Area | Choice |
|------|--------|
| UI | SwiftUI |
| Persistence | SwiftData for hosts; Keychain for keys |
| SSH | SwiftNIO SSH (or thin wrapper) — key auth + interactive channel |
| Terminal | Embedded VT100 terminal view (SwiftTerm-class) wired to SSH PTY |
| Package mgmt | Swift Package Manager |
| Network | Assume Tailscale already provides reachability |
| Distribution | Personal Apple Team, TestFlight / local device |

### Host prerequisites

- Tailscale connected
- `sshd` reachable from phone
- `tmux` installed
- CLIs on `PATH`: defaults `claude`, `codex`, `agent` (overridable per host)

## Error handling

| Condition | Behavior |
|-----------|----------|
| Host unreachable / Tailscale down | Banner / red status on host row; sessions unavailable |
| Auth failure | Prompt to re-import key / edit host |
| `tmux` missing | Block AI create; show install instructions |
| CLI binary missing | Name the missing binary; allow plain SSH |
| Mid-session disconnect | Session remains in tmux; reconnect reattaches |
| Duplicate slug | Reject or auto-suffix (`-2`); do not overwrite |

## Future host agent (out of v1, designed for)

- Same session identity (`ai/<tool>/<slug>` + `~/.ai-remote/`)
- Expose list/status (and later push hooks) without changing Hosts → Sessions → Terminal
- Phone gains richer “waiting / idle / running” only when agent is present

## Testing strategy (v1)

- Unit: session name parsing/formatting; metadata JSON encode/decode
- Integration (Mac/Linux host fixture): create → list → attach → kill via SSH against a test host or local `sshd` in CI where feasible
- Manual: TestFlight on device over Tailscale against a real host with all three CLIs

## Success criteria

- From the phone, add a Tailscale host with a key, create a Claude / Codex / Cursor session in a chosen cwd, disconnect, reconnect later, and continue the same tmux-backed session
- Unrelated tmux sessions do not clutter the primary list
- No secrets written to plaintext app storage
