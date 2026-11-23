# Mac Attention Signals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a conversation enters Needs you or To review, the Mac app plays a sound (urgent for Needs you), pulses the row and sidebar section, posts a silent banner if the app isn't active, and badges the Dock with the Needs you count.

**Architecture:** `AppModel.alertNewlyWaiting` becomes `announceArrivals`: it diffs raw statuses (existing `StatusTransitions`) plus a new "newly finished" diff filtered by `board.review`, then per arrival posts through `WaitingAlerts` (now carrying a kind), plays one sound, and bumps pulse serials the views animate on. Mac-only pieces (sound player, Dock badge, banner rule, settings) live in the app target.

**Tech Stack:** Swift 6 / SwiftUI, AISessionCore package (XCTest via `swift test`), app tests via `xcodebuild`, `NSSound`, `UNUserNotificationCenter`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-23-mac-attention-signals-design.md`

## Global Constraints

- Banner copy: title = todo title, body exactly `Needs you` or `Ready for review`; never conversation text.
- No signal (sound, banner, pulse) for an arrival whose todo is `visibleTodoId` in the active app; that case keeps today's `feedback()` call.
- Baseline refreshes (`Fetched.isBaseline`) never signal.
- One sound per refresh; Needs you wins over review. Player throttles to one sound per 1.5 s.
- Mac banners: `content.sound = nil`, identifier `NotificationPolicy.notificationIdentifier(todoId:)`, only when `!NSApp.isActive`.
- iPhone behaviour unchanged: review arrivals are ignored on iOS; Needs you keeps `postWaiting`.
- UserDefaults keys (all Mac): `attention.sound.needsYou`, `attention.sound.review` (values `"default"`, `"none"`, or a system sound name; default `"default"`), `attention.banners` (default true), `attention.dockBadge` (default true).
- Bundled sounds: `App/AISessionRemote/Resources/Sounds/attention-needs-you.caf`, `attention-review.caf`, each < 1 s, original synthesis.
- Keep signing team 233QTK6KCL; install only with `scripts/rebuild-mac-app.sh`.

## Review Focus

- Launch / reconnect with conversations already idle or waiting → no sound (baseline). Test in Task 2.
- Conversation goes waiting → idle (user answered the prompt in a terminal, turn finished) → counts as a review arrival. Test in Task 1.
- Todo marked done, or conversation already reviewed, finishing → not in `board.review` → no review signal. Test in Task 2.
- Two arrivals in one refresh (one needs-you, one review) → exactly one sound call, kind `.needsYou`. Test in Task 2.
- Notifications toggle off → banners off but sound and pulse still happen on Mac. Test in Task 2.

---

### Task 1: Core "newly finished" transition

**Files:**
- Modify: `Sources/AISessionCore/Board/StatusTransitions.swift`
- Test: `Tests/AISessionCoreTests/BoardTests.swift` (next to the `newlyWaiting` tests, ~line 416)

**Interfaces:**
- Produces: `StatusTransitions.newlyFinished(previous: [String: ConversationStatus]?, current: [Conversation]) -> [Conversation]` — conversations now `.idle` whose previous status was `.busy` or `.waiting`; `previous == nil` → `[]`; missing previous entry → not included.

- [ ] **Step 1: Write failing tests** `testNewlyFinishedNeedsABaseline` (`previous: nil` → `[]`), `testNewlyFinishedFromBusyOrWaiting` (prev `["a": .busy, "b": .waiting, "c": .idle]`, current a,b,c idle, d idle new → `[a, b]`), `testNewlyFinishedIgnoresOtherStatuses` (prev `["a": .busy]`, current a `.waiting` → `[]`).
- [ ] **Step 2:** `swift test --filter BoardTests` → FAIL (no member `newlyFinished`).
- [ ] **Step 3:** Implement with a doc comment mirroring `newlyWaiting`.
- [ ] **Step 4:** `swift test --filter BoardTests` → PASS.
- [ ] **Step 5:** Commit `Detect conversations that just finished a turn`.

### Task 2: AppModel announces arrivals (kind, sound, pulses)

**Files:**
- Modify: `App/AISessionRemote/Services/AppModel.swift` (`WaitingAlert`, `WaitingAlerts`, `alertNewlyWaiting` ~333)
- Test: `App/AISessionRemoteTests/AppModelTests.swift` ("Needs you" alerts section ~595)

**Interfaces:**
- Produces:
  - `enum AttentionKind: Equatable { case needsYou, review }` (AppModel.swift, top level).
  - `WaitingAlert` gains `let kind: AttentionKind`; body `"Needs you"` / `"Ready for review"`.
  - `WaitingAlerts` gains `var sound: (AttentionKind) -> Void`; `isEnabled` now gates only `post`.
  - `AppModel.rowPulses: [String: Int]` (todoId → serial, observable) and `AppModel.sectionPulses: [AttentionKind: Int]`; each arrival increments its todo's serial and its section's serial.
- `.live`: `post` → `NotificationCenterCoordinator.shared.postAttention(alert)` (Task 3); `sound` → `AttentionSound.play(kind)` (Task 4).

- [ ] **Step 1: Update `AlertRecorder`** with `var sounds: [AttentionKind] = []` and fix existing asserts (`assertNoConversationText` accepts either body).
- [ ] **Step 2: Write failing tests:**
  - `testReviewArrivalWhenATurnFinishes`: fetch t1 `.busy` twice (baseline + one), then t1 `.idle` → `posted.map(\.kind) == [.review]`, body `"Ready for review"`, `sounds == [.review]`, `rowPulses["t1"] == 1`, `sectionPulses[.review] == 1`.
  - `testBaselineNeverSignals`: first fetch with t1 `.waiting`, t3 `.idle` → `posted`, `sounds`, `rowPulses` empty.
  - `testOneSoundPerRefreshNeedsYouWins`: from busy/busy, t1 → `.waiting`, t3 → `.idle` in one fetch → `sounds == [.needsYou]`, two posts.
  - `testFrontmostArrivalOnlyBuzzes`: `frontmost = "t1"`, t1 busy → waiting → `feedbacks == 1`, no post, no sound, no pulse.
  - `testDisabledStillSoundsAndPulses`: `enabled = false`, t1 busy → waiting → `posted` empty, `sounds == [.needsYou]`, `rowPulses["t1"] == 1`. (On iOS `sound` is a no-op, so this is Mac-visible only.)
  - `testCompletedTodoFinishingIsNotReview`: mark t1's todo completed in fetched todos, busy → idle → no `.review` post/sound.
- [ ] **Step 3:** `xcodebuild -scheme AISessionRemoteMac -derivedDataPath <scratchpad>/dd CODE_SIGNING_ALLOWED=NO test -only-testing:AISessionRemoteMacTests/AppModelTests` → FAIL (compile). (Use the actual test target name from `project.yml`.)
- [ ] **Step 4: Implement `announceArrivals(_:)`** replacing `alertNewlyWaiting`: needs-you = `newlyWaiting`; review = `newlyFinished` ∩ `board.review` todo ids (read `board` after the store applied the fetch); drop frontmost (→ `feedback()`); for the rest bump pulses, `post` if `isEnabled()`, then one `sound` call (`.needsYou` if any needs-you arrival else `.review`).
- [ ] **Step 5:** Run the same test command → PASS, plus the full app test suite.
- [ ] **Step 6:** Commit `Announce review arrivals with a kind, a sound and a pulse`.

### Task 3: Coordinator banner rule per platform

**Files:**
- Modify: `App/AISessionRemote/Services/Notifications/NotificationCenterCoordinator.swift`
- Modify: `App/AISessionRemote/Views/Notifications/NotificationSettingsView.swift` (remove Mac "Alert on this Mac too" toggle and its footer)

**Interfaces:**
- Consumes: `WaitingAlert` with `kind` (Task 2).
- Produces: `func postAttention(_ alert: WaitingAlert)`. iOS: `.needsYou` → existing `postWaiting(...)`; `.review` → return. macOS: guard `isEnabled`, `UserDefaults` `attention.banners` (default true via `object(forKey:) as? Bool ?? true`), `!NSApplication.shared.isActive`; post content title/body from alert, `sound = nil`, `threadIdentifier = todoId`, category `Self.category`, userInfo `kind` = `"waiting"` or `"review"`. `macAlertsTooKey` and its use in `shouldPostLocal` become iOS-irrelevant: delete the key and pass `macAlertsToo: false` only if the policy signature still needs it; otherwise drop the parameter and update `PushStateTests`/policy tests accordingly.

- [ ] **Step 1:** Implement `postAttention`; route Mac's old `postWaiting` path through it (Mac no longer calls `shouldPostLocal`).
- [ ] **Step 2:** Remove the Mac toggle/footer; fix the doc comment at the top of the settings view.
- [ ] **Step 3:** `swift test` and the app test suite → PASS.
- [ ] **Step 4:** Commit `Mac banners for arrivals while the app is in the background`.

### Task 4: Sounds and player

**Files:**
- Create: `App/AISessionRemote/Resources/Sounds/attention-needs-you.caf`, `attention-review.caf`
- Create: `scripts/make-attention-sounds.py` (generates the two files; kept for re-tuning)
- Create: `App/AISessionRemote/Platform/AttentionSound.swift`

**Interfaces:**
- Produces: `enum AttentionSound { static let systemNames: [String]; static func play(_ kind: AttentionKind); static func preview(_ choice: String) }` — macOS only bodies, iOS no-ops. `systemNames` = `["Basso","Blow","Bottle","Frog","Funk","Glass","Hero","Morse","Ping","Pop","Purr","Sosumi","Submarine","Tink"]`. Choice resolution: `"none"` → silent, `"default"` → bundled caf for the kind, else `NSSound(named:)`. Throttle 1.5 s between plays.

- [ ] **Step 1:** Write the generator (stdlib `wave` + `math`, then `afconvert -f caff -d LEI16`). Review sound: one soft bell partial stack around 880 Hz, ~0.5 s exponential decay. Needs you: two notes (e.g. 988 Hz then 1319 Hz, 120 ms apart), brighter attack, ~0.8 s total. Peak ≤ -6 dBFS, 10 ms fade-in.
- [ ] **Step 2:** Run it; `afinfo` both files → duration < 1 s; `afplay` each once to listen.
- [ ] **Step 3:** Implement `AttentionSound`.
- [ ] **Step 4:** `xcodegen generate` and build the Mac scheme; confirm both `.caf` files are in the built app's `Contents/Resources`.
- [ ] **Step 5:** Commit `Bundle attention sounds and a player that follows the Mac's volume`.

