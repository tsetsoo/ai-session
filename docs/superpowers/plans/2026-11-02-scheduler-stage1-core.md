# Scheduler Stage 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jobs with cron or manual triggers run on schedule. Conversation jobs start as scheduled todos on a chosen Mac, in their own worktree, behind a per-job usage limit setting. Push and todo jobs run on the hub. Everything is visible and editable in the app.

**Architecture:**
- **Hub:** stores jobs, runs and scheduler settings. A one-minute clock turns cron slots into runs and executes push and todo actions itself.
- **Each Mac:** a launchd runner (`ai-todo-runner tick`, every 60 s) fetches due conversation runs, checks usage locally, claims each run atomically, creates a git worktree, and asks the hub to create the todo and conversation. It then starts it detached through `ai-todo-open` with the first prompt and auto-approve.
- **App:** gets models, a Jobs screen, a scheduled marker on todos and a list filter.

**Tech Stack:** Rust (actix-web, rusqlite, chrono, chrono-tz, tokio), Python 3 inside shell wrappers, launchd, SwiftUI (AISessionCore + app).

**Spec:** `docs/superpowers/specs/2026-11-02-scheduler-design.md` (this plan covers its stage 1: sections 1, 2, 2a, 3, 3a for scheduled conversations, and 4).

## Global Constraints

- **Timezone:** Europe/Sofia for cron.
- **Cron:** 5 fields (minute hour day-of-month month day-of-week). Supports `*`, numbers, `a-b`, `a,b`, `*/n`, `a-b/n`; day-of-week 0–7, with 0 and 7 both Sunday.
- **Run states:** `due`, `waiting`, `running`, `done`, `failed`, `skipped`, `missed`. A run waiting more than 24 hours becomes `missed`.
- **Scheduled todo:**
  - title `<job name> · <YYYY-MM-DD>`
  - section: the project's section
  - `project_id` set
  - marker: `scheduled_job_id` and `scheduled_run_id`
- **Usage limit setting per conversation job:**
  - `{"mode": "always"}` or `{"mode": "wait", "five_hour": <int?>, "weekly": <int?>}`
  - global defaults: `five_hour` 60, `weekly` 80
  - with no usage reading, a `wait` run starts only if fewer than 3 `wait` runs of that tool started in the last 24 hours
  - a global `pause_waiting` switch holds every `wait` run
- **Priority** (`urgent` or `background`) only decides pushes: a `background` scheduled todo is push-muted when it's created.
- **Overlap:** a job's next run isn't handed out while its previous run's conversation is `busy` or `waiting`.
- **Worktree:**
  - path `~/.ai-remote/worktrees/<project id>/<run id>`
  - branch `scheduled/<job slug>-<YYYYMMDD>-<run id first 8>`
  - based on `origin/HEAD` if it exists, else the folder's `HEAD`
  - a non-git folder runs in place
- **Prompt preamble** (prepended to every scheduled prompt, verbatim):
  `This is a scheduled conversation ("{job}", {date}). You work in your own git worktree at {folder}. Do not push, merge, deploy or change anything outside this worktree; leave results here for review.`
  For a non-git folder the second sentence is replaced by `You work in {folder}, which is not a git repository: do not modify files.`
- **Auto-approve:** Claude starts with `--permission-mode bypassPermissions`; Codex as today.
- **Git:** work happens in the existing worktree `~/programming/ai-session-memory`, on a new branch `feat/scheduler-core` from `main`. Push to `main` only in Task 11.

## Review Focus

1. **A Mac asleep for a day.** When it wakes, a job gets one run, not 24 (missed slots coalesce to the latest), and a run waiting over 24 hours becomes `missed`. Test: `tick_coalesces_missed_slots` (Task 4).
2. **Two runners racing for the same run** (a stale and a new launchd instance). Exactly one claim succeeds and the other gets 409. Test: `claim_is_atomic` (Task 5).
3. **A project folder that isn't a git repo, or a repo without `origin`.** The runner falls back sensibly and never checks out or changes a branch in the live folder. Tests: `runner_non_git_runs_in_place`, `runner_worktree_without_origin_uses_head` (Task 7).
4. **DST transitions in Europe/Sofia.** On the fall-back day a 03:30 job fires once. On the spring-forward day a 03:30 slot that doesn't exist fires at the next valid minute, once. Tests: `cron_dst_fall_back_fires_once`, `cron_dst_spring_forward_skips_to_next_valid` (Task 2).
5. **`ai-todo-limits` failing or hanging.** The runner treats it as no reading (with a 20 s timeout), applies the 3-per-24h rule, and never blocks the tick. Test: `runner_limits_failure_uses_daily_cap` (Task 7).

