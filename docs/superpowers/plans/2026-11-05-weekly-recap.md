# Weekly Recap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Monday morning, a Weekly section on the Mac and iPhone shows last week as wins: totals, a per-project section written by that project's computer, and what the scheduled jobs did.

**Architecture:** The hub (Rust, schema v21) keeps per-week job tallies as runs settle and snapshots each finished week's jobs block. It offers each project's computer a "weekly" work item once Sunday is covered. The runner (`ai_todo_updates.py`) writes the headline and wins with the same model path as daily updates and PUTs them. The apps read one list endpoint.

**Tech Stack:** Rust (actix-web, rusqlite, chrono-tz), Python 3 stdlib, Swift/SwiftUI (AISessionCore package and app).

**Spec:** `docs/superpowers/specs/2026-11-05-weekly-recap-design.md` (builds on `2026-11-04-daily-updates-design.md`).

## Global Constraints

- Week = Mon 08:00 → Mon 08:00 Europe/Sofia; key `week` = the Monday's date `YYYY-MM-DD`; its days are `week`..`week+6` (daily-update day keys).
- A week is ready for a project when Sunday (`week+6`) has a `project_updates` row with `rewrite_requested = 0 AND stale = 0`, or now ≥ `week+7` 10:00 Sofia.
- Hub makes no model calls. Each project's section is written only by that project's computer (`section_computers`).
- Recaps and job snapshots are never deleted (not in `cleanup_db`).
- Watcher jobs (`json_extract(action,'$.kind') = 'watch'`): quiet (`result = 'quiet'`) and skipped runs count as **checks**, not runs.
- Auto-rewrite on a late daily update only until `week+14` (7 days after the week ends).
- Runner model path, headroom rule, `MAX_FAILURES = 3`, redaction: identical to daily-update writing.
- Wins are second person, 3–5 bullets, no "next/open/blocked"; headline ≤ 120 chars.
- Clippy `-D warnings`; Python stdlib only; the apps' refresh-call count test must not grow (Weekly loads only when its view opens).
- No push, no Copy button.

## Review Focus

1. A week where Sunday was a quiet day (row with empty text) must be ready at ~08:15, not wait for 10:00. Covered in Task 3 (`weekly_ready_when_sunday_quiet`).
2. A project switched on mid-week (`daily_updates_since` = Wednesday): Mon/Tue are `untracked`, never `missing`. Covered in Task 3 (`days_before_since_are_untracked`).
3. A watcher's quiet runs pruned after 2 days must still be counted as checks for the week. Covered in Task 2 (`tally_survives_watch_prune`).
4. Deleting a job mid-week keeps its runs in that week's tallies. Covered in Task 2 (`delete_job_tallies_first`).
5. A daily update rewritten after the recap was written marks the recap stale, but not a month later. Covered in Task 3 (`late_daily_marks_recap_stale`, `old_week_not_marked_stale`).

---

### Task 1: Hub schema v21 and week helpers

**Files:**
- Create: `todo-app/crates/todo-server/src/weekly.rs` (module `weekly`, add `mod weekly;` in `main.rs`)
- Modify: `todo-app/crates/todo-server/src/db.rs` (`SCHEMA_VERSION = 21`, `create_v21_objects`, call it after v20 in pool setup and in `migrate`)

**Interfaces:**
- Produces (in `weekly.rs`):
  - `pub(crate) fn week_of_day(day: &str) -> Option<String>`: the Monday of the day's week.
  - `pub(crate) fn week_days(week: &str) -> Option<Vec<String>>`: 7 days.
  - `pub(crate) fn week_of_time(t: DateTime<Utc>) -> String`: the week of the daily-update day containing `t` (shift −8 h in Sofia, then the Monday).
  - `pub(crate) fn last_finished_week(now: DateTime<Utc>) -> Option<String>`: the most recent week whose end (`week+7` 08:00 Sofia) ≤ now.
  - `pub(crate) fn week_fallback(week: &str) -> Option<DateTime<Utc>>`: `week+7` 10:00 Sofia.
