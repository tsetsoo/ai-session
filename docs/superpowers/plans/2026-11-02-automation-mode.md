# Automation Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give jobs, ideas and activity their own place.
- **Mac:** a Sessions / Automation mode switch, where the big pane shows the details or the form.
- **iPhone:** an Automation tab.
- **Hub:** schedules in plain words, a cross-job runs list, and Research now.

**Architecture:**
- **Hub:** gains `schedule_text` on jobs (a cron describer next to `cron.rs`), `GET /api/runs`, and `POST /api/ideas/{id}/research`.
- **Research now:** a per-project manual job ("Research now · <project>", always run, background) whose runs carry `note = idea:<id>`. The idea is reserved as `researching` at once.
- **App:** a new `Views/Automation/` folder holds the lists, detail panes and forms, used by both the Mac's split view and the phone's tab. The old job sheets and the project-page Ideas section are removed. Existing pieces are reused: job form fields, idea detail, shape-an-idea.

**Tech Stack:** Rust (actix-web, rusqlite), SwiftUI (iPhone and Mac), AISessionCore.

**Spec:** `docs/superpowers/specs/2026-11-02-automation-mode-design.md`

## Global Constraints

- **Mode switch:** a toolbar segmented control **Sessions | Automation**.
  - Shortcuts: `⌃⌘1` Sessions, `⌃⌘2` Automation.
  - The mode is stored per window. Each mode keeps its own selection.
- **Automation sidebar:** Jobs, Ideas, Activity.
- **Research now:** the job is named `Research now · <project name>`, with research kind, Claude, the project's computer (`computer_id: null`), `priority: background`, `limit: always`, and `max_runs_per_day: 20`.
  - The run note is `idea:<id>`.
  - It returns 409 unless the idea is `new` and not pending.
  - A missed, failed or skipped run returns the idea to `new`.
- **Idea filter chips:** All (excludes dropped), New, Researching, Researched, Waiting for OK, Dropped.
- **Usage limits:** a pinned row at the top of Automation → Jobs. Its pane saves on change.
- **Removed:**
  - the Mac sidebar Jobs row
  - the phone Projects-toolbar Jobs button
  - `JobsView`'s sheets (editor, runs)
  - the project-page `IdeasSection`, replaced by a one-line link `Ideas: N new · M waiting for OK`
- **Git:** branch `feat/automation-ui` in `~/programming/ai-session-memory`. Merge `origin/main` before pushing, regenerating the Xcode project on conflict. Run CI clippy before pushing: `cargo clippy -p todo-shared -p todo-server -- -D warnings`.

## Review Focus

1. **Research now pressed twice, or from two devices:** one run, and the second press gets 409. Test: `research_now_twice_conflicts` (Task 2).
2. **A Research-now run missed after 24 h:** its idea goes back to `new`, not stuck. Test: `missed_research_now_returns_idea` (Task 2).
3. **Leaving a half-filled job form** (clicking another job or switching mode) never silently drops it: a confirm dialog appears. Test: `testJobDraftIsDirty` (Task 3) plus the dialog in Task 4.
4. **An old hub without `schedule_text` or `/api/runs`:** the app still shows jobs (the raw cron), and Activity shows "Needs a newer hub". Test: `testJobDecodesWithoutScheduleText` (Task 3).
5. **The idea list with many projects:** grouping is stable (by project name), and pending ideas show only under "Waiting for OK". Test: `testIdeaFilterAndGrouping` (Task 3).

---

### Task 1: Hub — schedule text and the runs list

**Files:**
- Modify: `todo-app/crates/todo-server/src/cron.rs` (`pub(crate) fn describe(expr: &str) -> String`)
- Modify: `todo-app/crates/todo-shared/src/lib.rs`:
  - `Job.schedule_text: Option<String>` (`#[serde(default)]`)
  - `RunWithJob { run: JobRun, job_id: String, job_name: String }`, serialised flat as `JobRun` fields plus `job_name`; builder's choice
- Modify: `todo-app/crates/todo-server/src/jobs.rs`:
  - fill `schedule_text` (cron jobs get `describe(cron)`; manual jobs get `"Manual"`)
  - `GET /api/runs?limit=N` (default 50, max 200), newest by `due_at`, with `job_name`