---

### Task 1: Schema v13 and shared types

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs` (`SCHEMA_VERSION` 13, doc line, migration step `version == 12`, `create_v13_objects` called on every start like `create_v12_objects`, `schema_version` sniff: `jobs` table exists → 13)
- Modify: `todo-app/crates/todo-shared/src/lib.rs` (types below; `Todo` gains `scheduled_job_id: Option<String>` and `scheduled_run_id: Option<String>`, both `#[serde(default, skip_serializing_if = "Option::is_none")]`)
- Modify: the todo row mappers in `todo-app/crates/todo-server/src/handlers.rs` (or wherever `Todo` is read) to fill the two fields

**Interfaces:**
- Produces:
  - **Tables:**
    - `jobs(id TEXT PK, name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, trigger TEXT NOT NULL /*JSON*/, action TEXT NOT NULL /*JSON*/, max_runs_per_day INTEGER NOT NULL DEFAULT 4, last_slot_at TEXT, created_at, updated_at)`
    - `job_runs(id TEXT PK, job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE, due_at TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('due','waiting','running','done','failed','skipped','missed')), computer_id TEXT, todo_id TEXT REFERENCES todos(id) ON DELETE SET NULL, tool TEXT, limit_mode TEXT, waiting_reason TEXT, result TEXT, started_at TEXT, created_at, updated_at)`, with index `(job_id, due_at)` and index `(state)`
    - `scheduler_settings(id INTEGER PK CHECK(id = 1), five_hour INTEGER NOT NULL DEFAULT 60, weekly INTEGER NOT NULL DEFAULT 80, pause_waiting INTEGER NOT NULL DEFAULT 0)`, seeded with one row
    - `todos.scheduled_job_id TEXT`, `todos.scheduled_run_id TEXT` (`ALTER TABLE` when missing)
  - **Shared types** (serde snake_case):
    - `JobTrigger` = enum tagged `kind`: `Cron { cron: String }` | `Manual`
    - `LimitSetting` = enum tagged `mode`: `Always` | `Wait { five_hour: Option<u8>, weekly: Option<u8> }`
    - `Priority` = `Urgent` | `Background`
    - `JobAction` = enum tagged `kind`:
      - `Conversation { project_id: String, computer_id: Option<String>, tool: String, folder: Option<String>, prompt: String, priority: Priority, limit: LimitSetting }`
      - `Push { title: String, body: String }`
      - `Todo { title: String, project_id: Option<String>, section: Option<Section> }`
    - `Job { id, name, enabled: bool, trigger: JobTrigger, action: JobAction, max_runs_per_day: u32, created_at, updated_at, last_run: Option<JobRun>, next_fire_at: Option<String> }`. `next_fire_at` is computed by the hub (Task 3), and is `null` for manual or disabled jobs.
    - `JobRun { id, job_id, due_at, state: String, computer_id: Option<String>, todo_id: Option<String>, waiting_reason: Option<String>, result: Option<String>, started_at: Option<String>, created_at, updated_at }`
    - `CreateJobRequest { name, enabled: Option<bool>, trigger, action, max_runs_per_day: Option<u32> }`
    - `UpdateJobRequest`: all fields optional
    - `SchedulerSettings { five_hour: u8, weekly: u8, pause_waiting: bool }`

