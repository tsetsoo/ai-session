# Terminal UI redesign: the frame around the conversation

Date: 2026-10-16 · Status: draft for approval

## Intent

The conversation is, and stays, a real terminal: SwiftTerm running `claude` / `codex` in
tmux over SSH. Everything *around* it gets redesigned so the app feels like the Claude
desktop/iOS app and Cursor's agents view. That means calm lists, a live status on every
conversation, one obvious place for the conversation, and fast keyboard paths. Today the
app is two tabs (Todos, Hosts) that push a black terminal with a `⋯` menu. Status is a small
capsule, and errors come up as alerts.

**Success:** open the app, see at a glance which conversations need you, and get into one
with one tap or keystroke. The frame shows up instantly and the terminal fills it. Every
dead end says what to do next.

## Goals / non-goals / anti-goals

Goals: the six areas from the brief (layout, terminal frame, status everywhere, visual
language, fast paths, empty/error states). Details are below.

Non-goals:
- A rendered chat view. Parsing Claude's output. Any change to what the terminal shows.
- Keeping terminals attached in the background for instant switching. That is latency
  work and stays as it is today: switching disconnects, and the pool makes reattaching fast.
- New server endpoints. Everything here uses today's todo-server API and `/api/ws`.

Anti-goals (a failure even if it "works"):
- Any regression in typing latency, output coalescing, resize debounce or pooling.
- SSH jargon on primary screens (host, key, tmux, port, `user@host`).
- Section codes expanded into names. `Sp / I / Si / P` stay opaque everywhere.
- Fake data reachable in a release build.

## Constraints

- iOS 17 / macOS 14 deployment targets. One source tree (`App/AISessionRemote`) builds the iOS
  app (iPhone + iPad) and the Mac app. Reuse `MacCompatibility.swift` / `PlatformSupport`
  and extend them rather than scattering `#if`.
- `TerminalCoordinator`, `SSHTerminalSession`, the coalescer, the debouncer and the pool keep
  their behaviour. The redesign wraps `TerminalContainerView`; it does not re-plumb input.
- All existing features stay reachable: per-computer tmux sessions, new session, promote
  session, plain shell, host editor, hub settings, computers + section mapping, link /
  create-from / delete conversation, offline cache.
- New UI goes in new files (`Views/Frame/`, `Views/Shell/`, `Views/Lists/`,
  `Views/Palette/`, `Theme/DesignSystem.swift`). Existing files only get the edits needed
  to hand off to them.

## Vocabulary on screen

| Model | Shown as | Notes |
|---|---|---|
| hub `Computer` + matching local `HostEntity` | **computer** ("mac-studio") | matched by hostname+port+user as today |
| `HostEntity` key / user / port | Settings → *Access & keys* only | |
| `Conversation` | **conversation** | tool shown as "Claude" / "Codex" |
| tmux session not linked to a todo | **other session** (computer detail) | |
| `cwd` | **folder** (`~/code/app`, middle-truncated) | |

## Status model

One `StatusBadge` component used everywhere (lists, sidebar, header pill, palette).

| `ConversationStatus` | Badge | Look |
|---|---|---|
| `busy` | **Working** | three-dot pulse (animated, respects Reduce Motion → static dot), primary colour |
| `waiting` | **Needs you** | filled accent capsule, white text |
| `idle`, `unknown` | **Idle** | hollow grey dot + secondary text |
| `closed` | **Closed** | no dot, tertiary text |
| no conversation | nothing | |

`unknown` (no hook report yet, which is always the case for Codex) is shown as Idle. *My call.*

