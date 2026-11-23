# Mac attention signals: sound, pulse, banner, Dock badge

Status: approved 2026-11-23 (short design: small feature, Mac app only).

## Why

The user missed conversations that moved to **Needs you** or **Ready for review**. Claude's
"jobs done" Stop hook sound has been removed from both Macs (it played on whichever computer
ran the agent, not where the user sits). The Mac app should signal instead. The Mac is muted in
the office and audible at home, so sounds follow the system volume and no schedule is needed.

## Goals

- When a conversation **enters** Needs you or Ready for review on the Mac app:
  - play a sound: a soft single note for Ready for review, a brighter, more urgent two-note
    chime for Needs you;
  - pulse that conversation's sidebar row (and the section header) a few times;
  - if the app is not frontmost (another app, or window hidden/minimised), post a banner.
- Dock badge = number of conversations in Needs you.

## Non-goals / anti-goals

- No iPhone changes; server push stays as it is.
- No server changes.
- No signal for the conversation the user is already looking at in the active app.
- No repeats: one signal per entry into a section (a new turn that ends again may signal again).
- No sound on launch / first load / reconnect baseline.
- Anti-goal: anything that plays sound on a remote host, or ignores the Mac's mute.

## Approaches

1. **Mac app reacts to its own section changes** — chosen. The app already gets live status by
   websocket and computes sections in `ConversationBoard`. Plays sound locally (respects
   mute), can pulse rows, no server work.
2. Hub pushes to the Mac via APNs — needs Mac push/signing work, can't pulse in-app anyway.
3. Per-host hook sound (old `afplay`) — rejected: sounds on the agent's computer.

## Design

- **Detection:** after each store refresh (`AppModel` `store.onRefresh`, next to
  `alertNewlyWaiting`), compare the todo ids in `board.needsYou` and `board.review` with the
  previous refresh. New ids in a section are "arrivals". Baseline refreshes record without
  signalling. A conversation going Needs you → Ready for review counts as a review arrival.
  Several arrivals in one refresh: one sound (Needs you wins), one pulse per row, banners per
  conversation (existing `todo-<id>` identifier so a newer one replaces older).
- **Suppression:** skip the arrival entirely when it is the conversation on screen in the active
  app (`visibleTodoId`).
- **Sound:** two short sounds bundled in the app (generated, original), played with `NSSound`
  so it follows the system volume/mute. Settings: per kind, pick bundled default, a macOS system
  sound, or None.
- **Pulse:** the arriving row gets an accent-coloured background pulse (~3 pulses, ~2 s, orange
  for Needs you, the review tint for Ready for review); the section header count pulses once.
  Respects Reduce Motion (a static highlight that fades instead).
- **Banner:** only when the app isn't frontmost. Title = todo title, body "Needs you" or
  "Ready for review" (never conversation text). No banner sound (the app plays its own sound,
  so it isn't doubled). Tapping opens the conversation (existing routing). This replaces the
  Mac's current `postWaiting` rule that skipped local alerts when an iPhone was registered; the
  "Alert on this Mac too" toggle goes away on Mac.
- **Dock badge:** `NSApp.dockTile.badgeLabel` = Needs you count, empty when 0.
- **Settings (Mac, Notifications):** sound per kind (picker + preview button), "Show banners
  when the app is in the background", "Badge the Dock icon". All on by default.

## Left to the builder

- Exact pulse timing/colours, sound synthesis (keep each under ~1 s, pleasant, not a system
  sound clone), and where the arrival-diff helper lives (a pure function in `AISessionCore`
  next to `StatusTransitions`, with tests).