- [ ] **Step 1:** Write the failing tests in `db.rs` tests:
  - `migrates_v12_to_v13_adds_scheduler_tables`: a v12 database becomes 13, with `jobs`, `job_runs` and `scheduler_settings` (one row: 60, 80, 0) and the two `todos` columns. One backup is written.
  - `fresh_database_has_v13_objects`
  - In `todo-shared`: `job_action_round_trips_json`, with exactly this JSON:
    `{"kind":"conversation","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"x","priority":"background","limit":{"mode":"wait","five_hour":40,"weekly":null}}`
- [ ] **Step 2:** Run `cd todo-app && cargo test`. Expected: the new tests fail.
- [ ] **Step 3:** Implement the migration (additive: `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE` guarded by `column_exists`) and the types.
- [ ] **Step 4:** Run `cd todo-app && cargo test`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(server): scheduler schema v13 and shared job types`

### Task 2: Cron parser

**Files:**
- Create: `todo-app/crates/todo-server/src/cron.rs` (no IO)

**Interfaces:**
- Produces:
  - `pub(crate) struct Cron`
  - `pub(crate) fn parse(expr: &str) -> Result<Cron, String>`
  - `impl Cron { pub(crate) fn next_after(&self, after: DateTime<Utc>, tz: Tz) -> Option<DateTime<Utc>> }`: the first matching wall-clock minute strictly after `after`, evaluated in `tz`.
  - DST rules:
    - Ambiguous local times (fall-back) take the **earlier** instant only.
    - Nonexistent local times (spring-forward) move to the first valid minute after the gap.
  - Day-of-month and day-of-week combine as in Vixie cron: if both are restricted, either matching fires.
  - `pub(crate) const TZ: Tz = chrono_tz::Europe::Sofia;`

- [ ] **Step 1:** Write the failing tests:
  - `parse_rejects_bad_fields` (`"60 * * * *"`, `"* * *"`, `"a * * * *"` are errors)
  - `next_after_every_15_minutes`
  - `next_after_weekday_morning` (`"0 8 * * 1-5"` from a Saturday gives Monday 08:00 Sofia)
  - `dom_or_dow_either_matches`
  - `sunday_is_0_and_7`
  - `cron_dst_fall_back_fires_once` (`"30 3 * * *"` across 2026-10-25: exactly one fire that day, at 03:30 EEST = 00:30 UTC)
  - `cron_dst_spring_forward_skips_to_next_valid` (`"30 3 * * *"` on 2026-03-29: 03:30 doesn't exist, so it fires at 04:00 EEST = 01:00 UTC, once)
- [ ] **Step 2:** Run `cd todo-app && cargo test cron::`. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement it by walking minute by minute in local time with field bitsets, capped at 366 days, then returning `None`.
- [ ] **Step 4:** Run `cd todo-app && cargo test cron::`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): 5-field cron in Europe/Sofia`

### Task 3: Jobs and scheduler settings API

**Files:**
- Create: `todo-app/crates/todo-server/src/jobs.rs`
- Modify: `todo-app/crates/todo-server/src/main.rs` (`mod jobs;`, routes in `api_routes`)

**Interfaces:**
- Consumes: the types from Task 1, and `cron::parse` from Task 2.
- Produces routes:
  - `GET /api/jobs` returns `[Job]`, each with its `last_run` and `next_fire_at` (`cron::next_after(now)` in RFC 3339 UTC).
  - `POST /api/jobs` returns 201 with the `Job`. It returns 400 when:
    - the name is empty
    - the cron is invalid
    - the conversation tool isn't `claude` or `codex`
    - a limit threshold is above 100
    - the prompt is empty

    It returns 404 for an unknown `project_id` or `computer_id`.
  - `PATCH /api/jobs/{id}`, `DELETE /api/jobs/{id}`
  - `POST /api/jobs/{id}/run` creates a `due` run with `due_at = now` (manual "Run now") and returns 201 with the `JobRun`. Disabled jobs still run on demand.
  - `GET /api/jobs/{id}/runs?limit=N` returns the newest runs first (default 20, max 200).
  - `GET /api/scheduler/settings` and `PUT /api/scheduler/settings` (validation: 1–100).
  - Every change calls `broadcaster.send()`.
- Also produces `pub(crate) fn load_job(conn, id) -> rusqlite::Result<Option<Job>>`.