### Task 5: Pulses, Dock badge, settings UI

**Files:**
- Create: `App/AISessionRemote/Views/Components/AttentionPulse.swift` (put it where other view modifiers live)
- Modify: `App/AISessionRemote/Views/Lists/ConversationListView.swift` (`row(...)` ~168), `App/AISessionRemote/Views/Lists/ConversationRow.swift`
- Modify: `App/AISessionRemote/Views/Shell/SidebarView.swift` (`SidebarRow` ~148, Needs you / To review rows ~33)
- Modify: `App/AISessionRemote/Views/Shell/MacShell.swift` (Dock badge)
- Modify: `App/AISessionRemote/Views/Notifications/NotificationSettingsView.swift` (Mac "On this Mac" section)

**Interfaces:**
- Consumes: `AppModel.rowPulses`, `AppModel.sectionPulses`, `AttentionKind`, `AttentionSound.systemNames/preview` (Tasks 2, 4).
- Produces: `extension View { func attentionPulse(serial: Int?, tint: Color) -> some View }` — on change of `serial` (not on appear) animates a tinted rounded background 0 → 0.35 opacity three times over ~2 s then clears; with `accessibilityReduceMotion` a single fade-out instead. Tint: `DS.accent` for Needs you; the existing review tint (use `ConversationDisplayStatus.idle`'s colour) for review.

- [ ] **Step 1:** Modifier + apply to each conversation row (tint from `board.status(of:)`: `.needsYou` → accent, else review tint) and to the Needs you / To review `SidebarRow`s with `sectionPulses`.
- [ ] **Step 2:** Dock badge in `MacShell`: `.onChange(of: model.board.needsYou.count, initial: true)` → `NSApp.dockTile.badgeLabel = (enabled && count > 0) ? "\(count)" : nil`, also re-applied when `attention.dockBadge` changes (`@AppStorage`).
- [ ] **Step 3:** Settings (macOS only) section "On this Mac": `Picker("Needs you sound")` and `Picker("Ready for review sound")` over `"default"` ("Chime"), system names, `"none"` ("None"), each with a play button calling `AttentionSound.preview`; `Toggle("Show banners when the app is in the background")`, `Toggle("Badge the Dock icon")`. Footer: "Sounds follow the Mac's volume, so a muted Mac stays silent."
- [ ] **Step 4:** Build the Mac scheme; run full app tests and `swift test` → PASS.
- [ ] **Step 5:** Commit `Pulse arriving rows, badge the Dock, Mac attention settings`.

### Task 6: Hand check and install

- [ ] **Step 1:** `scripts/rebuild-mac-app.sh` (rebase on `origin/main` first if it refuses).
- [ ] **Step 2:** In the running app, trigger a review arrival (short Claude turn in any conversation, app in front on another conversation): hear the review sound, see row + "To review" pulse. Switch to another app, trigger a permission prompt: hear the Needs you chime, see the silent banner, Dock badge shows 1.
- [ ] **Step 3:** Update the memory file for this feature; report results.
