# Automation mode: a separate place for jobs, ideas and activity

Date: 2026-11-02. Status: draft for review.

## Why

Stages 1 and 2 of the scheduler shipped jobs, ideas and research, but their UI is tucked away:
- **Jobs:** a toolbar button on the phone's Projects tab, and a sidebar row on the Mac.
- **Ideas:** only a section on each project page.

The user couldn't find ideas at all, and called the current placement "just to the side".

**What the user wants:** working with jobs and ideas isn't working with terminals, so it deserves its own interface. Selecting a job should fill the big pane (where the terminal normally is) with that job's details: configuration and executions. Creating a job should be a button that turns the main pane into the job's configuration, not a pop-up. This needs to be in place before stage 3 (watchers) adds more automation.

## Goals

1. **Two modes (Mac):** a window-level switch between **Sessions** (today's app) and **Automation**. Automation has its own sidebar: **Jobs**, **Ideas** and **Activity** now, with room for stage 3–5 items later.
2. **Jobs:**
   - The middle column lists jobs.
   - Selecting one fills the big pane with its details and run history, with Run now, Edit and an on/off switch.
   - **New** and **Edit** turn the big pane into the job form. There are no sheets.
3. **Ideas:**
   - The middle column lists ideas across all projects, grouped by project, filterable by status (including Waiting for OK).
   - Selecting one fills the big pane with its notes and findings, shown as a readable page.
   - Actions: Star, **Research now**, Turn into todo, Drop and Delete.
   - New idea and Shape with an agent live at the top of the list.
4. **Activity:** one timeline of runs across all jobs (newest first). Selecting a run shows its details and links to its job and todo.
5. **iPhone:** a fifth tab, **Automation**, with the same three lists. Each item opens a full screen with the same content as the Mac's big pane.
6. **One home for each thing:** the old placements go away.
   - the phone's Jobs toolbar button
   - the Mac's Jobs sidebar row
   - the Jobs sheets
   - the Ideas section on project pages, replaced by a one-line "Ideas: N new · M waiting for OK" link that opens Automation → Ideas filtered to that project

## Non-goals

- Watchers, reminders, people & dates and Today. Those are stages 3–5. Their sidebar slots may appear greyed out or be absent; builder's choice.
- Changing how jobs or research work, apart from Research now (section 4).
- A visual redesign of Sessions mode.

## Anti-goals

- Losing the user's place: switching modes and back returns to the same selection in each mode.
- Two ways to do the same thing (old placements kept alongside new ones).
- A job form that loses typed changes when the user clicks another job. Ask first, or keep the draft (builder's choice; the draft must not be dropped silently).

## Existing system

- **App:** SwiftUI for iPhone and Mac, in `ai-session-remote/App/AISessionRemote`, with shared models and client in `Sources/AISessionCore`.
  - **Mac shell:** a `NavigationSplitView` (sidebar, content, detail) in `Views/Shell/MacShell.swift`. Sidebar items are `AppModel.SidebarItem`. `⌘1`–`⌘9` already open conversations.
  - **Phone shell:** tabs in `Views/Shell/PhoneShell.swift` (`Tab`: todos, conversations, projects, computers).
- **Existing jobs and ideas UI** (stage 1–2): `Views/Jobs/JobsView.swift`, `JobEditorView.swift`, `JobRunsView.swift`, and `Views/Projects/IdeaViews.swift`. The pieces that move into Automation (the job form fields, idea detail, shape-an-idea, approve and reject) should be reused, not rewritten.
- **Data:**
  - `TodoHubStore` holds `jobs`.
  - Ideas are loaded per project (`ideas(projectId:pending:)`).
  - Runs are loaded per job (`jobRuns`).
- **Hub API:** `/api/jobs`, `/api/jobs/{id}/runs`, `/api/ideas` (with optional `project_id`), `/api/ideas/shape`, `/api/runner/*`.

## Design

### 1. Mode switch (Mac)
- **Control:** a segmented control **Sessions | Automation** in the window toolbar.
- **Shortcuts:** `⌃⌘1` (Sessions) and `⌃⌘2` (Automation), in a "View" or "Go" menu (my call; `⌘1`–`⌘9` are taken).
- **Memory:** the current mode is remembered per window. Each mode keeps its own sidebar, list and detail selection.
- **What Automation shows:**
  - **Sidebar:** Jobs, Ideas, Activity.
  - **Middle column:** the list for the selected sidebar item.
  - **Big pane:** the detail or form.
  - The list-and-pane pattern matches Sessions, so the app feels like one app.

### 2. Jobs
- **Each list row shows:**
  - the name
  - a one-line summary of what it does (for example "Research ideas · ai-session · Claude")
  - the schedule in plain words
  - a state chip for the last run (done, failed, waiting with its reason, skipped, off)

  **+ New** sits at the top.
- **Detail pane:**
  - **Header:** the name, an on/off switch, **Run now** and **Edit**.
  - **Schedule:** the cron in words plus the raw expression, and the next run (`next_fire_at`).
  - **Does:** what it does, where (project, computer, tool), the limit setting and pushes.
  - **Runs:** the newest 50, each with state, time, reason or result, and the todo it made (clicking opens the todo in Sessions mode).
  - **Deleting:** a menu item, with confirmation.
- **Form** (New and Edit), in the big pane:
  - the same fields as today's sheet, including the research kind
  - Create/Save and Cancel
  - the cron shown in plain words under the field, with the next three runs once saved (hub-computed; the app has no cron engine)
- **Plain-words schedule:** the hub adds `schedule_text` to jobs (for example "Weekdays at 09:00"), from a small cron describer next to `cron.rs`, with a fallback to the raw expression. My call: the hub already parses cron, so describing it there avoids a second parser in Swift.

### 3. Ideas
- **List:** ideas from all projects, grouped by project.
  - **Filter chips:** All, New, Researching, Researched, Waiting for OK. Default: All, which doesn't show dropped ideas; dropped ones appear only under a "Dropped" chip.
  - Each row shows a star, the title, a status chip and a "findings" marker.
  - **New idea** and **Shape with an agent** buttons sit at the top. Both ask for the project first.
- **Detail pane:**
  - an editable title and notes
  - the findings rendered as Markdown (read-only, selectable)
  - links to the research todo or conversation
  - actions: Star, **Research now**, Turn into todo, Drop, Delete
  - waiting-for-OK ideas show Approve and Reject at the top
- **Data:** the app loads ideas across projects with `GET /api/ideas` (no `project_id`), plus `pending=true` for the waiting ones.

### 4. Research now (new on the hub)
`POST /api/ideas/{id}/research` researches *this* idea now. Pressing it is an explicit request, so it doesn't queue behind the scheduled research job.

- **Its own job:** it runs on its own per-project manual job, **"Research now · <project>"**, created on first use.
  - It's the same kind of job as "Shape an idea".
  - Settings: research, Claude, the project's computer, background (no pushes), and **always run**. You asked for it, so it doesn't wait for headroom.
- **The run:** it creates a `due` run whose `note` is `idea:<id>`.
- **The idea is reserved at once:** in the same transaction it becomes `researching`, with `run_id` set to that run. The consequences:
  - Every device shows it as Researching straight away.
  - A second press, from any device, gets 409.
  - Scheduled research runs skip it (they only pick `new` ideas).
- **Refused:** it returns 409 unless the idea is `new` and approved.
- **Starting:** `start_db`, for a research run with an `idea:<id>` note, takes that idea when it is `researching` with `run_id` equal to this run. Otherwise the run fails with "idea no longer available".
- **Giving the idea back:** if the run is missed (24 h), fails, or is skipped, the idea returns to `new`. The existing failed-finish reset is extended to missed runs in the clock.
- **App:** Research now is enabled only for `new`, approved ideas. After pressing, the idea shows **Researching**, the hub's own state, with no app-only flag.

### 5. Activity
- **Hub:** `GET /api/runs?limit=N` returns the newest runs across all jobs, with the job's name.
- **List:** runs, newest first, each with the state chip, job name, time and reason or result.
- **Detail pane:** the run's fields, plus links to its job (in Automation) and its todo (in Sessions).

### 5a. Usage limits
- **Where:** the scheduler's global settings (Pause waiting jobs, 5-hour %, weekly %) move from the old JobsView into **Automation → Jobs**, as a "Usage limits" row pinned at the top of the jobs list.
- **Opening it:** selecting the row shows the three settings in the big pane, saved as they change. This is still one home for them.

### 6. iPhone
- **New tab:** **Automation**, between Projects and Computers.
  - Its root is a list with three rows: Jobs, Ideas and Activity, plus a pending-ideas count badge.
  - Each row pushes the list, and items push full-screen detail and form views, the same views the Mac uses in its big pane.
- **Old entry points removed:** the Jobs toolbar button on Projects.

### 7. Removed placements
- the Mac sidebar's **Jobs** row
- the phone's Projects toolbar **Jobs** button
- the job sheets (the form moves into the pane)
- the **Ideas** section on project pages, replaced by a one-line link

The pending-memories count stays on Projects. The pending-ideas count moves to the Automation tab and its Ideas row.

## Decisions

**The user decided:**
- A whole second mode of the window (Sessions / Automation), not a sidebar group.
- Selecting a job fills the big pane with its details and executions.
- New and Edit happen in the main pane, not in a pop-up.
- Ideas get their own section there.
- The rest of the played-back design "sounds good", including Activity, the phone tab and removing the old placements.

**My calls (flag any you disagree with):**
- **Shortcuts:** `⌃⌘1` / `⌃⌘2`.
- **Schedule in words:** computed by the hub (`schedule_text`).
- **Research now:**
  - It runs on its own per-project "Research now" job, with always run and no pushes, so it never queues behind scheduled research or waits for headroom.
  - It reserves the idea as Researching on the hub at once, so there are no duplicates from any device.
  - It gives the idea back if the run fails, is missed or is skipped.
- **Usage limits:** the settings live as a pinned row at the top of Automation → Jobs, opening in the big pane.
- **Activity:** shows the newest runs across jobs, with a new `/api/runs` endpoint.
- **Phone:** Automation is the fifth tab, between Projects and Computers.
- **Dropped ideas:** hidden unless the Dropped filter is chosen.

## Left to the builder

- **SwiftUI structure:** how the two modes share or swap the split view, and state restoration.
- **Unsaved forms:** the behaviour when leaving a form with unsaved changes. It must not be dropped silently.
- **Layout and styling:** within the existing design system (`DS`), Markdown rendering for findings, and empty states.
- **Later slots:** whether watcher, reminder and Today slots appear greyed out now.
- **Tests:** Rust tests for the new endpoints and `schedule_text`; Swift tests for any pure logic (filters, grouping, form drafts); both apps must build.