- [ ] **Step 1:** Write failing handler tests with `test_support`:
  - `create_and_list_job` (includes `next_fire_at` for `"0 8 * * *"` and `null` for manual)
  - `create_job_validation` (one assert per 400 case above)
  - `patch_job_disables`
  - `run_now_creates_due_run`
  - `runs_newest_first`
  - `settings_get_put_validate`
  - `delete_job_cascades_runs`
- [ ] **Step 2:** Run `cd todo-app && cargo test jobs::`. Expected: FAIL.
- [ ] **Step 3:** Implement the module.
- [ ] **Step 4:** Run `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): jobs and scheduler settings API`

### Task 4: The hub clock

**Files:**
- Create: `todo-app/crates/todo-server/src/scheduler.rs`
- Modify: `todo-app/crates/todo-server/src/main.rs` (spawn the clock with `actix_web::rt::spawn`, ticking every 60 s via `tokio::time::interval`, with access to the pool, broadcaster and `PushNotifier`)

**Interfaces:**
- Consumes: `cron` (Task 2), `jobs::load_job` (Task 3), and `PushNotifier::send_to_devices` with `Alert`. `PushKind` gains `Scheduled`; `Alert.todo_id` is `None`.
- Produces:
  - `pub(crate) struct TickOutcome { created: Vec<String>, missed: Vec<String>, pushes: Vec<(String, String)>, todos: Vec<String> }`
  - `pub(crate) fn tick_db(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<TickOutcome>`. It's pure DB work; the caller sends the pushes. For each enabled cron job:
    - **New run:** if the next slot after `last_slot_at` (or after the job's `created_at` when it's null) is ≤ `now`, insert **one** run with `due_at` = the latest slot ≤ now, and set `last_slot_at` to it.
    - **Daily cap:** don't insert past `max_runs_per_day` runs created today (Sofia day); record a `skipped` run instead.
    - **Push and todo actions:** these runs complete inside the tick (the todo is created with the scheduled marker; the push title and body go into `pushes`), and the run is `done`.
    - **Missed:** runs in `due` or `waiting` whose `due_at` is more than 24 hours old become `missed`.
  - `pub(crate) fn render(template: &str, vars: &[(&str, &str)]) -> String`: replaces `{date}`, `{project}`, `{folder}`, `{job}`. Unknown braces are left as they are.

- [ ] **Step 1:** Write the failing tests:
  - `tick_creates_run_when_slot_passes`
  - `tick_coalesces_missed_slots` (a job every 15 min, last slot 6 hours ago: one new run)
  - `tick_respects_max_runs_per_day`
  - `tick_marks_missed_after_24h`
  - `tick_runs_push_job_on_hub` (the outcome has the push and the run is `done`)
  - `tick_runs_todo_job_with_marker`
  - `tick_ignores_disabled_and_manual`
  - `render_replaces_known_vars`
- [ ] **Step 2:** Run `cd todo-app && cargo test scheduler::`. Expected: FAIL.
- [ ] **Step 3:** Implement it, then wire the spawn in `main.rs` (log errors, never panic the loop).
- [ ] **Step 4:** Run `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): scheduler clock (cron runs, push and todo jobs)`

### Task 5: Runner API

**Files:**
- Create: `todo-app/crates/todo-server/src/runner_api.rs`
- Modify: `todo-app/crates/todo-server/src/main.rs` (routes)
- Modify: `todo-app/crates/todo-server/src/conversations.rs` (expose a helper that creates the conversation row for a todo with an explicit `cwd`, reusing `open_conversation_db`)