- Tables (v21):
  - `job_runs` gains `tallied INTEGER NOT NULL DEFAULT 0`.
  - `weekly_job_tallies(week, job_id, job_name, project_name, is_watch INTEGER, runs, done, failed, skipped, checks, findings, todos_created, conversations_started, PRIMARY KEY(week, job_id))`; counters are `INTEGER NOT NULL DEFAULT 0`.
  - `weekly_jobs(week TEXT PRIMARY KEY, snapshot TEXT NOT NULL, taken_at TEXT NOT NULL)`.
  - `weekly_recaps(week, project_id, project_name TEXT NOT NULL DEFAULT '', headline TEXT NOT NULL DEFAULT '', wins TEXT NOT NULL DEFAULT '', failed INTEGER NOT NULL DEFAULT 0, days TEXT NOT NULL DEFAULT '[]', commits, conversations, days_with_work INTEGER NOT NULL DEFAULT 0, written_at TEXT NOT NULL, rewrite_requested, stale INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(week, project_id))`.
  - On first migration to v21, mark every already-settled run `tallied = 1` except those with `due_at` in the current week. Those get tallied by Task 2, so the current week starts complete for what still exists.

- [ ] **Step 1: Write failing tests in `weekly.rs`**: `week_of_day("2026-11-08") == "2026-11-02"`, `week_of_day("2026-11-09") == "2026-11-09"`; `week_of_time(2026-11-09 05:59Z) == "2026-11-02"` (07:59 Sofia, EET), `week_of_time(2026-11-09 06:00Z) == "2026-11-09"`; `last_finished_week(2026-11-09 06:00Z) == Some("2026-11-02")`, `last_finished_week(2026-11-09 05:59Z) == Some("2026-10-26")`; `week_fallback("2026-11-02") == 2026-11-09 08:00Z`. In `db.rs`: `migrates_to_v21` asserts the three tables and `job_runs.tallied` exist and `user_version == 21`.
- [ ] **Step 2: Run** `cd todo-app && cargo test -p todo-server weekly` and `cargo test -p todo-server migrates_to_v21`. Expected: FAIL (module and tables missing).
- [ ] **Step 3: Implement** the helpers, reusing `updates::day_window` and `crate::updates::TZ` for Sofia. Implement `create_v21_objects` with `column_exists` guarding the `ALTER`.
- [ ] **Step 4: Run** the same tests, then `cargo test -p todo-server`. Expected: all PASS.
- [ ] **Step 5: Commit** `feat(hub): v21 weekly recap tables and week helpers`.

### Task 2: Job tallies and the weekly jobs snapshot

**Files:**
- Modify: `todo-app/crates/todo-server/src/weekly.rs`, `scheduler.rs` (`tick_db`), `jobs.rs` (`delete_job`)

**Interfaces:**
- Consumes: Task 1 helpers and tables.
- Produces:
  - `pub(crate) fn tally_settled_runs(conn: &Connection) -> rusqlite::Result<usize>` adds each run with `state IN ('done','failed','skipped','missed') AND tallied = 0` to `weekly_job_tallies` for `week_of_time(due_at)`, then sets `tallied = 1`. It upserts and refreshes `job_name` and `project_name` (from `json_extract(action,'$.project_id')` → `projects.name`, else `''`).
    - Counting rule: for watch jobs, `result = 'quiet'` or `skipped` → `checks += 1`. Other watch runs → `runs += 1`, plus `done`, `failed` or `skipped`, and `findings += N` when `result` matches `^(\d+) new`.
    - For other jobs, `missed` counts as failed. `todos_created += 1` when `todo_id` is set. `conversations_started += 1` when `result` starts with `started `.
  - `pub(crate) fn snapshot_finished_weeks(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize>` runs for `last_finished_week(now)` only when now ≥ `week_fallback`. When there's no `weekly_jobs` row, it calls `tally_settled_runs`, builds `WeeklyJobs` (Task 4 type, in `todo_shared`) from the tallies plus the week's still-present non-quiet runs as lines, and inserts it.
    - Line order: failed first, then runs whose todo is open (`todos.completed = 0`), then newest first.
    - `outcome` = the todo title if there is one, else `result`.
  - `pub(crate) fn live_jobs(conn: &Connection, week: &str) -> rusqlite::Result<WeeklyJobs>` is the same builder, used by the snapshot.
