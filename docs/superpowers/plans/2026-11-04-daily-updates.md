# Daily Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every morning, each switched-on project has an update for the previous 08:00→08:00 Sofia window on its project page, written in the project's style from per-conversation summaries, commits and completed todos.

**Architecture:**
- **Each Mac:** a new helper, `ai-todo-updates run`, which the runner tick starts detached. It summarizes its own transcripts for the window with a tool-less Claude Haiku call, falling back to Codex read-only, and posts the summaries to the hub.
- **The hub (v19):** stores the summaries, tracks which computers have reported each day, decides when a project's day is ready to write, and tells the project's computer to write it.
- **The project's computer:** writes the update from the stored summaries, its own git commits and the completed todos, then PUTs it.
- **The apps:** show the updates in a section on the shared `ProjectDetailView`.

**Tech Stack:** Rust (actix-web, rusqlite, chrono-tz via `cron::TZ`) in `todo-app/`; Python 3 stdlib scripts in `ai-session-remote/scripts/todo/`; SwiftUI + `AISessionCore` in `ai-session-remote/`.

**Spec:** `docs/superpowers/specs/2026-11-04-daily-updates-design.md`

## Global Constraints

- Window: **08:00 → 08:00 Europe/Sofia**. A day is named by the window's start date (`YYYY-MM-DD`).
- Keep **90 days** of summaries, reports and updates. Cleanup runs in the scheduler tick.
- `projects.daily_updates` defaults to **off**. An empty `update_style` means the default plain-bullets style.
- A Mac catches up **at most 3 days** back. A computer is **expected** to report if its runner checked in within the **last 3 days**.
- **10:00 Sofia** on the day after the window: the update is written anyway, with "Waiting on: <computer names>".
- A summary that arrives after its day's update was written marks the update **stale**, and it's rewritten automatically.
- Model: **Claude Haiku first**, as `claude -p … --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence`, run in an empty temp folder. **Fallback: Codex** `gpt-6.1-terra` with a read-only sandbox, no network, in an empty temp folder. Model ids come from Today settings (`claude_model`, `codex_model`). Usage thresholds come from the scheduler settings (5-hour **60%**, weekly **80%** by default). If neither tool has headroom, wait and retry on a later tick.
- Transcript text goes through `ai_todo_redact.py` before the model sees it, and model output goes through it again before posting.
- A Jira key may appear in output only if it appears in that item's inputs (transcript window, todo title, commit subjects).
- Commits count when the author is the repo's `git config user.email` or they're on `scheduled/*` branches. The window is filtered by **author date**. De-duplicate by (subject, author date).
- Schema **v19**. Clippy runs with `-D warnings` on deploy: `cargo clippy -p todo-server -p todo-shared --all-targets -- -D warnings`.
- Scripts are Python 3 stdlib only. Never log prompt or transcript text, only ids and counts.
- The app's refresh call-count test (10 hub calls) must not change. Updates load only when a project page opens.
- Work in the worktree `~/programming/ai-session-daily-updates` (branch `spec/daily-updates`). Before pushing, merge `origin/main`. If `project.pbxproj` conflicts, resolve with `git checkout --theirs` and then `xcodegen generate`.

## Review Focus

1. **Window edges.** An entry at 07:59:59 Sofia belongs to the previous day and one at 08:00:00 to this day; switching a project on never backfills (Task 1 `switch_on_sets_since`, Task 3 `days_start_at_switch_on`). Pinned in Task 2 (`day_window`) and Task 5 (`window_entries`).
2. **DST.** Sofia's switch on 2026-10-25 makes that window 25 hours, still 08:00 to 08:00 local. Pinned in Task 2.
3. **A Mac off for days.** The hub stops waiting for it after 3 days, and when it comes back it only catches up 3 days. Pinned in Task 3 (`expected_computers`) and Task 5 (`days` from the hub).
4. **Made-up Jira keys.** Keys not in the inputs are dropped from summaries and de-linked in updates. Pinned in Task 5 (`verified_keys`) and Task 6 (`unknown_keys`).
5. **A late summary after the update was written.** The update becomes stale, the writer picks it up again, and the new PUT clears the flag. Pinned in Task 3.

---