**Interfaces:**
- Consumes: Tasks 1, 3 and 4 (`render`), plus the push mute table (`push_muted_todos`).
- Produces routes:
  - `GET /api/runner/due?computer_id=X` returns `{"settings": SchedulerSettings, "runs": [DueRun]}`, where `DueRun = {run: JobRun, job: Job, wait_runs_24h: u32}`.
    - **Which runs:** conversation-action runs in `due` or `waiting` whose resolved computer is X. The resolved computer is the action's `computer_id`, else the computer of the project's section (`section_computers`).
    - **Left out:**
      - runs whose previous run of the same job has a conversation in `busy` or `waiting`
      - `wait`-mode runs while `pause_waiting` is on
    - `wait_runs_24h` counts `wait`-mode runs of the same tool started in the last 24 hours.
  - `POST /api/runs/{id}/wait` with `{"reason": "..."}` sets the run to `waiting` and records the reason. It returns 409 unless the run is `due` or `waiting`.
  - `POST /api/runs/{id}/claim` with `{"computer_id": "..."}` atomically moves the run from `due`/`waiting` to `running` (`UPDATE … WHERE id = ? AND state IN ('due','waiting')`, one row). It returns 200 with the `DueRun`, or 409 otherwise.
  - `POST /api/runs/{id}/start` with `{"cwd": "~/…", "is_git": true}` requires the run to be `running` and claimed by the caller's computer. It:
    - creates the scheduled todo (title `<job name> · <YYYY-MM-DD>` in Sofia time, the project's section, `project_id`, marker)
    - push-mutes it when the priority is `background`
    - creates its conversation with that `cwd` and the job's tool
    - sets `todo_id`, `started_at` and `limit_mode`
    - returns `{"todo_id", "tmux_name", "session_id", "tool", "prompt"}`, where `prompt` = the preamble from Global Constraints (git or non-git variant) + a blank line + the rendered job prompt
  - `POST /api/runs/{id}/finish` with `{"state": "done"|"failed", "result": "..."}`

- [ ] **Step 1:** Write the failing tests:
  - `due_lists_runs_for_computer_only`
  - `due_resolves_section_computer`
  - `due_skips_job_whose_last_conversation_is_busy`
  - `due_hides_wait_runs_when_paused`
  - `due_counts_wait_runs_24h`
  - `claim_is_atomic` (two claims, one 200 and one 409)
  - `start_creates_marked_todo_and_conversation_with_cwd`
  - `start_mutes_background_not_urgent`
  - `start_prompt_has_preamble` (git and non-git variants, exact strings)
  - `finish_records_result`
  - `wait_then_claim`
- [ ] **Step 2:** Run `cd todo-app && cargo test runner_api::`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): runner API (due, claim, start, finish)`

### Task 6: `ai-todo-open` options for unattended starts

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-open` (leading options in any order: `--mcp <names>`, `--detached`, `--prompt-file <path>`, `--auto-approve`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (ai-todo-open section)

**Interfaces:**
- Produces:
  - **`--detached`:** creates the tmux session without attaching, then exits 0 once the tool has started (as it already waits for Codex/Cursor ids).
  - **`--prompt-file <path>`:**
    - On a new conversation, the file's text becomes the tool's initial prompt: a positional argument for `claude` and for `codex`.
    - On a resume, it's ignored.
    - The file is deleted after reading.
  - **`--auto-approve`:** adds `--permission-mode bypassPermissions` for Claude. Codex already auto-approves.
  - Older callers (the app) are unchanged.

- [ ] **Step 1:** Write the failing tests, using the existing fake-tool and fake-tmux setup in that section:
  - `open_detached_does_not_attach`
  - `open_prompt_file_becomes_initial_prompt_claude`
  - `open_prompt_file_becomes_initial_prompt_codex`
  - `open_prompt_ignored_on_resume`
  - `open_auto_approve_claude_flag`
  - `open_options_any_order_with_mcp`
- [ ] **Step 2:** Run `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Expected: the new tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the script. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(scripts): ai-todo-open --detached, --prompt-file, --auto-approve`

### Task 7: `ai-todo-runner`

**Files:**
- Create: `ai-session-remote/scripts/todo/ai-todo-runner` (same shell-wrapper + Python layout as `ai-todo-memory`; reuses its `Config`/`Hub` patterns, copied rather than shared)
- Modify: `ai-session-remote/scripts/todo/fixtures/fake-hub.py` (the runner endpoints from Task 5, from state keys `due_runs`, plus claim/start/finish/wait logging; `claim` answers 409 when `state["claimed"]` already has the id)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new section `--- ai-todo-runner`)

