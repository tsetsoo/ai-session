# iOS Live Activities & Dynamic Island Implementation Plan

> **Goal:** Ambient visibility on iPhone Lock Screen & Dynamic Island for background AI agent sessions, with 1-tap interactive approvals via Hub relay.
> **Spec:** [docs/superpowers/specs/2026-11-24-live-activities-design.md](file:///Users/tsvetelinpantev/.ai-remote/worktrees/89fdb36c-131c-4bbb-ac83-d8bfbc3c8a10/e2d323b2-cf3e-4309-953b-06c2438e94c0/docs/superpowers/specs/2026-11-24-live-activities-design.md)

---

## Stages

### Stage 1: Hub & Host Approval Transport
1. **Server DB & Endpoints (`todo-server`)**:
   - Add SQLite table or in-memory queue for `pending_approvals (conversation_id, tool, key, created_at)`.
   - `POST /api/conversations/{id}/approve`: Enqueues an approval for `conversation_id`.
   - `GET /api/runner/approvals?computer_id={id}`: Returns and clears pending approvals for conversations running on that computer.
   - Add tests in `todo-server/src/handlers.rs` or `runner_api.rs`.
2. **Host Script Integration (`ai_todo_status.py`)**:
   - In `ai_todo_status.py`, while any local session is in `waiting` state, query `/api/runner/approvals`.
   - On approval received: dispatch keystroke via `tmux send-keys` (`'1' C-m` for Claude, `'y'` for Codex).
   - Add tests in `scripts/todo/test-status.py`.

### Stage 2: Shared ActivityKit Models & Client (`AISessionCore`)
1. **Attributes & State (`Sources/AISessionCore/LiveActivity/AgentSessionAttributes.swift`)**:
   - `AgentSessionAttributes: ActivityAttributes` with `ContentState` (`status`, `currentStep`, `promptQuestion`, `isWaiting`, `finishedMessage`, `updatedAt`).
2. **Client API (`Sources/AISessionCore/TodoHub/TodoHubClient.swift`)**:
   - Add `approveConversation(id: String) async throws`.

### Stage 3: Widget Extension Target & Views (`AISessionWidget`)
1. **Project Configuration (`project.yml`)**:
   - Add `AISessionWidget` target (`type: app-extension`, `platform: iOS`).
   - Add `NSSupportsLiveActivities: true` to `AISessionRemote/Info.plist`.
   - Add shared App Group (or shared Keychain/UserDefaults) for hub credentials access from the widget extension.
2. **Live Activity View (`App/AISessionWidget/AgentLiveActivityView.swift`)**:
   - Lock screen banner layout with live timer, tool badge, current step, and prompt banner.
   - Dynamic Island (Compact leading/trailing, minimal, expanded).
   - Interactive `Button(intent: ApprovePromptIntent(...))` using `LiveActivityIntent`.

### Stage 4: App State Coordinator (`AISessionRemote`)
1. **`LiveActivityManager.swift`**:
   - Observes active conversations in `AppModel`.
   - Starts Live Activity when entering `busy` or backgrounding.
   - Updates `ContentState` on step changes or entering `waiting`.
   - Ends activity on `idle` / `done`.
2. **Verification**:
   - `cargo test` in `todo-app/`.
   - `scripts/todo/test-todo-scripts.sh` for host scripts.
   - `xcodegen generate` and Swift compilation.
