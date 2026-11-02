# Scheduler, ideas, watchers and reminders

Date: 2026-11-02. Status: draft for review.

## Why

The user wants the hub to do things on its own: start research on ideas, watch production systems and open a debugging conversation when something breaks, nudge conversations that should keep going, and remind them of daily things and birthdays. These are experiments. The point is to try every idea cheaply and keep what turns out to be useful, so the design is a few general building blocks, with every use case expressed as a configured job rather than its own feature.

This is the second of three projects. The first (memory upgrade, shipped 2026-11-02) is done. The third is an always-on agent that decides on its own what to run. It will sit on top of this scheduler, so the scheduler must be easy to drive from code as well as from the app.

## Goals

1. **Jobs** on the hub: a trigger plus an action, with every **run** recorded, editable in the app.
2. **Scheduled conversations** start on a chosen computer and show up as **normal todos** with a "Scheduled · <job name>" marker, landing in the usual lists (Working → Ready for review).
3. **Limit guard:** low-priority conversation jobs wait while usage is high. Urgent ones always run.
4. **Ideas** per project, created in the app, by an agent on the user's request, or proposed by an agent (pending approval). A research job picks one, researches it, and stores the findings back on the idea.
5. **Watchers:** small per-project check scripts on a chosen computer. On a problem they push a notification and, if configured, open a debugging conversation.
6. **Reminders and people & dates**, built into the app (not imported), with pushes. A **morning briefing** push plus a "Today" view.
7. **Ready-made jobs** (templates): nightly health, weekly upkeep, stale sweep, memory gardener, release watch, re-ping.

## Non-goals

- Importing from Apple Calendar, Contacts or Reminders. The user's data isn't there; this is built in the app instead.
- An agent that decides by itself what to run. That's the third project.
- Jobs running on the Pi itself. Conversations and watchers run on the Macs, where the tools, repos and credentials are.
- Email sending or chat integrations. Notifications are the existing iPhone pushes only.
- Multi-user anything.

## Anti-goals

- **Burning usage limits:** background jobs eating the quota the user needs for their own work. The limit guard and per-job caps exist for this.
- **Noise:** a flood of pushes or scheduled todos that the user learns to ignore. Every job has a quiet default, and watchers notify once per problem, not once per check.
- **Hidden work:** a conversation that started on its own and isn't visible in the normal lists.
- **Guessing which conversations to continue.** Re-ping only touches conversations the user explicitly marked "keep going".
- **A job silently not running** because its computer was asleep. The app shows "waiting for <computer>" or "missed".

## Existing system (what to build on)

- **Hub:** a Rust server (`todo-app/crates/todo-server`, actix-web + SQLite) on the Pi. It has todos with sections (Sp, I, Si, P) and projects, conversations, push notifications (`push/` with APNs), usage limits (`/api/limits`), daily todos (`/api/daily`), and memories. The schema is versioned in `db.rs` (currently v12).
- **The hub can't reach the Macs.** Today the app SSHes into a Mac and runs `ai-todo-open <tmux_name> <cwd> <session_id> [tool]` with the values `POST /api/todos/{id}/conversation` returns.
- **Host scripts** live in `ai-session-remote/scripts/todo/`, are installed to `~/.ai-remote/bin` by `install.sh`, and use launchd agents (a nightly memory job and a persistent status agent). Config is in `~/.ai-remote/todo-hub.conf`. Each Mac has a computer id on the hub.
- **App:** a SwiftUI app for iPhone and Mac (`AISessionCore` package plus `App/`), with Projects, Computers and lists. Memories already have an approve/reject pattern for agent proposals.

## Design

### 1. Jobs and runs (hub)

**A job has:**
- a name and an enabled flag
- a **trigger**:
  - `cron`: a 5-field cron expression in the user's timezone (Europe/Sofia)
  - `watcher`: fired when a watcher reports a problem
  - `manual`: only "Run now"