**Interfaces:**
- Consumes: the Task 5 routes, Task 6 `ai-todo-open` options, and `ai-todo-limits --tool T` (JSON `{"windows":[{"kind":"5h","used_percent":21.0},{"kind":"weekly","used_percent":40.0}]}`).
- Produces:
  - `ai-todo-runner tick`: for each due run, in order:
    1. **Limit check** for `wait` mode: the thresholds are the job's, else the settings'. Run `ai-todo-limits` with a 20 s timeout.
       - If a reading is over a threshold: `POST /wait` with the reason `"5h 72% > 60%"` or `"weekly 85% > 80%"`.
       - If there's no reading and `wait_runs_24h >= 3`: `/wait` with the reason `"no usage reading; 3 runs in 24h"`.
    2. **Claim.** On 409, skip the run.
    3. **Worktree** (git folder):
       - `git -C <folder> fetch --quiet origin` (ignore failure)
       - base = `origin/HEAD` if `git rev-parse --verify origin/HEAD` succeeds, else `HEAD`
       - `git -C <folder> worktree add -b <branch> <path> <base>`
       - Non-git folder: run in place.
    4. **Start:** `POST /start` with `cwd` (in `~` form) and `is_git`, write the prompt to a mode-600 temp file, and run `ai-todo-open --detached --auto-approve --prompt-file F <tmux_name> <cwd> <session_id|-> <tool>`.
    5. **Finish:** `/finish` with `done` and result `"started <tool> in <cwd>"`, or with `failed` and the error. A failed worktree or start removes the worktree it created.
  - Never more than 3 runs started per tick.
  - Log to `~/.ai-remote/runner-state/runner.log` (ids and counts only, never prompt text).
  - Exit 0 unless the config is missing (65).
  - `ai-todo-runner status [--json]` shows the last tick, the last error and the runs started in 24 hours.

- [ ] **Step 1:** Write the failing tests (fake hub, fake `ai-todo-open` recording its argv, fake `ai-todo-limits` via `AI_TODO_LIMITS_BIN`, a temp git repo with and without `origin`):
  - `runner_starts_due_run_in_worktree` (worktree exists on the right branch; `ai-todo-open` argv has `--detached --auto-approve --prompt-file`; the prompt file had the preamble; `/finish` done)
  - `runner_waits_when_over_threshold` (job threshold 40, reading 45: `/wait` with the reason, no claim)
  - `runner_always_mode_ignores_limits`
  - `runner_limits_failure_uses_daily_cap` (limits exit 75 or sleep > timeout: with `wait_runs_24h` 2 it starts; with 3 it waits)
  - `runner_claim_conflict_skips`
  - `runner_non_git_runs_in_place`
  - `runner_worktree_without_origin_uses_head`
  - `runner_start_failure_reports_and_cleans_worktree`
  - `runner_log_has_no_prompt`
- [ ] **Step 2:** Run the test script. Expected: the new tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the test script. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(scripts): ai-todo-runner runs scheduled conversations`

### Task 8: Install the runner

**Files:**
- Modify: `ai-session-remote/scripts/todo/install.sh`:
  - add `ai-todo-runner` to `HELPERS`
  - a LaunchAgent `com.ai-remote.todo-runner` with `ProgramArguments [bin/ai-todo-runner, tick]`, `StartInterval 60`, `RunAtLoad true`, and its log in `~/.ai-remote/runner-state/launchd.log`
  - create `~/.ai-remote/worktrees` (mode 700)
  - uninstall removes the agent but keeps the worktrees
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (install section)

- [ ] **Step 1:** Write the failing test: `install_runner_agent` (plist fields, launchctl bootout + bootstrap calls on macOS, worktrees dir 700, uninstall removes the plist).
- [ ] **Step 2:** Run the script. Expected: FAIL.
- [ ] **Step 3:** Implement, reusing the existing plist-writing helper.
- [ ] **Step 4:** Run the script. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(scripts): install the scheduler runner LaunchAgent`

### Task 9: App models and client