- In `tick_db`, call `tally_settled_runs` **before** `watch_upkeep`, then `snapshot_finished_weeks`. In `delete_job`, call `tally_settled_runs` before the `DELETE`.

- [ ] **Step 1: Write failing tests:**
  - `tally_counts_runs_by_week`: 2 done (1 with `todo_id`), 1 failed and 1 missed for a todo job in week 2026-11-02 → runs 4, done 2, failed 2, todos_created 1.
  - `tally_watch_checks_and_findings`: quiet ×3, `"2 new"` ×1, failed ×1 → checks 3, runs 2, findings 2, failed 1.
  - `tally_survives_watch_prune`: tally, then run `watch_upkeep` at +3 days → runs deleted, tallies unchanged; second tally adds nothing.
  - `delete_job_tallies_first`: delete a job via the handler → tally row keeps `job_name`.
  - `snapshot_once_after_fallback`: no snapshot at 2026-11-09 07:59Z; one at 08:00Z with lines ordered failed → open todo → rest; a second call doesn't change `taken_at`.
- [ ] **Step 2: Run** `cargo test -p todo-server weekly`. Expected: FAIL.
- [ ] **Step 3: Implement** the three functions and the two call sites.
- [ ] **Step 4: Run** `cargo test -p todo-server`. Expected: PASS (existing scheduler and watch tests still pass).
- [ ] **Step 5: Commit** `feat(hub): weekly job tallies survive pruning; finished weeks snapshotted`.

### Task 3: Runner work, PUT, rewrite and stale for weekly sections

**Files:**
- Modify: `weekly.rs`, `updates.rs` (`RunnerWork`, `runner_db`, `put_update_db`), `main.rs` (routes)

**Interfaces:**
- Consumes: Task 1; `updates::on_projects`, `waiting_on`, `expected_computers` (make `pub(crate)` as needed).
- Produces:
  - `RunnerWork` gains `pub weekly: Vec<WeeklyItem>` (`#[serde(default)]`-safe for old runners).
  - `WeeklyItem { project_id, project_name, week, style, days: Vec<WeeklyDay> }`.
  - `WeeklyDay { day, state, text, summaries: Vec<WeeklyDaySummary{title, summary}> }`, where `state ∈ "update" | "quiet" | "failed" | "missing" | "untracked"`. `text` is set only for `update`. `summaries` are set only for `failed` and `missing` (`update_summaries` with `failed = 0`).
    - Day state: `untracked` if day < `daily_updates_since`; else a row with empty text → `quiet`; text starting `"_This update couldn't be written"` → `failed` (hub const `WRITE_FAILED_PREFIX`); other text → `update`; no row → `missing`.
  - `pub(crate) fn weekly_items(conn, computer_id, now) -> rusqlite::Result<Vec<WeeklyItem>>` offers, for this computer's projects:
    - The last finished week when it's ready (Global Constraints), has no `weekly_recaps` row, and has ≥1 `update` or `failed` day.
    - Any week with `rewrite_requested = 1 OR stale = 1`.
  - `PUT /api/projects/{id}/weekly/{week}` takes `{ headline: String, wins: String, failed: bool }`. The hub computes and stores:
    - `days` as JSON `[{day, state}]`, `commits` = Σ `project_updates.commits` over the week, `days_with_work` = count of `update` days.
    - `conversations` = `COUNT(DISTINCT tool || ':' || session_id)` in `update_summaries` for the project and the 7 days.
    - Clears rewrite and stale. 400 on a bad week or headline > 200 chars; 404 for an unknown project.
  - `POST /api/projects/{id}/weekly/{week}/rewrite` sets `rewrite_requested = 1`, or returns 404.
  - In `put_update_db`, after the upsert: `UPDATE weekly_recaps SET stale = 1 WHERE project_id = ? AND week = week_of_day(day) AND now < week_fallback(week) + 7 days`.