### Task 1: Hub v19 schema, project fields, runner check-in

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs` (bump `SCHEMA_VERSION` to 19; add `create_v19_objects`, called after `create_v18_objects`)
- Modify: `todo-app/crates/todo-shared/src/lib.rs` (`Project`, `UpdateProjectRequest`)
- Modify: `todo-app/crates/todo-server/src/projects.rs` (`PROJECT_SELECT`, row mapping, `update_project_db`)
- Modify: `todo-app/crates/todo-server/src/runner_api.rs` (`due`: record check-in)
- Modify: `todo-app/crates/todo-server/src/describe.rs` (document the new fields)

**Interfaces:**
- Produces, in the tables created by `create_v19_objects`:
  - `projects.daily_updates INTEGER NOT NULL DEFAULT 0`
  - `projects.update_style TEXT NOT NULL DEFAULT ''`
  - `projects.daily_updates_since TEXT`: the Sofia date the switch was last turned on. It's set by PATCH when `daily_updates` goes false→true, and blocks backfill.
  - `computers.runner_seen_at TEXT`
  - `update_summaries(id TEXT PK, project_id, day, computer_id, tool, session_id, todo_id NULL, title, summary, jira_keys TEXT /*JSON array*/, model, created_at, UNIQUE(project_id, day, tool, session_id))`
  - `update_reports(computer_id, day, reported_at, PRIMARY KEY(computer_id, day))`
  - `project_updates(project_id, day, text, commits INTEGER, waiting_on TEXT /*JSON array of names*/, written_at, rewrite_requested INTEGER DEFAULT 0, stale INTEGER DEFAULT 0, PRIMARY KEY(project_id, day))`
  - Indexes on `update_summaries(project_id, day)` and `project_updates(day)`.
- Produces, on the shared types:
  - `Project { daily_updates: bool, update_style: String }`, both `#[serde(default)]`.
  - `UpdateProjectRequest { daily_updates: Option<bool>, update_style: Option<String> }`.
  - An `update_style` over 4000 characters returns 400.

- [ ] **Step 1: Write failing tests in `projects.rs` tests**
  - `patch_daily_updates_and_style`: PATCH `{"daily_updates": true, "update_style": "Group by Jira"}` returns both values, and a GET returns them too.
  - `update_style_too_long`: 4001 characters gives `BAD_REQUEST`.
  - `new_project_updates_off`: a created project has `daily_updates == false` and `update_style == ""`.
  - `switch_on_sets_since`: PATCH `daily_updates: true` sets `daily_updates_since` to today's Sofia date. A second PATCH `true` leaves it unchanged.
- [ ] **Step 2: Write failing test in `runner_api.rs` tests**
  - `due_records_runner_seen_at`: after `GET /api/runner/due?computer_id=mac`, `computers.runner_seen_at` for `mac` is not null.
- [ ] **Step 3: Run `cargo test -p todo-server projects:: runner_api::due_records` and confirm they fail.**
- [ ] **Step 4: Implement the schema, fields and check-in.**
  - `create_v19_objects` follows the v16/v18 pattern: `CREATE TABLE IF NOT EXISTS …`, plus `ALTER TABLE … ADD COLUMN` guarded by `column_exists`.
  - In `due`, run `UPDATE computers SET runner_seen_at = datetime('now') WHERE id = ?1` before `due_db`.
- [ ] **Step 5: Run `cargo test` in `todo-app/` and confirm everything passes.** Also run the clippy command from Global Constraints and confirm it's clean.
- [ ] **Step 6: Commit** with message `feat(hub): v19 daily-updates tables, project switch and style, runner check-in`.

### Task 2: Hub window helpers and the summary intake endpoints

**Files:**
- Create: `todo-app/crates/todo-server/src/updates.rs`, with routes registered in `main.rs`.