**Files:**
- Create: `ai-session-remote/Sources/AISessionCore/TodoHub/JobModels.swift` (Swift mirrors of the Task 1 types, `Codable`, snake_case through the existing decoder)
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift`: `listJobs()`, `createJob(_:)`, `updateJob(id:_:)`, `deleteJob(id:)`, `runJob(id:)`, `jobRuns(id:limit:)`, `schedulerSettings()`, `updateSchedulerSettings(_:)`
- Modify: the `Todo` model to add `scheduledJobId: String?` and `scheduledRunId: String?`
- Test: `ai-session-remote/Tests/AISessionCoreTests/JobsClientTests.swift`

- [ ] **Step 1:** Write the failing tests:
  - `testJobDecodesConversationAction` (the JSON from Task 1)
  - `testJobDecodesPushAndTodoActions`
  - `testCreateJobBody`
  - `testRunJobPath` (`POST /api/jobs/j1/run`)
  - `testSchedulerSettingsRoundTrip`
  - `testTodoDecodesScheduledMarker`
- [ ] **Step 2:** Run `cd ai-session-remote && swift test --filter JobsClientTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cd ai-session-remote && swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(app): job models and client`

### Task 10: App screens

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Jobs/JobsView.swift` (list with enable toggle, last run state, Run now; the "Pause waiting jobs" switch and the two thresholds at the top)
- Create: `ai-session-remote/App/AISessionRemote/Views/Jobs/JobEditorView.swift`:
  - name, trigger (cron text, or manual; after saving, the list shows the hub's `next_fire_at`), action kind
  - for conversations: project, computer (default "Project's computer"), tool, prompt, priority, and the usage limit (Always run / Wait for headroom with optional own thresholds)
  - max runs per day
- Create: `ai-session-remote/App/AISessionRemote/Views/Jobs/JobRunsView.swift` (runs, newest first, with state, reason or result, and the todo link)
- Modify: `TodoHubStore.swift` (load jobs on refresh, like projects, optional for older hubs; the jobs CRUD wrappers through `perform`)
- Modify:
  - **Marker:** todo row views (`RowText` / the list row) show a "Scheduled · <job name>" marker when `scheduledJobId` is set.
  - **Filter:** `TodoListView` and `ConversationListView` get a "Show scheduled" filter (default on, kept per device).
  - **Navigation:** Jobs is reachable from the Mac sidebar (a row under Projects) and from the phone's Projects tab toolbar.

- [ ] **Step 1:** Write a failing test for any pure logic added (marker text: `testScheduledMarkerText`).
- [ ] **Step 2:** Run `swift test --filter testScheduledMarkerText`. Expected: FAIL.
- [ ] **Step 3:** Implement the views.
- [ ] **Step 4:**
  - Run `cd ai-session-remote && swift test`.
  - Then `xcodegen generate`.
  - Then build both apps with `CODE_SIGNING_ALLOWED=NO` (`AISessionRemote` for `generic/platform=iOS`, `AISessionRemoteMac` for `generic/platform=macOS`).

  Expected: tests pass and both builds exit 0.
- [ ] **Step 5:** Commit: `feat(app): jobs screen, scheduled marker and filter`

### Task 11: Roll out and try it

- [ ] **Step 1:** Whole-branch review. Push to `main` (the hub first) and wait for the "Deploy Pi" workflow. Confirm `GET /api/jobs` answers on the Pi.
- [ ] **Step 2:** Install the helpers on this Mac, the Codbex Mac and the Spread Mac (`tar | ssh … install.sh`). Check `ai-todo-runner status` on each.
- [ ] **Step 3:** Create a manual job "Scheduler smoke test" (Claude, project ai-session, background, wait mode, prompt "List the three largest files in this worktree and stop.") and press Run now. Within 2 minutes expect:
  - a scheduled todo
  - a worktree under `~/.ai-remote/worktrees`
  - the conversation reaching Ready for review with no permission prompt
  - no push

  Then do the same with Codex.
- [ ] **Step 4:** Create a push job with `*/5 * * * *` and check that a push arrives, then disable it.
- [ ] **Step 5:** Rebuild the Mac app (`scripts/rebuild-mac-app.sh` from the worktree) and the iPhone app. Check the Jobs screen, the marker and the filter.
- [ ] **Step 6:** Report back. Leave the smoke test job disabled.