- [ ] **Step 1: Write failing tests:**
  - `weekly_not_offered_before_ready`: at 2026-11-09 06:05Z with no Sunday row → none.
  - `weekly_ready_when_sunday_quiet`: Sunday row with `text = ''` → offered at 06:05Z.
  - `weekly_offered_at_fallback` at 08:00Z without Sunday.
  - `days_before_since_are_untracked`: since = 2026-11-04 → Mon/Tue `untracked`, Wed `update`, Thu with no row `missing` with its summaries.
  - `failed_day_carries_summaries`.
  - `not_offered_to_other_computer`.
  - `put_weekly_computes_counts`: one session on 2 days counts as 1 conversation; commits summed; `days_with_work`.
  - `late_daily_marks_recap_stale`.
  - `old_week_not_marked_stale`: a PUT daily at `week+15`.
  - `rewrite_offers_again`.
  - `quiet_week_not_offered`: only quiet and untracked days.
- [ ] **Step 2: Run** `cargo test -p todo-server weekly`. Expected: FAIL.
- [ ] **Step 3: Implement**, following `updates.rs` handler and error patterns (`UpdateError`, `respond`, `broadcaster.send()` on writes).
- [ ] **Step 4: Run** `cargo test -p todo-server` and `cargo clippy -p todo-server -- -D warnings`. Expected: PASS, no warnings.
- [ ] **Step 5: Commit** `feat(hub): weekly recap work for runners, PUT, rewrite, stale on late daily updates`.

### Task 4: App list endpoint and shared types

**Files:**
- Modify: `todo-app/crates/todo-shared/src/lib.rs`, `weekly.rs`, `main.rs`

**Interfaces:**
- Produces (in `todo_shared`, `Serialize + Deserialize`, snake_case):
  - `WeeklyRecap { week, totals: WeeklyTotals{commits, conversations, runs}, sections: Vec<WeeklySection>, jobs: Option<WeeklyJobs> }`
  - `WeeklySection { project_id, project_name, headline, wins, failed: bool, rewriting: bool, commits, conversations, days_with_work, days: Vec<WeeklyDayState{day, state}>, written_at }`
  - `WeeklyJobs { runs, done, failed, skipped, todos_created, conversations_started, findings, jobs: Vec<WeeklyJob> }`
  - `WeeklyJob { job_id, name, project_name, is_watch: bool, runs, done, failed, skipped, checks, findings, lines: Vec<WeeklyRunLine{run_id, due_at, state, outcome, todo_id: Option<String>}> }`