**Interfaces:**
- Consumes: `projects::project_for(conn, computer_id, cwd) -> rusqlite::Result<Option<String>>`, `scheduler::sql_time`, `cron::TZ`.
- Produces:
  - `pub(crate) fn day_window(day: &str) -> Option<(DateTime<Utc>, DateTime<Utc>)>`: Sofia 08:00 on `day` to Sofia 08:00 on `day + 1`.
  - `pub(crate) fn last_closed_day(now: DateTime<Utc>) -> String`: the newest day whose window has ended.
  - `POST /api/updates/match` takes `{computer_id, sessions: [{tool, session_id, cwd}]}` and returns `[{tool, session_id, project_id}]`, listing only sessions whose project has `daily_updates = 1`.
  - `POST /api/updates/summaries` takes `{computer_id, day, items: [{tool, session_id, cwd, title, summary, jira_keys: [String], model}]}` and returns `{stored: u32, skipped: u32}`.
    - It resolves the project with `project_for`, and skips items that don't match or whose project is off.
    - It sets `todo_id` from `conversations(tool, session_id)` and upserts on `(project_id, day, tool, session_id)`.
    - `summary` is limited to 2000 characters and `title` to 200. A summary that's too long is cut, not refused.
    - It sets `project_updates.stale = 1` for any `(project_id, day)` that already has a row.
  - `POST /api/updates/reports` takes `{computer_id, day}` and upserts `update_reports`.

- [ ] **Step 1: Write failing unit tests in `updates.rs`**
  - `day_window_is_sofia_eight_to_eight`: `day_window("2026-11-02")` is `2026-11-02 06:00:00Z` → `2026-11-03 06:00:00Z` (EET, UTC+2).
  - `day_window_across_dst`: `day_window("2026-10-24")` is `2026-10-24 05:00:00Z` → `2026-10-25 06:00:00Z` (25 hours).
  - `last_closed_day_edges`: at `2026-11-03 05:59:59Z` it's `"2026-11-01"`; at `2026-11-03 06:00:00Z` it's `"2026-11-02"`.
  - `day_window_rejects_garbage`: `day_window("2026-13-01")` is `None`.
- [ ] **Step 2: Write failing handler tests.** Use `test_support::{pool, seed_computers, insert_session}`, with project `pa` on section Si, folder `~/w/a`, `daily_updates = 1`, and project `pb` with updates off.
  - `match_returns_only_switched_on`: sessions with cwd `~/w/a/sub` and `~/w/b` return only the first, with `project_id == "pa"`.
  - `summaries_upsert_and_link_todo`: posting the same session twice stores 1 row with the second text. When a conversation row exists for it, `todo_id` is set.
  - `summaries_skip_off_projects`: the response is `{"stored":0,"skipped":1}`.
  - `late_summary_marks_update_stale`: insert a `project_updates` row for `pa`/day, post a summary, and `stale` becomes 1.
  - `reports_upsert`: posting the same report twice leaves 1 row.
- [ ] **Step 3: Run `cargo test -p todo-server updates::` and confirm the tests fail.**
- [ ] **Step 4: Implement `updates.rs` and register the routes.** Follow the `ideas.rs` error and `respond` pattern. Call `broadcaster.send()` after writes.
- [ ] **Step 5: Run `cargo test -p todo-server updates::` and confirm the tests pass.**
- [ ] **Step 6: Commit** with message `feat(hub): daily-update windows, session match, summary and report intake`.

### Task 3: Hub runner work list and update PUT

**Files:**
- Modify: `todo-app/crates/todo-server/src/updates.rs`
- Modify: `main.rs` (routes)

**Interfaces:**
- Produces:
  - `pub(crate) fn expected_computers(conn, now) -> rusqlite::Result<Vec<(String /*id*/, String /*name*/)>>`: computers with `runner_seen_at >= now - 3 days`.
  - `GET /api/updates/runner?computer_id=X` returns:
    ```
    { "settings": {"five_hour": u8, "weekly": u8, "claude_model": str, "codex_model": str},
      "days": [day…],                 // the last 3 closed days (newest last) this computer has not reported, only days >= the earliest daily_updates_since of a switched-on project
      "projects": [{"id","name","folder"}],   // switched-on projects whose computer is X (for commits)
      "write": [{ "project_id","project_name","folder","day","style",
                  "summaries":[{"title","summary","jira_keys":[…],"computer"}],
                  "completed_todos":[{"title","completed_at"}],   // project's todos with completed_at in the window
                  "todo_titles":[str] }] }
    ```
    The thresholds come from `jobs::settings_db`, and the model ids come from the Today settings.
  - **The `write` rule**, for a project on computer X that's switched on, and a day among the last 3 closed days that is on or after the project's `daily_updates_since`:
    - The day is **ready** when every expected computer has reported it, or when the time is past 10:00 Sofia on `day + 1` (two hours after its window ends).
    - A ready day is included if it has no update row yet, or its row has `rewrite_requested = 1` or `stale = 1`.
  - `PUT /api/projects/{id}/updates/{day}` takes `{text, commits: u32}`.
    - The hub sets `waiting_on` itself, to the names of expected computers that haven't reported.
    - It sets `written_at` and clears `rewrite_requested` and `stale`.
    - An empty `text` means "nothing happened". The row is stored, so the day isn't offered again, but the app doesn't show it.
    - `text` is limited to 20,000 characters.