**Interfaces:**
- **`describe`, plain English:**
  - `"*/15 * * * *"` → `"Every 15 minutes"`
  - `"0 9 * * *"` → `"Every day at 09:00"`
  - `"0 9 * * 1-5"` → `"Weekdays at 09:00"`
  - `"30 8 * * 1"` → `"Mondays at 08:30"`
  - `"0 */2 * * *"` → `"Every 2 hours"`
  - `"0 9 1 * *"` → `"Monthly on day 1 at 09:00"`
  - anything else → `"Cron: <expr>"`

- [ ] **Step 1:** Write the failing tests:
  - `describe_common_schedules` (the cases above)
  - `jobs_include_schedule_text`
  - `runs_list_newest_across_jobs` (`job_name` present, limit respected)
- [ ] **Step 2:** Run `cd todo-app && cargo test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test` and clippy. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): schedules in words and a runs list across jobs`

### Task 2: Hub — Research now

**Files:**
- Modify: `todo-app/crates/todo-server/src/ideas.rs` (`POST /api/ideas/{id}/research`, using a find-or-create helper shared with shape)
- Modify: `todo-app/crates/todo-server/src/runner_api.rs` (`start_db`: a research run with an `idea:<id>` note takes that idea when it is `researching` with `run_id` = this run; otherwise it returns 409 `Idea no longer available`)
- Modify: `todo-app/crates/todo-server/src/scheduler.rs` (when a run becomes `missed` or `skipped`, the idea with `run_id` = that run and status `researching` returns to `new`)
- Modify: `todo-app/crates/todo-server/src/main.rs` (route)

**Interfaces:**
- **`POST /api/ideas/{id}/research`** returns 201 with the `JobRun`.
- In one IMMEDIATE transaction it:
  - checks the idea is `new` and `pending = 0` (otherwise 409)
  - finds or creates the project's "Research now" job
  - inserts a `due` run with `note = 'idea:<id>'`
  - sets the idea to `status = 'researching'`, `run_id = <run>`

- [ ] **Step 1:** Write the failing tests:
  - `research_now_reserves_idea_and_runs`
  - `research_now_twice_conflicts`
  - `research_now_pending_or_researched_conflicts`
  - `research_now_job_created_once`
  - `start_research_now_takes_that_idea` (even when a starred new idea exists)
  - `missed_research_now_returns_idea`
  - `failed_research_now_returns_idea`
- [ ] **Step 2:** Run `cargo test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test` and clippy. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(server): research a chosen idea now`

### Task 3: Core models, client and pure logic

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/JobModels.swift` (`SchedulerJob.scheduleText: String?`; `RecentRun` = a `JobRun` plus `jobName`)
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/IdeaModels.swift`:
  - `IdeaFilter` (`all, new, researching, researched, waiting, dropped`) with `label` and `matches(_ idea: Idea) -> Bool`
  - `IdeaGrouping.byProject(_ ideas: [Idea], projects: [Project]) -> [(project: Project?, ideas: [Idea])]`, sorted by project name, with unknown projects last