Derived sets (in the app model, recomputed on every refresh):
- **Needs you** = conversations with `waiting`.
- **Running now** = conversations not `closed` *and* whose tmux session is alive, in **stable
  order** (newest started first), so ⌘1–9 don't jump around as statuses change.
  - The hub only learns about a close through an explicit Close or Delete. A tmux session
    that died (for example after a reboot) would otherwise stay "running" forever.
  - So when Running now, a computer, or the sidebar first appears, and on pull-to-refresh, the
    app lists tmux sessions once per reachable computer. That is one pooled exec, the same
    listing `SessionsListView` already does.
  - Conversations whose `tmuxName` is missing show as **Closed** locally. Nothing is written
    to the hub. Unreachable computers keep their hub status. *My call.*

## Visual language

- System font, Dynamic Type everywhere except the terminal grid. Spacing tokens are 4/8/12/16/24.
  List rows are at least 52pt tall, with a two-line layout (title, then a secondary line).
- **One accent colour:** Claude terracotta `#D97757` (asset-catalog colour with a lighter
  dark-mode variant), used for Needs you, the primary buttons and selection. *My call.* The
  per-tool amber/teal/blue in `AppTheme` is retired from the new screens, and tools get
  monochrome SF Symbols (`sparkle` Claude, `chevron.left.forwardslash.chevron.right` Codex).
- Mac: `NavigationSplitView` with sidebar material, unified toolbar and source-list
  selection. iOS: inset-grouped lists and large titles.
- The app chrome follows the system appearance (light and dark), with no forced scheme. Tokens
  live in `Theme/DesignSystem.swift`. The terminal's own theme is a separate choice (§2).

## Screens

### 1. Mac: three columns (iPad in regular width uses the same layout)

```
┌──────────────────────┬────────────────────────────────┬──────────────────────────────────────────────┐
│ ● ● ●                │  Needs you           ⌕   ＋    │  (conversation frame, see §2)                │
│                      ├────────────────────────────────┤                                              │
│  ⚑ Needs you      2  │ ◉ Needs you                    │                                              │
│  ▶ Running now    5  │ Fix the rate import            │                                              │
│                      │ Sp · mac-studio · Claude   2m  │                                              │
│  TODOS               │ Claude needs your permission…  │                                              │
│  ▢ Sp            12  ├────────────────────────────────┤                                              │
│  ▢ I              8• │ ◉ Needs you                    │                                              │
│  ▢ Si             3  │ Draft the HTIF follow-up       │                                              │
│  ▢ P              4  │ I · linux-box · Codex      9m  │                                              │
│                      │                                │                                              │
│  COMPUTERS           │                                │                                              │
│  🖥 mac-studio    3  │                                │                                              │
│  🖥 linux-box     2  │                                │                                              │
│                      │                                │                                              │
│ ─────────────────    │                                │                                              │
│ ✓ Synced · just now  │                                │                                              │
│ ⚙ Settings           │                                │                                              │
└──────────────────────┴────────────────────────────────┴──────────────────────────────────────────────┘
```

- **Sidebar.** Counts are trailing and secondary. The Needs-you count, and the small dot on a
  section (`I 8•`), use the accent when non-zero. A computer's count is its running
  conversations. The footer shows sync state: "Synced · just now", "Offline · showing 5m ago",
  or "Server rejected the token". Settings is at the bottom (also ⌘,).