- [ ] **Step 1: Write failing handler tests.** Use a fixed `now`: test through `runner_db(conn, computer_id, now)`, which the handler wraps.
  - `days_lists_unreported_closed_days_max_three`: at `2026-11-06 07:00Z`, with nothing reported, the days are `["2026-11-02","2026-11-03","2026-11-04"]`. After reporting `2026-11-03`, it's `["2026-11-02","2026-11-04"]`.
  - `days_empty_when_no_project_on`.
  - `days_start_at_switch_on`: a project switched on with `daily_updates_since = "2026-11-04"`, at `2026-11-06 07:00Z`, gives days `["2026-11-04"]`. That's no backfill: the window of the 4th starts at 08:00 on the 4th.
  - `write_waits_for_expected_computers`: `mac` and `spread` were seen today and only `mac` has reported, so `write` is empty at 07:00 Sofia. Once `spread` reports, it lists `pa`.
  - `write_ignores_computer_unseen_for_three_days`: `spread` was last seen 4 days ago, so the day is ready once `mac` reports.
  - `write_after_ten_without_reports`: at `2026-11-04 08:01Z` (10:01 Sofia), day `2026-11-03` is in `write` even though `spread` hasn't reported. After the PUT, `waiting_on == ["spreads-macbook-pro"]`.
  - `put_clears_stale_and_rewrite`: PUT, then a late summary sets stale, `write` lists it again, and a new PUT clears it.
  - `write_only_for_project_computer`: `codbex` gets no `write` items for `pa` (section Si is `mac`).
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement `runner_db`, `expected_computers` and `put_update_db`.**
- [ ] **Step 4: Run `cargo test -p todo-server updates::` and confirm the tests pass.**
- [ ] **Step 5: Commit** with message `feat(hub): daily-update work list for runners and update PUT`.

### Task 4: Hub app endpoints, Rewrite, 90-day cleanup

**Files:**
- Modify: `updates.rs`, `main.rs`, `scheduler.rs` (`run_tick`), `describe.rs`
- Modify: `todo-app/crates/todo-shared/src/lib.rs` (response types)

**Interfaces:**
- Produces:
  - `todo_shared::ProjectUpdate { day: String, text: String, commits: u32, conversations: u32, waiting_on: Vec<String>, written_at: String, rewriting: bool }`. `rewriting` is `rewrite_requested || stale`.
  - `todo_shared::UpdateSummary { tool, session_id, todo_id: Option<String>, title, summary, jira_keys: Vec<String>, computer: String }`.
  - `GET /api/projects/{id}/updates?before=<day>&limit=<n ≤ 30, default 14>` returns `Vec<ProjectUpdate>`, newest first, excluding empty `text`.
  - `GET /api/projects/{id}/updates/{day}/summaries` returns `Vec<UpdateSummary>`, oldest first.
  - `POST /api/projects/{id}/updates/{day}/rewrite` sets `rewrite_requested = 1`. It returns 404 when there's no row.
  - `pub(crate) fn cleanup_db(conn, now) -> rusqlite::Result<usize>` deletes rows from all three tables where `day < local_date(now) - 90 days`. `run_tick` calls it once per Sofia date; track that with a `static` last-run date.