- Create: `ai-session-remote/Sources/AISessionCore/TodoHub/JobDraft.swift`: `JobDraft` (the editor's fields as a value type, `init(job:)`, `request` builders, `isDirty(comparedTo:)`), moved out of `JobEditorView`'s `@State`
- Modify: `TodoHubClient.swift` (`listIdeas(projectId: String?, pending:)` where nil means all projects; `researchIdea(id:) -> JobRun`; `recentRuns(limit:) -> [RecentRun]`)
- Test: `JobsClientTests.swift`, `IdeasClientTests.swift`

- [ ] **Step 1:** Write the failing tests:
  - `testJobDecodesWithoutScheduleText`
  - `testRecentRunsDecode`
  - `testResearchIdeaPath`
  - `testListIdeasAllProjectsHasNoProjectQuery`
  - `testIdeaFilterAndGrouping` (pending only under Waiting for OK; dropped only under Dropped; groups sorted by project name)
  - `testJobDraftIsDirty`
  - `testJobDraftRoundTripsResearchJob`
- [ ] **Step 2:** Run `cd ai-session-remote && swift test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(core): automation models, idea filters and job drafts`

### Task 4: Mac — Automation mode with Jobs

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Automation/AutomationMode.swift`: `enum AppMode { sessions, automation }`; `enum AutomationItem { jobs, ideas, activity }`; selection state in `AppModel` per window
- Create: `Views/Automation/JobsList.swift` (list column: the Usage limits row, then jobs with summary, schedule text and a last-run chip; "+ New")
- Create: `Views/Automation/JobDetailPane.swift` (header: on/off, Run now, Edit, delete menu; Schedule; Does; Runs)
- Create: `Views/Automation/JobFormPane.swift` (the form in the pane, built on `JobDraft`, from the old `JobEditorView` fields; Create/Save and Cancel; a confirm dialog when leaving a dirty draft)
- Create: `Views/Automation/UsageLimitsPane.swift`
- Modify: `Views/Shell/MacShell.swift` (toolbar mode switch; Automation mode swaps the sidebar, content and detail; `⌃⌘1` and `⌃⌘2` in the commands)
- Modify: `Views/Shell/SidebarView.swift` (remove the Jobs row) and `AppModel.SidebarItem` (remove `.jobs`)
- Delete: `Views/Jobs/JobsView.swift`, `JobEditorView.swift`, `JobRunsView.swift` (their contents move into the new files)

- [ ] **Step 1:** Build both apps (`xcodegen generate`, `xcodebuild … CODE_SIGNING_ALLOWED=NO`) after implementing. There's no new pure logic beyond Task 3 (`JobDraft`), so this task's gate is the build plus the Task 3 tests.
- [ ] **Step 2:** Implement.
- [ ] **Step 3:** Run `swift test` and build both apps. Expected: PASS, exit 0.
- [ ] **Step 4:** Commit: `feat(app): Automation mode on the Mac with jobs in the big pane`

### Task 5: Ideas and Activity panes

**Files:**
- Create: `Views/Automation/IdeasList.swift`:
  - filter chips
  - grouped list across projects, with pending ideas showing Approve/Reject inline
  - "New idea" (pane form: project picker, title, notes)
  - "Shape with an agent" (pane form: project picker, hint)
- Create: `Views/Automation/IdeaDetailPane.swift`:
  - title and notes editing (`IdeaEdit`)
  - findings rendered with `AttributedString(markdown:)`, selectable
  - Star, Research now (enabled for new, approved ideas), Turn into todo, Drop, Delete
  - links to the research todo
- Create: `Views/Automation/ActivityList.swift` and `RunDetailPane.swift` (with "Needs a newer hub" on 404)
- Modify: `Views/Projects/ProjectDetailView.swift` (replace `IdeasSection` with the one-line link, which opens Automation → Ideas filtered to the project)
- Delete: `Views/Projects/IdeaViews.swift` (reused parts move)

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift test` and build both apps. Expected: PASS, exit 0.
- [ ] **Step 3:** Commit: `feat(app): ideas and activity in Automation`

### Task 6: iPhone Automation tab

**Files:**
- Modify: `Views/Shell/PhoneShell.swift`:
  - `Tab.automation` between projects and computers, with the icon `bolt.horizontal.circle`
  - its root lists Jobs, Ideas and Activity, with a pending-ideas badge
  - each row pushes the same list views, and items push the same detail and form panes full screen
  - remove the Projects-toolbar Jobs button

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift test` and build both apps. Expected: PASS, exit 0.
- [ ] **Step 3:** Commit: `feat(app): Automation tab on iPhone`

### Task 7: Review and roll out

- [ ] **Step 1:** Whole-branch review and fixes.
- [ ] **Step 2:** Merge `origin/main`, run clippy, push, wait for "Deploy Pi", and check `GET /api/runs` and `schedule_text`.
- [ ] **Step 3:** Rebuild the Mac app (`scripts/rebuild-mac-app.sh` from the worktree) and the iPhone app.
- [ ] **Step 4:** Live:
  - on the Mac, switch to Automation; check Jobs, a job's details and runs, New job in the pane (then cancel), Ideas with findings, and Activity
  - press Research now on a new idea and check it turns Researching, then a run appears in Activity
