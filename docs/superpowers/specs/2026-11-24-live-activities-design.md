# iOS Live Activities & Dynamic Island for AI Sessions

Status: approved 2026-11-24
Date: 2026-11-24

## Why

When the user gives an agent a task (a multi-step code refactor, running test suites, or research) and puts their phone down or steps away from their desk, they currently have no ambient visibility into what the agent is doing until:
1. It completes, or
2. It hits a blocking question / permission prompt ("Needs you").

Even when a "Needs you" push notification arrives, the user must unlock their phone, wait for the app to open and re-establish SSH/terminal connections, and tap the prompt button.

With Apple's **ActivityKit (Live Activities & Dynamic Island)**, an active agent turn is visible directly on the iPhone Lock Screen, Always-On Display, and Dynamic Island. More importantly, when the agent hits a permission prompt, **interactive buttons on the lock screen allow 1-tap approval** without unlocking the phone or switching contexts.

---

## Goals

1. **Ambient Awareness on Lock Screen & Always-On Display:**
   - Display active task title, agent name, model (e.g. Claude 3.5 Sonnet / Codex), and elapsed time (using system `Text(timerInterval:)` for zero-battery continuous counting).
   - Show the current step summary (`"▸ Reading auth/jwt.rs"`, `"▸ Running cargo test"`, `"▸ Waiting for permission"`).
2. **Dynamic Island Integration:**
   - **Compact leading/trailing:** Agent tool icon + live status glyph (`…` busy spinner or `!` warning).
   - **Expanded Dynamic Island:** Full task title, elapsed time, current tool step, and action button if waiting.
3. **Interactive Lock-Screen Approvals:**
   - When a conversation moves to `waiting` with a known prompt (e.g. *"Allow running `cargo test`?"*), the Live Activity renders interactive action buttons (**Allow**, **Deny**) using iOS 17 `LiveActivityIntent`.
   - Tapping **Allow** immediately triggers an AppIntent that calls the Todo Hub server.
4. **Approval Transport (Hub API Relay):**
   - The lock-screen AppIntent sends `POST /api/conversations/{id}/permission-decision` to the Todo Hub.
   - The host daemon (`ai_todo_status.py`) fetches the pending approval on its fast-loop and delivers the keystroke to tmux (`tmux send-keys`).
   - This avoids holding flaky background SSH connections from a locked iPhone.
5. **Clean Lifecycle & Zero Battery Waste:**
   - Starts as the iOS app leaves the foreground with a conversation in progress.
   - Automatically updates when state transitions occur (`busy` ➔ `waiting` ➔ `idle`).
   - Automatically finishes when the task is `done` with a brief success confirmation (`"✓ Finished in 3m 42s"`), dismissing after a few seconds.

---

## Non-goals & Anti-goals

- **Non-goals:**
  - Streaming raw terminal ANSI characters or full diffs into the Live Activity widget (WidgetKit views cannot render interactive terminal emulators).
  - Answering free-text prompts directly inside the widget (free text prompts require opening the app's chat composer).
  - Mac app widget (macOS has no Dynamic Island or Live Activities; Mac attention signals and menu bar are handled separately).
- **Anti-goals:**
  - Stale Live Activities left on the lock screen forever after a task is completed.
  - Sending an approval to a prompt that has changed or expired.
  - Waking up the phone's CPU continuously for polling: elapsed time must use native SwiftUI timer intervals, not per-second push payloads.

---

## Design & UI Specifications

### 1. Dynamic Island Layouts

```
[ Compact Mode ]
( 🤖 )                       ( ⏳ 02:14 )
  Leading                      Trailing

[ Expanded Mode ]
+-------------------------------------------------------------+
| 🤖 Claude (Sonnet) · auth-refactor              02:14       |
| "Allow running `cargo test --all`?"                         |
|                                                             |
| [ Dismiss ]                            [ ✓ Allow & Run ]    |
+-------------------------------------------------------------+
```

* **Compact Leading:** App/Tool icon (`claude`, `codex`, or terminal glyph) with animated pulse dot if busy, amber accent if waiting.
* **Compact Trailing:** System timer countdown/countup or `✓` upon completion.
* **Expanded:**
  - Header: Tool name, model badge, project/todo title.
  - Body: Current activity text (`"Edited src/auth.rs · running tests"` or prompt question).
  - Bottom controls: If `waiting`, shows **Allow** button (accent colored) and **Deny** button.

### 2. Lock Screen Banner Layout

```
+-------------------------------------------------------------+
| 🤖 Claude (Sonnet) · API Hub                     ⏳ 03:45    |
| Fix JWT token refresh expiration                            |
|                                                             |
| ⚠️ Needs Permission:                                        |
| "Allow command: `cargo test --package todo-server`?"        |
|                                                             |
| [ Reject ]                             [ ✓ Allow & Resume ] |
+-------------------------------------------------------------+
```

* Top Row: Tool icon, model name, project name, live system timer.
* Middle: Todo title + latest activity step / prompt question.
* Bottom:
  - When `busy`: A subtle progress bar or step counter ("Step 4 of 6").
  - When `waiting`: Interactive **Allow** button (primary accent) and **Reject** button.
  - When `done`: Green checkmark banner `"Turn complete · Ready for review"`.

---

## Architecture

### 1. Data Contract (`Sources/AISessionCore/LiveActivity/`)
- `AgentSessionAttributes: ActivityAttributes`:
  - `ContentState`: `status` ("busy" | "waiting" | "idle"), `currentStep`, `promptQuestion`, `isWaiting`, `finishedMessage`, `updatedAt`.
  - Static attributes: `todoId`, `conversationId`, `todoTitle`, `tool`, `model`, `projectName`, `startedAt`.

### 2. Hub Approval Endpoint

- The app sends `POST /api/conversations/{id}/permission-decision` with the displayed status revision and the Allow or Reject decision. The Hub accepts decisions for identifiable permission prompts. A decision can be claimed for 45 seconds. The claim gets its own 10-second delivery window.
- The host calls `POST /api/conversations/approve` to claim a decision for the current tool and session. A computer-scoped helper token can claim decisions only for its computer.

### 3. Host Dispatcher

- The daemon requires the same tool prompt ID in its latest local state before delivering a decision to the recorded tmux pane. It acknowledges delivery or releases the reservation when delivery fails. Ambiguous delivery opens a path to check the conversation without automatically resending the key.
- Allow sends `1` followed by Enter for Claude or `y` for Codex. Reject sends Escape.

### 4. Lifecycle and Background Updates

- The iOS app requests the activity as it leaves the foreground with a conversation in progress. Tapping the activity opens that conversation.
- The app registers the ActivityKit update token with the Hub. The Hub uses its existing APNs configuration to send updates and end the activity as the conversation changes.
- Allow and Reject require local device authentication. The intent runs in the app process and uses the configured Hub credentials from the Keychain.

### 5. Hands-Free Chat

- The waveform control in iOS Chat turns on Voice Mode. End the dictated message with “Voice send now.” To send a draft already on screen, say “Send message.” Say “Discard message” to clear the draft or “Stop voice mode” to leave the mode.
- Voice Mode reads new agent replies aloud and resumes listening after playback. It pauses while the agent is working or a permission prompt is open, and stops when the chat loses the foreground.