- an **action**:
  - `conversation`:
    - project
    - computer (defaults to the computer of the project's section)
    - tool (claude, codex)
    - folder (defaults to the project folder)
    - prompt template
    - priority (`urgent` or `background`): only decides notifications (section 3a)
    - **usage limit setting** (section 3): `always run`, or `wait for headroom` with optional thresholds of its own
  - `push`: a title and body template
  - `todo`: create a todo with a title template
  - `builtin`: one of the ready-made jobs in section 7, with its settings
- limits:
  - the maximum number of runs per day
  - **overlap:** a new run doesn't start while the previous run's conversation is still working (busy or waiting on the user). A finished one (idle, Ready for review) doesn't block the next run.

**A run has:**
- the job and the time it was due
- a state: `due`, `waiting` (computer asleep, or the limit guard holding it), `running`, `done`, `failed`, `skipped`, `missed`
- the computer that claimed it
- links to the todo and conversation it started
- a short result or error text

**The clock:** a hub task wakes every minute, turns cron triggers that came due into `due` runs, and marks a run `missed` when it has waited more than 24 hours.

**Prompt templates** may use `{date}`, `{project}`, `{folder}`, `{job}` and, for ideas and watchers, `{idea}` and `{problem}`.

### 2. The runner (each Mac)

- A new helper, `ai-todo-runner`, is installed by `install.sh` and runs from a launchd agent every 60 seconds.
- **Claiming:** it asks the hub for due runs assigned to this computer. A claim is atomic, so a run is claimed once.
- **For a conversation run:**
  - The hub creates the todo (section from the project, title "<job name> · <date>", marker "scheduled" with the job id) and its conversation row.
  - The runner starts it with `ai-todo-open`, inside the same tmux naming the app uses, and the prompt is delivered as the conversation's first message.
  - Status then flows through the existing hooks, so the todo shows Working → Ready for review like any other.
- **For a watcher check:** it runs the watcher script (section 5) and posts the result.
- **Results:** it reports the run's outcome. A computer that isn't awake simply doesn't claim; the run shows `waiting` with the computer's name.

### 2a. Permissions and worktrees (user's decision)

- **Own worktree:** every scheduled conversation works in its own git worktree, never in the user's live checkout.
  - The runner creates the worktree from the project folder's current default branch, at `~/.ai-remote/worktrees/<project>/<run id>`, on a branch `scheduled/<job>-<date>`.
  - `{folder}` in templates is the worktree.
  - If the project folder isn't a git repository, the conversation runs in the folder itself, read-only by instruction in its prompt.
- **Auto-approve:** permissions are auto-approved.
  - Claude starts in its auto-accept/bypass permission mode.
  - Codex runs as today (`--approve-for-me`, workspace-write sandbox).
- **Nothing leaves the Mac without the user:**
  - No push to a remote, no merge, no deploy.
  - The prompt preamble states this, and the scheduled branch name makes the work easy to find.
- **Cleanup:** a worktree is removed once its todo is completed or closed and its branch has no unpushed commits. Otherwise it's kept, and the stale sweep lists it.

### 3. Limit guard (per-job setting, user's decision)

Every conversation job has a **usage limit setting**, edited in the app:

- **Always run:** starts whatever the usage. Meant for things like watcher debugging or a failed nightly health check.
- **Wait for headroom** (the default for new jobs):
  - The job waits while usage is above its thresholds.
  - The defaults are 60% of the 5-hour window and 80% of the weekly window, and both are global settings in the app.
  - A job can set its own thresholds instead, for example research only below 40%.

How the check works:

- **Who reads usage:** the hub's limit readings are in memory only and refreshed only while the app is open, so the **runner** reads usage itself before starting a waiting-type run (with `ai-todo-limits` for the job's tool on that Mac) and reports it with the run.
- **No reading** (the tool can't report usage, as with Codex today, or the read fails): a "wait for headroom" run goes ahead only if fewer than 3 such runs of that tool started in the last 24 hours.
- **Retrying:** a waiting run is retried on every runner tick, and is `missed` after 24 hours.
- **Pause switch:** a global "pause waiting jobs" switch in the app holds every "wait for headroom" run.
- **Ready-made jobs' defaults (section 8):** nightly health's debugging conversation and watcher debugging always run; everything else waits for headroom. All of them can be changed.

### 3a. Notifications

- **Scheduled conversations don't send** the usual "needs you" / "finished" pushes. Their results are collected in the morning briefing. `urgent` conversations (watcher debugging, failed nightly health) do push.
- **Watcher problems** push even during quiet hours (user's decision).
- **Reminders, people & dates and the briefing** follow quiet hours: a reminder due during quiet hours is delivered when they end.

### 4. Scheduled todos in the app

- Scheduled todos are normal todos in their project's usual section, with a visible marker ("Scheduled · <job name>").
- **List filter:** the lists get a filter to show or hide scheduled todos. By default they're shown.
- **On the todo:** it links to its job and run.
- **Jobs screen:** list, create, edit, enable/disable, Run now, and the last runs with their state.

### 5. Watchers

- **A watcher** is an executable file in `~/.ai-remote/watchers/<name>` on a computer, like the MCP server files.
- **Its output:** JSON on stdout, `{"status": "ok"}` or `{"status": "problem", "key": "<stable id>", "title": "...", "details": "..."}`. Exit codes other than 0 count as a failed check, not a problem.
- **A watcher job** has the watcher name, the computer, how often to check (cron), and what to do on a problem: push, and optionally a debugging conversation (an action like section 1, with `{problem}` in the prompt).
- **Deduplication:** a problem with the same `key` doesn't notify or start a conversation again until it has been `ok` once, or until 24 hours have passed. The run history keeps every check.
- **Secrets:** watchers use secrets from `~/.ai-remote/watchers/env` (shell syntax, mode 600), never stored on the hub.
- **First watchers:**
  - Sigma Revenue: Sentry new issues, via the Sentry API with a token in the env file.
  - The Spread laptop's projects: a log tail with a pattern.

  They're shipped as examples. The user picks which to enable.

### 6. Ideas

- **Storage:** ideas live on the hub, per project:
  - a title and notes
  - a status: `new`, `researching`, `researched`, `dropped`
  - `starred`
  - `pending`, for agent proposals
  - findings text
  - links to the research todo or conversation
- **In the app:** an Ideas section on the project page lets the user add, edit, star, drop, and turn an idea into a todo. Pending ones get Approve/Reject, as memories do.
- **"New idea with an agent":** opens a short conversation (Claude, in the project folder) whose prompt asks the agent to help shape the idea and save it.
- **Command `ai-todo-idea`:**
  - `add "<title>" [--notes "<text>"] [--cwd PATH] [--pending]` saves an idea. It saves directly when the user asked for it; `--pending` is for agent proposals.
  - `list`
  - `findings <id> "<text>"`
- **Research job:**
  - It picks a starred `new` idea in its project, else the oldest `new` one.
  - It marks the idea `researching` and starts a conversation with a research prompt: investigate, write findings, suggest next steps, and save the findings with `ai-todo-idea findings`.
  - When the run's conversation goes idle, an idea still `researching` without findings stays `researching` and shows that state in the app.

### 7. Reminders, people & dates, briefing

- **Reminders:** a title, a time, and a repeat (none, daily, weekdays, weekly, monthly, yearly). The hub sends a push at the time. Done or snoozed from the app.
- **People & dates:** a name, a kind (birthday, anniversary, other), a date (with or without a year), and notes. Pushes go out at 09:00 the day before and on the day.
- **Morning briefing:**
  - **Delivery:** a push at a user-set time (default 08:00) and a Today view in the app.
  - **The push says:** today's reminders and dates, the scheduled todos that finished overnight (Ready for review), how many conversations need the user, and open watcher problems.
  - **Cost:** it's computed on the hub, with no model call.

### 8. Ready-made jobs (builtin)

Each is a job template the user enables and tunes:

| Builtin | What it does | Trigger default | Action |
|---|---|---|---|
| Nightly health | per chosen project, runs its test command; if it fails, starts a debugging conversation | 02:00 daily | conversation only on failure (urgent) |
| Weekly upkeep | per chosen project, a conversation to check dependency updates and advisories and prepare changes on a branch | Sunday 10:00 | conversation (background) |
| Stale sweep | todos untouched for 21 days and conversations in Needs you for 2 days, in one push | Monday 08:30 | push |
| Memory gardener | merges duplicate memories and retires stale ones, as a short conversation over `ai-todo-memory` output | Sunday 03:00 | conversation (background) |
| Release watch | Pi health (hub `/api/health` and disk) at first; App Store review state and backups once the user names the apps, the Mac holding App Store Connect credentials, and the backups (asked at stage 5) | every 2 hours | push on change |
| Re-ping | for conversations marked "keep going" that are idle in Ready for review, sends "continue" | every 3 hours | conversation resume (background) |

- **Re-ping needs a "Keep going" toggle** on a conversation in the app. It stops after the conversation has been re-pinged 5 times or the user turns it off.
- **Nightly health's test command** is a per-project setting (for example `cargo test` in `todo-app`).

## Stages

Built and shipped in this order, each usable on its own:
1. **Core:** jobs and runs, the clock, the runner, scheduled todos with the marker and filter, the push action, the limit guard, and the Jobs screen.
2. **Ideas:** ideas, the research job, `ai-todo-idea`, and the agent-created idea.
3. **Watchers:** the watcher contract and dedup, plus the two example watchers.
4. **Reminders, people & dates, and the morning briefing.**
5. **Ready-made jobs** and the Keep going toggle.

## Decisions

**The user decided:**
- Build all of it, as experiments, to see what's useful.
- Scheduled conversations are normal todos with a scheduled marker.
- Ideas are new, kept in the app. Agents can create them.
- Reminders and birthdays are built in the app, not imported (the user's data isn't in Apple apps).
- Watchers are per-project and flexible: Sigma Revenue and the Spread laptop's projects are the first targets.
- Re-ping is fine, but must not burn limits.
- Scheduled conversations auto-approve permissions, each in its own git worktree; nothing is pushed or merged without the user.
- Watcher problems push even during quiet hours.

**My calls (flag any you disagree with):**
- **Where things run:** the hub schedules, and a runner on each Mac executes (the hub can't reach the Macs).
- **Section:** scheduled todos stay in their project's usual section, not a new one.
- **Re-ping:** only for conversations marked "keep going", capped at 5 nudges.
- **Overlap:** a job's next run is blocked only while its previous conversation is still working, not while it waits for review.
- **Limit guard:**
  - Each job has a usage limit setting (user's decision): always run, or wait for headroom with global or per-job thresholds.
  - The defaults are 60% of the 5-hour window and 80% of the weekly window.
  - The runner reads usage on the Mac.
  - With no reading, at most 3 waiting-type runs per tool per 24 hours.
- **Notifications:** scheduled conversations don't push (the briefing collects them) unless urgent. Reminders wait for the end of quiet hours.
- **Release watch:** starts with Pi health only; the App Store and backups part waits for details at stage 5.
- **Default computer:** a project's default computer is its section's computer.
- **Ideas:** created on the user's request save directly; agent proposals wait for approval.
- **Missed:** a run counts as missed after 24 hours waiting.
- **Watchers:** secrets stay on the Macs, and each problem notifies once until it clears or 24 hours pass.
- **Briefing:** computed without a model call.
- **Timezone:** Europe/Sofia for cron and reminders.

## Left to the builder

- **Schema details:** tables, columns, the v13 migration, and API shapes for jobs, runs, ideas, reminders, people and settings.
- **Delivering the first prompt:** how the prompt reaches a newly started conversation (for example an `ai-todo-open` option that passes it to the tool as its initial message).
- **Claiming:** the atomic claim mechanism and the runner's launchd setup.
- **Cron:** parsing (a small crate or a hand-written 5-field parser).
- **App:** layout of the Jobs, Ideas, Reminders, People and Today screens, within the existing design system.
- **Tests:** following the existing patterns (`cargo test`, `scripts/todo/test-todo-scripts.sh` with the fake hub, Swift tests for models and client).