- `GET /api/weekly?before=<week>&limit=<n>` (default 4, max 12) lists finished weeks that have any `weekly_recaps` row or a `weekly_jobs` row, newest first.
  - Sections are sorted by `conversations` desc. `failed` sections are included. A section with `failed = 0` and empty `wins` is not shown.
  - `totals.runs` = `jobs.runs` (0 when there's no snapshot). Commits and conversations are summed over sections.

- [ ] **Step 1: Write failing tests:**
  - `list_weekly_newest_first_and_paged`.
  - `sections_sorted_by_conversations`.
  - `totals_sum_sections_and_runs`.
  - `week_with_only_jobs_listed`.
  - `deleted_project_section_kept_with_stored_name`: store `project_name` on the recap row at PUT (add a column in v21 from Task 1 if it isn't there yet: `project_name TEXT NOT NULL DEFAULT ''`).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cargo test` (whole workspace) and clippy. Expected: PASS.
- [ ] **Step 5: Commit** `feat(hub): GET /api/weekly`.

### Task 5: Runner writes the weekly section

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai_todo_updates.py`, `ai-session-remote/scripts/todo/test-updates.py`

**Interfaces:**
- Consumes: the `weekly` list from `/api/updates/runner` (Task 3), and `PUT /api/projects/{id}/weekly/{week}`.
- Produces:
  - `WEEKLY_SCHEMA = {"type":"object","additionalProperties":False,"required":["headline","wins"],"properties":{"headline":{"type":"string"},"wins":{"type":"string"}}}`.
  - `WEEKLY_SYSTEM`: data-not-instructions marker. Second person, as wins; 3–5 Markdown bullets in `wins` (fewer if the week was quiet); one headline line ≤120 chars. Only what the material shows; never upgrade "PR open" to "shipped". Keep concrete numbers. Leave out what's next, open, blocked or waiting. When the style names a Jira site, keep keys as `[KEY](<site>/browse/KEY)` links, using only keys in the material. Ignore the style's voice and audience.
  - `weekly_message(item) -> str`: the `<<<MATERIAL … MATERIAL>>>` block. Per day: `## <day> (update)` with the text, or `## <day> (no update; conversation summaries)` with the summaries. Skip quiet and untracked days.
  - `put_weekly(hub, item, headline, wins, failed=False)`.
  - `write_weekly_one(hub, item, settings, usage=read_usage)`: picks the model (raise `Wait` when there's no headroom), redacts the message, runs the model, delinks unknown Jira keys using the daily-update texts and summaries as `key_sources`, then redacts, cuts the headline to 120 and PUTs.
  - In `cmd_run`, after the `write` loop, run the `weekly` loop with the same failure counting under key `weekly:<project>:<week>`. After `MAX_FAILURES`, call `put_weekly(..., "", "", failed=True)`.

- [ ] **Step 1: Write failing tests in `test-updates.py`** using `FakeHub` and the fake claude:
  - `test_weekly_written_and_put`: the PUT body has `headline` and `wins` from the fake model.
  - `test_weekly_message_skips_quiet_and_untracked_and_uses_summaries_for_missing`.
  - `test_weekly_waits_without_headroom`: no PUT.
  - `test_weekly_fails_after_three`: the third run PUTs `failed: true`.
  - `test_weekly_unknown_jira_key_delinked`.
  - `test_runner_without_weekly_key_still_works`: old hub.
- [ ] **Step 2: Run** `python3 ai-session-remote/scripts/todo/test-updates.py`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `test-updates.py`, then `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Expected: PASS. If the sandbox blocks the tmux parts of the full suite, record that and run with the sandbox disabled.
- [ ] **Step 5: Commit** `feat(scripts): runner writes the weekly recap section per project`.

### Task 6: AISessionCore models and client

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/TodoHub/WeeklyModels.swift`, `ai-session-remote/Tests/AISessionCoreTests/WeeklyClientTests.swift`
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift`, `App/AISessionRemote/Services/TodoHubStore.swift` (pass-through methods like `projectUpdates`)

**Interfaces:**
- Produces: the Swift mirrors of Task 4's types (`WeeklyRecap`, `WeeklyTotals`, `WeeklySection`, `WeeklyDayState`, `WeeklyJobs`, `WeeklyJob`, `WeeklyRunLine`). They're public, `Codable, Hashable, Identifiable, Sendable`, with lenient `decodeIfPresent` defaults like `ProjectUpdate`; `id` is `week`, `projectId` or `jobId`, `runId`.
  - `WeeklyRecap.label: String` → `"Week of Mon 2 Nov"`.
  - `WeeklyRecap.windowLabel: String` → `"Mon 2 Nov 08:00 → Mon 9 Nov 08:00"`.
  - Client: `func weeklyRecaps(before: String? = nil, limit: Int = 4) async throws -> [WeeklyRecap]` and `func rewriteWeekly(projectId: String, week: String) async throws`.
  - Store: `weeklyRecaps(before:limit:)` and `rewriteWeekly(projectId:week:)`.

- [ ] **Step 1: Write failing tests**:
  - `decodesWeeklyRecapFromHubJSON`: a fixture covering every field, including `jobs: null`.
  - `weeklyRecapsSendsBeforeAndLimit`: through the URL-protocol stub used in `UpdatesClientTests`.
  - `rewriteWeeklyPostsToPath`.
  - `labels`.
- [ ] **Step 2: Run** `cd ai-session-remote && swift test --filter WeeklyClientTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test`. Expected: PASS; the refresh-call count test is unchanged.
- [ ] **Step 5: Commit** `feat(core): weekly recap models and hub client`.

### Task 7: Weekly view on Mac and iPhone

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Today/WeeklyView.swift`
- Modify: `App/AISessionRemote/Views/Automation/AutomationModels.swift` (`TodayItem.weekly`: title "Weekly", icon `calendar.badge.checkmark`, placed last); `Views/Today/TodayPanes.swift` (list and detail cases; `PhoneTodayRoot` menu link and Monday row)

**Interfaces:**
- Consumes: Task 6 store methods.
- Produces: `struct WeeklyView: View { let store: TodoHubStore }`. It's a scrolling list that loads 4 weeks on appear (`.task`, not on `store.revision`), with "Show older" paging by `before`. The newest week is expanded and the others are collapsed to the label plus totals. Layout per week, matching the accepted sketch:
  - The window line.
  - Three totals tiles: commits, conversations, scheduled runs.
  - Headlines: one line per section, `project: headline`.
  - Per section:
    - Name, then a count line: "N conversations · M commits · K of 7 days". Untracked days are excluded from the 7, so it reads "K of T days".
    - `wins` rendered with `ChatStyledText.make`.
    - Missing and failed days named in caption ("Thu and Fri missing").
    - "▸ From N daily updates" lists the days, with the label from `UpdateDay.label` and the state.
    - A **Rewrite** button (disabled while `rewriting` or offline).
    - A failed section shows "This section couldn't be written." plus Rewrite.
  - Scheduled jobs: a totals line, then a "What they did for you" line (todos created, conversations started, findings). One row per job: name, project, runs ✓ ✗ skip, and "checked N times" for watchers. Failures are in red. Expanding a job shows its lines, and lines with a `todoId` open the todo via `onOpenTodo`.
- Mac: `TodayListColumn` `.weekly` → `WeeklyView`; `TodayDetailColumn` `.weekly` → `AutomationEmpty(text: "")` or collapse the detail column, matching how `.today` handles it.
- iPhone: `PhoneTodayRoot` menu gains `NavigationLink { WeeklyView(store:) } label: { Label("Weekly", systemImage: "calendar.badge.checkmark") }`. On Mondays (Sofia) before 23:59, a top row "Last week's recap" links to the same view.

- [ ] **Step 1:** Build: `cd ai-session-remote && xcodegen generate && xcodebuild -scheme AISessionRemoteMac -configuration Debug build` after the changes. Expected: BUILD SUCCEEDED. Also build the iOS scheme for a simulator.
- [ ] **Step 2:** Run the app against a local hub seeded with a fixture week (`cargo run -p todo-server` with a temp DB plus a curl PUT), or use SwiftUI previews with fixture `WeeklyRecap`s. Screenshot the Mac Weekly view and check every element above appears.
- [ ] **Step 3: Commit** `feat(app): Weekly section in Today on Mac and iPhone`.

### Task 8: Ship

- [ ] **Step 1:** Merge `origin/main` into the branch. Resolve `project.pbxproj` with `git checkout --theirs` + `xcodegen generate`. Run `cargo test`, clippy, `test-updates.py`, `swift test`.
- [ ] **Step 2:** Code review with superpowers:requesting-code-review, then fix what it finds.
- [ ] **Step 3:** Push: `git -c credential.helper='!gh auth git-credential' push https://github.com/tsetsoo/ai-session.git HEAD:main`. Wait for the `pi-latest` release, update the Pi, and check `curl $TODO_HUB_URL/api/weekly` returns `[]` and the schema is v21.
- [ ] **Step 4:** Install helpers on this Mac (`scripts/todo/install.sh`) and on the Codbex and Spread Macs (`tar -czf - scripts/todo watchers jobs | ssh -i ~/.ssh/id_ed25519_aisession -o IdentitiesOnly=yes <host> …install.sh`). Run `ai-todo-updates status` on each.
- [ ] **Step 5:** `ai-session-remote/scripts/rebuild-mac-app.sh`; install the iPhone app (`DEVELOPMENT_TEAM=233QTK6KCL`, `xcrun devicectl`).
- [ ] **Step 6:** Mark the hub idea "Weekly scheduled-jobs summary" done. Update the memory file `daily-updates.md` or add `weekly-recap.md` with: shipped, first real recap Mon 2026-11-09.