- [ ] **Step 1: Write failing tests.**
  - `list_updates_newest_first_hides_empty`
  - `list_updates_pages_with_before`
  - `summaries_for_day`
  - `rewrite_flags_and_404`
  - `cleanup_keeps_ninety_days`: at local date 2026-11-04, a day of `2026-08-05` (91 days back) is deleted and `2026-08-06` is kept.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the endpoints and cleanup, and add them to `describe.rs`.**
- [ ] **Step 4: Run `cargo test` and clippy (Global Constraints) and confirm both pass.**
- [ ] **Step 5: Commit** with message `feat(hub): project updates for the apps, rewrite, 90-day cleanup`.

### Task 5: `ai-todo-updates`: summarize this Mac's conversations

**Files:**
- Create: `ai-session-remote/scripts/todo/ai-todo-updates` (same sh→python wrapper as `ai-todo-runner`)
- Modify: `ai-session-remote/scripts/todo/install.sh` (add to `HELPERS`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new section `# --- ai-todo-updates`, reusing the runner section's fake hub and fake limits)

**Interfaces:**
- Consumes:
  - Hub endpoints from Tasks 2–3.
  - `ai-todo-sessions list --json --limit 1000`, which gives `tool, session_id, cwd, title, updated_at`.
  - `ai-todo-transcript <tool> <sid> --json --activity`, which gives entries with `role`, `text`, `timestamp`.
  - `ai_todo_redact.py`, by import, as `ai-todo-memory` does.
- Produces:
  - `ai-todo-updates run`: one pass, guarded by `fcntl` lock `~/.ai-remote/updates-state/lock`. If the lock is held, it exits 0 at once.
  - `ai-todo-updates status [--json]`: last run, last error, and days done.
  - Functions, for tests:
    - `window_entries(entries, start, end) -> list`: keeps entries whose `timestamp` falls in `[start, end)`.
    - `transcript_text(entries, limit=60000) -> str`: user and assistant text plus short activity lines. Over `limit`, it keeps the first 10,000 and last 50,000 characters, joined by `[…]`.
    - `pick_model(settings, usage=read_usage) -> ("claude", model) | ("codex", model) | None`.
      - Claude if it has no reading, or its 5-hour and weekly readings are both under the thresholds.
      - Otherwise Codex, under the same check.
      - Otherwise `None`.
    - `verified_keys(keys, *sources) -> list`: keeps only keys matching `^[A-Z][A-Z0-9]+-\d+$` that appear in some source.
    - `summarize(tool_model, title, text) -> {"summary", "jira_keys", "committed"}`.
      - **Claude:** `--output-format json --json-schema` like `ai-todo-memory.run_claude`.
      - **Codex:** `codex exec --sandbox read-only --skip-git-repo-check -m <model> --output-schema <file> -o <file> -` with cwd a fresh `tempfile.mkdtemp()`, removed afterwards. Check the flag names with `codex exec --help` on this Mac; network stays off in read-only mode.
      - **Environment:** `AI_TODO_CLAUDE_BIN` / `AI_TODO_CODEX_BIN` for the fakes. The CLAUDECODE variables are stripped as in `ai-todo-memory`.
- **The run, for each `day` in the hub's `days`:**
  1. List sessions with `updated_at >= window start`, and `POST /api/updates/match` them.
  2. For each match, read the transcript, apply `window_entries`, and skip it if empty.
  3. `redact`, then `transcript_text`, then `pick_model`. If that returns `None`, log `wait` and stop the whole run without reporting.
  4. `summarize`, then `redact` the output, then `verified_keys` against the transcript text and the title.
  5. POST all of the day's summaries in one call, then POST the report.
- **Failures:**
  - A conversation that fails 3 runs in a row is skipped. The count is kept in state per `tool:sid:day`.
  - Any other failure leaves the day unreported, so it's retried on a later run.
  - Never log prompt or summary text.

- [ ] **Step 1: Write failing tests in `test-todo-scripts.sh`.** Use fake transcripts in the sandbox HOME, a fake `claude` that echoes a fixed JSON envelope, and the fake hub recording POST bodies.
  - **Window:** with entries at 07:59:59 and 08:00:00 Sofia on the day after, `window_entries` keeps only the first for day D.
  - **Truncation:** for a 100,000-character text, `transcript_text` has length ≤ 60,003, starts with the original's first 10,000 and ends with its last 50,000.
  - **Model choice:**
    - With `FAKE_5H=70`, `pick_model` returns codex.
    - With Claude's weekly at 90 and Codex's 5-hour at 70, it returns `None`, the run posts no report, and the log says `wait`.
    - With no reading, it returns claude.
  - **Keys:** with a fake model answering `jira_keys: ["EIN-1","XYZ-9"]` and only `EIN-1` in the transcript, the posted item has `["EIN-1"]`.
  - **Off projects:** a session the hub's match leaves out is never summarized; the fake `claude` call count is 0 for it.
  - **Redaction:** a transcript containing `sk-ant-…` isn't seen by the model (the fake `claude` records stdin), and the posted summary contains no secret.
  - **Retries:** after 3 failed runs for one conversation, the day is reported without it.
  - **Lock:** a second `run` while the lock is held exits 0 without calling the hub.
- [ ] **Step 2: Run `scripts/todo/test-todo-scripts.sh` and confirm the new tests fail.**
- [ ] **Step 3: Implement `ai-todo-updates` (summary part) and add it to `install.sh` `HELPERS`.**
- [ ] **Step 4: Run `scripts/todo/test-todo-scripts.sh` and confirm all tests pass.**
- [ ] **Step 5: Commit** with message `feat(scripts): ai-todo-updates summarizes this Mac's conversations per day`.

### Task 6: `ai-todo-updates`: write project updates; the runner starts it

**Files:**
- Modify: `ai-todo-updates`, `ai-todo-runner`, `test-todo-scripts.sh`

**Interfaces:**
- Produces:
  - `repos_in(folder) -> [path]`: the folder itself if it holds `.git`, else repos at depth 1–2, skipping `node_modules` and hidden folders.
  - `user_commits(repo, start, end) -> [{"repo","subject","author_date"}]`:
    - Commits by `git -C repo log --all --author=<user.email> --since=<start-7d> --format=%aI%x1f%s`.
    - Plus commits on `git log --branches='scheduled/*'`.
    - Filtered to author dates in `[start, end)`, de-duplicated by (subject, author_date).
    - A repo with no `user.email` uses only `scheduled/*`.
  - `unknown_keys(text, sources) -> set`.
  - `write_update(item, tool_model) -> str`: Markdown, via the same model call as `summarize`.
    - The output schema is `{"text": str}`.
    - The system prompt takes the style text as the user's instructions for shape. Inputs are passed as data.
    - The prompt tells the model to link Jira keys as `[KEY](<site>/browse/KEY)` when the style names a site, put work with no key under "Other work", and invent nothing.
    - On `unknown_keys`, it retries once with the list appended. If they're still there, each unknown `[KEY](…)` link is replaced by plain `KEY`.
  - **The run, after the summary part:** for each hub `write` item, collect commits for the item's day window, call `write_update`, redact it, and `PUT /api/projects/{id}/updates/{day}` with `{text, commits}`. When there are no summaries, no completed todos and no commits, PUT `{"text":"","commits":0}` without calling a model.
  - **`ai-todo-runner` tick:** add `maybe_start_updates()` after `report_job_templates`.
    - If `~/.ai-remote/bin/ai-todo-updates` (overridable with `AI_TODO_UPDATES_BIN`) exists and its last start was more than 300 s ago (state `updates-start.json`), start it with `subprocess.Popen([...,"run"], start_new_session=True, stdin/stdout/stderr=DEVNULL)`.
    - The tick never waits for it.

- [ ] **Step 1: Write failing tests.**
  - **Commits:** in a temporary git repo with `user.email=me@x`, a commit by `me@x` in the window, one by `other@x` in the window, one by `me@x` before it, and one by `other@x` on `scheduled/a` give exactly the 1st and 4th.
  - **Rebase copies:** a cherry-pick of the same commit onto another branch is counted once.
  - **Nested repos:** `repos_in` on a folder with `a/.git` and `b/c/.git` returns both.
  - **Empty day:** with no summaries, todos or commits, the PUT body is `{"text":"","commits":0}` and the fake `claude` isn't called.
  - **Made-up keys:** a fake model answering `[XYZ-9](https://solveit.atlassian.net/browse/XYZ-9)` twice gives a posted text containing `XYZ-9` but no `browse/XYZ-9`.
  - **Runner:** `ai-todo-runner tick` with a fake `AI_TODO_UPDATES_BIN` (which records its start) starts it once. A second tick within 300 s doesn't.
- [ ] **Step 2: Run the tests and confirm they fail.**
- [ ] **Step 3: Implement the writing part and `maybe_start_updates`.**
- [ ] **Step 4: Run `scripts/todo/test-todo-scripts.sh` and confirm all tests pass.**
- [ ] **Step 5: Commit** with message `feat(scripts): write project updates from summaries and commits; runner starts ai-todo-updates`.

### Task 7: Swift core: models and client

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/TodoHub/UpdateModels.swift`
- Modify: `ProjectModels.swift` (`Project.dailyUpdates: Bool`, `Project.updateStyle: String`, both decoded with defaults `false` / `""` when missing; `UpdateProjectRequest.dailyUpdates: Bool?`, `.updateStyle: String?`)
- Modify: `TodoHubClient.swift`
- Test: `ai-session-remote/Tests/AISessionCoreTests/UpdatesClientTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProjectUpdate: Codable, Hashable, Identifiable, Sendable { day, text, commits: Int, conversations: Int, waitingOn: [String], writtenAt: String, rewriting: Bool; id: day }`
  - `public struct UpdateSummary: Codable, Hashable, Identifiable, Sendable { tool, sessionId, todoId: String?, title, summary, jiraKeys: [String], computer; id: "\(tool):\(sessionId)" }`
  - `TodoHubClient`:
    - `projectUpdates(projectId:before:limit:) async throws -> [ProjectUpdate]`
    - `updateSummaries(projectId:day:) async throws -> [UpdateSummary]`
    - `rewriteUpdate(projectId:day:) async throws`

- [ ] **Step 1: Write failing tests,** in the `IdeasClientTests` style with `StubURLProtocol`.
  - **Decoding:** both models decode from snake_case JSON.
  - **Old hub:** a `Project` JSON without the new keys decodes with `dailyUpdates == false`.
  - **Paths and query:** `projectUpdates` sends `GET /api/projects/p/updates?before=2026-11-01&limit=14`; `rewriteUpdate` sends `POST …/updates/2026-11-02/rewrite`.
  - **Request body:** `UpdateProjectRequest(dailyUpdates: true, updateStyle: "x")` encodes `daily_updates` and `update_style`.
- [ ] **Step 2: Run `swift test --filter UpdatesClientTests` in `ai-session-remote/` and confirm it fails.**
- [ ] **Step 3: Implement the models and client functions.**
- [ ] **Step 4: Run `swift test` and confirm it passes.**
- [ ] **Step 5: Commit** with message `feat(core): project update models and hub client`.

### Task 8: App: the Updates section and project settings

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Projects/ProjectUpdatesSection.swift`
- Modify: `ProjectDetailView.swift` (insert the section after `conversationsSection`), `ProjectEditorSheet.swift`, `App/AISessionRemote/Services/TodoHubStore.swift`

**Interfaces:**
- Consumes: Task 7's client functions. For the Markdown, reuse the chat's renderer (`ChatMarkdown.blocks`, drawn as `ChatMessageView` / `ChatStyledText` draw them) so links, bullets and headings render.
- Produces:
  - `TodoHubStore` gains `projectUpdates(projectId:before:)`, `updateSummaries(projectId:day:)` and `rewriteUpdate(projectId:day:)`. All of them are demo-safe (they return `[]` under `demo`).
  - **`ProjectUpdatesSection(project:store:onOpenTodo:)`:**
    - Shown only when `project.dailyUpdates`.
    - Loads 14 days on appear, then "Show older" pages with `before`.
    - **Empty state:** "The first update appears after 08:00 tomorrow."
    - **Each day:** a header (`Mon 2 Nov`), the rendered text, **Copy** (puts the raw Markdown on the pasteboard: `UIPasteboard` on iOS, `NSPasteboard` on macOS, as `CommandClipboard` does), and **Rewrite** (shows "Rewriting…" while `rewriting`).
    - A `"Waiting on: …"` line when `waitingOn` is non-empty.
    - A disclosure `"\(conversations) conversations · \(commits) commits"` loads the summaries. Each row opens its todo through `onOpenTodo` when `todoId` is set and the todo is in the store; otherwise it shows "terminal only".
    - The newest day starts expanded.
  - **`ProjectEditorSheet`:**
    - A "Daily updates" toggle, with the footer "Each morning, a summary of yesterday's work (08:00 to 08:00) appears on this project's page."
    - An "Update style" `TextEditor`, shown when the toggle is on, with the placeholder "How the update should read. Empty: a plain bullet list."
    - Both are sent only when changed, like `digestEnabled`.

- [ ] **Step 1: Write failing test** `Tests/AISessionCoreTests/UpdateDayLabelTests.swift` for `public enum UpdateDay { static func label(_ day: String) -> String }` in `UpdateModels.swift` (Sofia-independent: it parses the date only).
  - `label("2026-11-02") == "Mon 2 Nov"`
  - An invalid input is returned unchanged.
- [ ] **Step 2: Run `swift test --filter UpdateDayLabelTests` and confirm it fails.** Then implement it and confirm it passes.
- [ ] **Step 3: Build the views and store functions.**
- [ ] **Step 4: Build both apps.**
  - In `ai-session-remote/`, run `xcodegen generate`.
  - `xcodebuild -scheme AISessionRemoteMac -destination 'platform=macOS' build` succeeds.
  - `xcodebuild -scheme AISessionRemote -destination 'generic/platform=iOS Simulator' build` succeeds.
  - Run the iOS test target's refresh-count test and confirm it's still 10 calls.
- [ ] **Step 5: Commit** with message `feat(app): Updates section on project pages, daily-updates switch and style`.

### Task 9: Rollout

**Files:** none new. Deploy only.

- [ ] **Step 1: Run the full checks.**
  - `cargo test` and clippy (Global Constraints) in `todo-app/`.
  - `scripts/todo/test-todo-scripts.sh`.
  - `swift test`.
  - Both app builds.
  - All must pass.
- [ ] **Step 2: Merge.** `git fetch origin && git merge origin/main`, resolve as in Global Constraints, and rerun Step 1.
- [ ] **Step 3: Push.** `git push origin HEAD:main`. The auto-mode classifier blocks this, so ask the user to run it with `!`. Watch the Pi deploy workflow until it succeeds. Then `GET /api/describe` shows the updates endpoints and `GET /api/projects` has `daily_updates`.
- [ ] **Step 4: Set the four style texts.** Use `PATCH /api/projects/{id}` with `update_style` only, and leave `daily_updates` off.
  - **Repositories** (codbex): "Work update for the team. Group by Jira task: **[KEY](https://jira.digital.ingka.com/browse/KEY) Title** then 1–2 bullets: what moved, what's next. Work with no key under **Other work**. Short, no internal tool names."
  - **Repository** (spread): the same, with `https://solveit.atlassian.net/browse/KEY`.
  - **sigma-revenue**: "A few plain sentences, as told to a teammate: what got done, what's waiting for review or blocked. No bullet lists, no Jira."
  - **ai-session**: "Notes for myself: terse, technical, complete. Bullets per area (hub, scripts, apps): what shipped (commit subjects), what's half-done, open threads."
- [ ] **Step 5: Install the helpers on all three Macs.**
  - This Mac: `scripts/todo/install.sh` from the worktree.
  - Other Macs: `tar -czf - scripts/todo watchers jobs | ssh <host> 'd=$(mktemp -d) && tar -xzf - -C "$d" && "$d/scripts/todo/install.sh"'`. The user runs the SSH lines with `!` if the classifier blocks them.
  - Then `ai-todo-updates status` runs on each Mac.
- [ ] **Step 6: Rebuild the apps.**
  - Mac: run `ai-session-remote/scripts/rebuild-mac-app.sh` from the worktree.
  - iPhone: build with `DEVELOPMENT_TEAM=233QTK6KCL` and install with `xcrun devicectl`.
- [ ] **Step 7: Hand over to the user.** They switch on the four projects in each project's settings. The first update covers the day they switched on, and it appears the next morning after 08:00.