- **List column, by selection:**
  - *Section* → that section's todos. A todo row has a checkbox, the title, a trailing status
    badge, and a second line ("mac-studio · 3m" or the status message). Completed todos sink to
    the bottom. Context menu: Open, Link conversation…, Close conversation, Delete conversation…,
    Delete todo.
  - *Needs you / Running now* → conversation rows (status, todo title, "section · computer ·
    tool", relative time, status message). The ⌘1–9 hint shows on hover in Running now.
  - *Computer* → its running conversations, then **Other sessions** (today's
    `SessionsListView` content: AI sessions plus other tmux), then **On this computer** (today's
    remote-conversation picker, with Link to todo… / New todo from this…). Toolbar: Open shell,
    New session (⌥⌘N).
  - `.searchable` filters the current list. ＋ = New todo (⌘N).
- **Detail.** The conversation frame (§2), or an empty state: "Select a conversation",
  plus a hint line "⌘K to jump · ⌘N new todo".
- **Selecting vs starting** (*my call*). Arrow keys move the selection, so selection alone
  must never create or resume anything.
  - Selecting a *running* conversation attaches, debounced 150 ms so arrowing through the list
    doesn't connect to each one.
  - Selecting a todo with no conversation, or a closed one, shows the frame with a **Start
    Conversation** / **Resume** button in the terminal area. ⏎, a double-click or that button
    does the get-or-create on the hub.
  - On iPhone a tap is explicit, so it starts or resumes immediately, as today.
  - ⌘K and ⌘1–9 pick an explicit target, so they open (start or resume) immediately.

### 2. Mac: conversation frame

The header is the window toolbar of the detail column, so it is native, slim and on a
material background.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│  Fix the rate import                                   ◉ Needs you   ⎘   ⧉   ⋯               │
│  Sp · mac-studio · ~/code/rms-backend · Claude                                               │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                              │
│   ╭─ Claude Code ──────────────────────────────╮       (terminal, edge to edge;              │
│   │ Do you want to run `cargo test`?           │        10pt padding filled with the         │
│   │ ❯ 1. Yes                                   │        terminal background, so the          │
│   │   2. Yes, and don't ask again              │        padding reads as part of the         │
│   │   3. No, and tell Claude what to do        │        terminal, not as a border)           │
│   ╰────────────────────────────────────────────╯                                             │
│                                                                                              │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Title** = todo title. **Subtitle** (`navigationSubtitle`) = `section · computer · folder ·
  tool`. The folder is middle-truncated.
- **Status pill** = live `StatusBadge`. It updates from `/api/ws` while the terminal is open.
- **Actions:**
  - ⎘ **Copy resume command** → `cd '<cwd>' && claude --resume <id>` (or `codex resume <id>`),
    with a "Copied" toast.
  - ⧉ **Open in new window** (Mac only, ⇧⌘O) → `WindowGroup(id: "conversation", for: String.self)`
    keyed by todo id. The main window's detail then shows "Open in its own window ·
    [Show Window] [Bring Back]" instead of attaching a second client, because tmux
    `window-size latest` would make two attached views fight over the size.
  - ⋯ menu → Close Conversation (ends tmux, keeps it resumable, which is today's "Kill
    Session"), Delete Conversation… (confirmation dialog, today's text), Reconnect, Copy
    Screen, Paste, Text Size ▸ (Bigger ⌘+, Smaller ⌘−, Default ⌘0).
- **Terminal appearance:**
  - Font: SF Mono (`monospacedSystemFont`). Default 13pt on Mac, 11pt on iPhone, range 9–24,
    persisted in `@AppStorage`.
  - ⌘+/⌘−/⌘0 work on the Mac and with an iPad hardware keyboard. A size change goes through
    SwiftTerm's normal resize, so the existing debouncer handles it.
  - Theme: a dark palette and a light palette (background, foreground, cursor, selection, 16
    ANSI colours), with a setting under Settings → Terminal (System / Light / Dark).
    **Default: System** (decided 2026-10-16), so the terminal follows the app's light/dark
    appearance. Claude Code picks its own colours with `/theme`; Settings → Terminal notes that
    Claude's theme should be set to match (or auto).
- **Opening feels instant.** The frame (title, subtitle, pill, actions) renders from local
  data the moment a row is selected. The terminal area moves through these states *inside
  itself*, drawn on the terminal background:

```
   Preparing  →  "Starting conversation on mac-studio…"   (hub get-or-create, host lookup)
   Connecting →  small spinner, after the existing 250 ms gate, "Connecting to mac-studio…"
   Connected  →  terminal; keyboard focus lands in it
   Problem    →  in-frame error state (§6) with the action that fixes it
   Ended      →  "Disconnected" + [Reconnect]   (today's overlay, restyled, no black scrim)
```

### 3. iPhone: lists

Tab bar: **Todos** · **Conversations** (badge = Needs-you count) · **Computers**. Each tab has
a large title and a ⚙ button that opens Settings as a sheet.

```
┌───────────────────────────────┐  ┌───────────────────────────────┐  ┌───────────────────────────────┐
│ ⚙                          ＋ │  │ ⚙                             │  │ ⚙                          ＋ │
│ Todos                         │  │ Conversations                 │  │ Computers                     │
│ ┌───────────────────────────┐ │  │ [ Needs you 2 | Running | All]│  │ ┌───────────────────────────┐ │
│ │ Sp              mac-studio│ │  │ ┌───────────────────────────┐ │  │ │ 🖥 mac-studio            › │ │
│ │ ○ Fix the rate  ◉Needs you│ │  │ │◉ Fix the rate import   2m │ │  │ │   3 running · 1 needs you │ │
│ │   Claude needs permission…│ │  │ │  Sp · mac-studio · Claude │ │  │ │   Sp  I                   │ │
│ │ ○ Import Booking  ⋯Working│ │  │ │  Claude needs your perm…  │ │  │ ├───────────────────────────┤ │
│ │   mac-studio · 1m         │ │  │ ├───────────────────────────┤ │  │ │ 🖥 linux-box             › │ │
│ │ ○ Call Santé          Idle│ │  │ │◉ Draft HTIF follow-up  9m │ │  │ │   2 running               │ │
│ │ ✓ Old thing               │ │  │ │  I · linux-box · Codex    │ │  │ │   Si  P                   │ │
│ └───────────────────────────┘ │  │ └───────────────────────────┘ │  │ ├───────────────────────────┤ │
│ ┌───────────────────────────┐ │  │                               │  │ │ 🖥 old-laptop            › │ │
│ │ I                linux-box│ │  │                               │  │ │   Needs access · Set Up   │ │
│ │ ...                       │ │  │                               │  │ └───────────────────────────┘ │
│ ├───────────────────────────┤ │  │                               │  │                               │
│ │ ✎ New todo…    [I ▾]  🎙   │ │  │                               │  │                               │
│ └───────────────────────────┘ │  │                               │  │                               │
│  ☑ Todos   💬 Conv(2)  🖥 Comp│  │  ☑ Todos   💬 Conv(2)  🖥 Comp│  │  ☑ Todos   💬 Conv(2)  🖥 Comp│
└───────────────────────────────┘  └───────────────────────────────┘  └───────────────────────────────┘
```

- **Todos.**
  - Inset-grouped sections `Sp / I / Si / P`. Each header shows the section's computer in
    secondary text.
  - Row swipe actions: leading **Done/Undo** (full swipe); trailing **Delete**, plus **Close**
    when a conversation is running and **Link…** when there is none.
  - The context menu mirrors the Mac one.
  - **Quick-add** is pinned under the list. Tap it, type, return. The section chip defaults to
    the last used section. 🎙 starts in-app dictation (see §5).
  - The ＋ menu keeps New Todo / New Todo from Conversation….
- **Conversations.** A segmented filter: Needs you (default when non-empty) / Running / All.
  Row swipes: trailing **Close**, **Delete…**; leading **Copy resume command**.
- **Computers.** Rows show live counts, the sections the computer serves, and whether this
  device can reach it.
  - Tap a computer: running conversations, Other sessions, On this computer (link /
    new todo), and **Open Shell**.
  - A computer with no access on this device shows **Set Up** (it opens the host editor,
    prefilled as today).
  - Local-only hosts that aren't hub computers are listed under "Other computers".
- **Settings sheet:** Todo server · Sections (computer + folder per section; today's
  `SectionMappingSheet`) · Computers on the server (add/delete) · **Access & keys** (today's
  `HostsListView`/`HostEditorView`; the only place SSH words appear) · Terminal (text size,
  theme) · Notifications.

### 4. iPhone: terminal + key bar

The terminal is pushed full screen: the tab bar is hidden and swipe-back still works.

```
┌───────────────────────────────┐
│ ‹      Fix the rate import  ⋯ │   inline nav bar with a two-line principal title,
│   Sp · mac-studio · Claude    │   status pill under it; ⋯ = copy resume, close,
│        ◉ Needs you            │   delete…, reconnect, text size, copy screen, paste
├───────────────────────────────┤
│╭─ Claude Code ───────────────╮│
││ Do you want to run          ││   terminal, edge to edge, 6pt padding
││ `cargo test`?               ││   in the terminal background colour
││ ❯ 1. Yes                    ││
││   2. Yes, and don't ask…    ││
││   3. No                     ││
│╰─────────────────────────────╯│
│ > _                           │
├───────────────────────────────┤
│ esc  tab  ctrl  ←  ↑  ↓  →  ⇧⏎ ✓Approve  ⌨ │   key bar, 44pt, material, scrolls
├───────────────────────────────┤                horizontally if needed
│        (system keyboard)       │
└───────────────────────────────┘
```

- **One key bar**, always docked: above the keyboard when it is up, and at the bottom safe
  area when it is down. It replaces both `SoftKeyBar` and SwiftTerm's `TerminalAccessory`
  (`inputAccessoryView` is set to an empty view, and the bar is a `safeAreaInset(edge: .bottom)`).
- **Keys:**
  - `esc`, `tab`.
  - `ctrl`: sticky. It highlights while armed and applies to the next key, using
    SwiftTerm's `controlModifier`. `ctrl` then `c` gives ^C, which replaces the old Ctrl-C key.
  - Arrows (auto-repeat on hold).
  - `⇧⏎` sends `ESC CR`, the newline Claude Code accepts. Codex gets `^J`.
  - Paste lives in the ⋯ menu and in the long-press on `⌨`.
  - `⌨` shows or hides the keyboard.
- **✓ Approve** sends what the tool expects at a permission prompt: Claude `1`, Codex `y`.
  - For Claude it is accent-tinted and enabled only while the status is `waiting` and you
    haven't typed anything since that status arrived. Answering a prompt from the keyboard
    leaves the hub at `waiting` until the next prompt, so any keystroke disarms Approve until
    the status changes again. This avoids a stray `1` landing in Claude's input box. *My call:
    a client-side guard, with no hook change.*
  - Codex reports no status, so its Approve stays enabled in neutral style. *My call.*
- **Haptics:** light tick on every key bar key, rigid tap on Approve, success on connect and
  warning on disconnect (as today), and a warning notification haptic when a conversation
  flips to Needs you while the app is open.

## 5. Fast paths

- **⌘K palette (Mac).**
  - A centred floating panel over the window (material, 560pt wide) with a search field
    and keyboard-navigable results (↑↓ ⏎, esc).
  - Groups: *Conversations* (with status badges, Needs-you first), *Todos*, *Actions*: New
    Todo, Link Conversation to "<selected todo>"…, New Todo from Conversation…, Open
    Settings. A fuzzy match over title, section code and computer.
- **⌘1–9** select the n-th conversation in *Running now* order (stable, see Status model).
  **⌘N** opens the new-todo sheet, prefilled with the selected section.
  - Today's ⌘N for "New Session" moves to **⌥⌘N**. *My call.*
  - **⌘+/⌘−/⌘0** set the text size; **⇧⌘O** pops the conversation out into its own window.
  - All of these are in the menu bar (a "Conversation" menu) so they are discoverable.
- **Quick-add with dictation (iOS).**
  - The pinned quick-add field keeps the keyboard's own dictation key.
  - 🎙 starts in-app speech-to-text (`SFSpeechRecognizer`, on-device when available) straight
    into the field. A second tap stops it. Return adds the todo.
  - Needs `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
  - A Home-screen quick action "New Todo" opens the app with the field focused.
- **Instant open:** see §2. The frame never waits on the network.

## Notifications and focus

- **Ownership (agreed 2026-10-17 with the separate push-notifications work):** that work owns
  `NotificationCenterCoordinator`, which handles the notification delegate, permission,
  APNs push from the todo-server, and deduplication between push and local alerts.
  - This redesign only detects the flip and calls `postWaiting`, reports the visible
    conversation, and owns the Settings toggle UI.
  - Permission is asked from the Settings toggle, never on first launch.
  - Background iPhone alerts come from that work's push, not from this redesign.
- The store diffs each refresh against the previous one. A conversation moving *into*
  `waiting` calls `postWaiting` with title = the todo title and body = "Needs you". There is
  never a status message or any conversation text, so it matches what a push can carry.
  - The coordinator posts the alert locally or relies on push.
  - On the Mac it alerts only when no iPhone is registered for push, unless "Alert on this
    Mac too" is on.
  - Already-waiting conversations at launch don't notify.
  - No notification while that conversation is frontmost and the app is active (just
    the haptic). Tapping the notification opens that conversation (Mac: selects it in the
    main window; iPhone: switches to Conversations and pushes it).
- Switching to a conversation that is `waiting` lands keyboard focus in the terminal, on Mac
  too, where focus would otherwise stay in the list. Other conversations keep today's
  behaviour (focus after connect).

## 6. Empty and error states

The ones about a conversation render **inside the terminal area** of the frame, on the
terminal background, as `ContentUnavailableView`-style blocks with one primary action.
List-level ones render in the list column.

| Situation | Detected by | Says | Action |
|---|---|---|---|
| No server configured | `!store.isConfigured` | "Connect to your todo server" | **Open Settings** |
| Server unreachable | `isOffline` | footer/banner "Offline · showing todos from 5m ago"; changes disabled | **Retry** |
| Token rejected | `unauthorized` | "The server didn't accept the API token" | **Open Settings** |
| No computer for section | hub 409 "no computer" | "No computer runs Sp conversations yet" | **Choose Computer** (Settings → Sections → Sp) |
| Computer has no access on this device | no matching host | "This device can't open conversations on mac-studio yet" | **Set Up Access** (prefilled host editor) |
| Host without key | `SessionServiceFactory` throws | "The key for mac-studio is missing on this device" | **Fix in Settings** |
| Can't reach computer | connect fails, unreachable | "Can't reach mac-studio. Check it's awake and on Tailscale." | **Try Again** |
| Helper scripts missing | exit 127 | "mac-studio needs the AI Session helpers" + a copyable block `scripts/todo/install.sh --hub-url <current URL> --token "$TODO_API_TOKEN"` | **Copy Command** |
| Claude/Codex/tmux not installed | exit 90 | "Claude isn't installed on mac-studio" (stderr names which) | **Try Again** |
| Folder missing | exit 93 | "The folder ~/code/app doesn't exist on mac-studio" | **Change Folder** (Settings → Sections) |
| Conversation not found | exit 94 | "This conversation no longer exists on linux-box" | **Unlink** · Copy resume command |
| Empty Needs you | | "Nothing needs you" (checkmark) | none |
| Empty Running now | | "No conversations running. Open a todo to start one." | none |
| Empty section | | "No todos in Sp" | **New Todo** |
| Mac detail, nothing selected | | "Select a conversation" + ⌘K/⌘N hints | none |

Exit codes come from `ai-todo-open`, which runs as the PTY's command. **The builder adds
exit-status reporting** to the transport: `SSHTerminalSession` reads NIOSSH's `ExitStatus`
channel event and passes it with `onDisconnect`. This is additive and adds no round-trip
on the happy path. Today a failed open just shows "Disconnected".

## Architecture (for the builder)

- **`AppModel`** (`@Observable`, created once in `AISessionRemoteApp`, injected via
  `.environment`).
  - Owns the single `TodoHubStore` (moved up from `TodosView`'s `@State`), selection
    (sidebar item, list item), popped-out conversation ids, the Needs-you / Running-now
    sets, and transition detection for notifications.
  - Mac pop-out windows share it, so there is one `/api/ws` connection.
- **`ConversationLoader`**: the Preparing → Connecting → Connected | Problem state machine
  behind the frame. It wraps today's `TodosView.open(_:)` logic (hub get-or-create, host
  match, `SessionServiceFactory`), then hands `TerminalScreen`'s terminal view the config.
  `TerminalScreen` is split so the terminal body (`TerminalContainerView` + coordinator
  wiring) can be hosted inside the new frame. Its connect, focus, disconnect and overlay
  timing code is moved, not rewritten.
- **Platform split**: `RootView` picks `MacShell` (`NavigationSplitView`), used on macOS and
  iPad in regular width, or `PhoneShell` (`TabView`). Lists, rows, badges, frame and error
  views are shared.
- **Previews / screenshots**: `#if DEBUG` fixtures plus a `-uiDemo` launch argument (like the
  existing `-demoConversationPicker`). In demo mode a debug-only transport feeds canned ANSI
  (a Claude permission prompt) into SwiftTerm, so screenshots show a realistic terminal with
  no server. None of this compiles into release builds.

## Delivery: small stacked PRs

Each PR builds both targets and passes the existing tests (`swift test` plus the
`AISessionRemoteTests` scheme). Each PR then gets Simulator (iPhone 16) and Mac screenshots,
light and dark, which are compared with the mockups above and attached to the PR.

1. **Foundations:** `DesignSystem` tokens, accent, `StatusBadge`, terminal theme + SF Mono +
   text size (⌘+/−/0), applied to today's screens. Debug `-uiDemo` fixtures.
2. **Conversation frame:** header, actions (copy resume, close, delete), `ConversationLoader`
   with instant open and in-frame connecting/error states, exit-status plumbing.
3. **iPhone shell:** tabs, the three lists with swipe actions, Settings sheet (absorbs Hosts,
   Server, Sections, Computers), quick-add with dictation.
4. **iPhone key bar + haptics.**
5. **Mac shell:** three columns, sidebar counts, computer detail, pop-out window (iPad
   regular width gets the same).
6. **Status everywhere:** notifications on flip to waiting, tab badge, focus-on-waiting.
7. **Fast paths:** ⌘K palette, ⌘1–9, ⌘N, Conversation menu.

## Calls I made (check these)

- Accent = Claude terracotta `#D97757`. Tool colours are dropped from the new screens.
- `unknown` status is shown as Idle.
- ⌘1–9 follow a stable Running-now order (newest started first), not a status-sorted one.
- "New Session" moves from ⌘N to ⌥⌘N.
- Approve sends `1` (Claude, only while waiting and untouched since) / `y` (Codex, always enabled).
- On the Mac, selection attaches only to running conversations. Starting or resuming needs ⏎,
  a double-click or the button.
- Running now hides conversations whose tmux session is gone. This uses one listing per
  computer and writes nothing to the hub.
- No background notifications on iPhone (needs APNs, out of scope).
  `⇧⏎` sends `ESC CR` (Claude) / `^J` (Codex).
- Pop-out shows a placeholder in the main window instead of attaching twice.
- The install command shown copies with a `$TODO_API_TOKEN` placeholder, never the real token.
- iPad in regular width uses the Mac layout.
- Dictation uses in-app `SFSpeechRecognizer` (new permission prompts) in addition to the
  keyboard's dictation key.

## Left to the builder

Exact spacing and animation curves, the palette panel's look, the ANSI colour values (pick for
legibility of Claude's diff colours in both themes), and how `TerminalScreen` is split.
Keep the existing behaviour comments with the moved code.
