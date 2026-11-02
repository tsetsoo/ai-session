# Watchers, stage 3: Sigma Sentry

Stage 3 of the scheduler (`2026-11-02-scheduler-design.md`, section 5), narrowed by the user's
decisions on 2026-11-02. This document replaces section 5 where they differ.

## Intent

Sigma Revenue's errors land in Sentry and nobody looks until a hotel complains. The user wants
a new Sentry issue to reach them as a push, with a debugging conversation already working on it,
and a button to resolve the issue in Sentry once the fix is out. They don't want a pile of
duplicate conversations for one recurring issue.

## User's decisions

- Sigma Revenue Sentry only, for now. The Spread laptop's log watcher is deferred.
- A new Sentry issue **starts a debugging conversation automatically**.
- **Never more than one debugging conversation per issue**, ever.
- A **"Resolve in Sentry"** button in the app.
- The watcher runs on this Mac (tsvetelins-macbook-pro, `78e7ef89-…`). The Sentry token lives
  only in `~/.ai-remote/watchers/env` (mode 600) on this Mac, never on the hub.
- Debugging conversations run with Claude in auto mode in their own git worktree, as scheduled
  conversations do. Nothing is pushed, merged or deployed without the user.
- Watcher problems push even during quiet hours, but **silently** (no sound) inside them, as
  other scheduled pushes do (user's answer, 2026-11-02).

## Facts

- Sentry API base: `https://de.sentry.io/api/0/` (EU region). Org `sigma-revenue`. Projects
  `go-http` (Go backend) and `sigma-revenue-webapp` (React).
- Hub project `sigma-revenue` (`00aa5759-…`), folder `~/programming/sigma-revenue`, section Si,
  which is this Mac. That folder is **not** a git repo. The code is in two repos inside it:
  `sigma-revenue-backend` (go-http) and `sigma-revenue-webapp`.

## Goals

1. A watch job checks Sentry every 10 minutes on this Mac.
2. A new unresolved issue: one push, and one debugging conversation in the right repo.
3. The app's Automation mode lists open problems, links each one to its conversation and to
   Sentry, and resolves it in Sentry on request.

## Non-goals

- Other watchers or other computers' secrets (the contract stays generic, but only `sentry`
  ships).
- Re-pushing a problem that stays open. Open problems are listed in the app (and later in the
  morning briefing). *My call:* the main spec's "again after 24 hours" would push the same
  backlog every day.
- The debugging agent resolving issues. It must not touch Sentry; resolving is the user's button.

## Anti-goals

- A flood: a bad deploy that raises ten issues must not start ten conversations at once.
- The Sentry backlog (issues open before the watcher existed) firing on the first check.
- The token showing up anywhere but the env file: not on the hub, not in logs, not in prompts.
- Issue text steering the agent. Error messages can contain text written by anyone; the prompt
  says the problem text is data.

## Design

### Watch jobs

- A new job action kind `watch`: `{project_id, computer_id, watcher, debug_tool, prompt}`.
  - `computer_id` is required (the watcher and its secrets are on one Mac).
  - `debug_tool`: `claude`, `codex`, or none (push only).
  - `prompt`: optional extra instructions for the debugging conversation.
- Its cron is a normal job cron (default `*/10 * * * *`). The daily run cap doesn't apply to
  watch jobs.
- Check runs are due for the job's computer and go through that Mac's runner like conversation
  runs, without the usage-limit guard.

### The watcher contract

- An executable at `~/.ai-remote/watchers/<name>`. The runner runs it with the variables from
  `~/.ai-remote/watchers/env` added to its environment, 60 s at most.
- `<name> check` prints JSON:
  `{"problems": [{"key", "title", "details", "url", "folder"}], "partial": false}`: every
  problem open right now. `partial` (optional) says the list may be incomplete.
  `folder` (optional) is relative to the project folder: the repo a debugging conversation
  should work in.
- `<name> resolve <key>` resolves one problem at the source. Exit 0 is success; its stdout or
  stderr is the message.
- A non-zero exit or bad JSON is a failed check: the run fails with the message and problems are
  left as they are.

### Problems on the hub

- Stored per watcher name and `key` (not per job), so deleting or recreating the watch job
  keeps the memory of which issues already had a conversation. *My call.* Stored: title, details, url, folder, first seen, last seen, state
  (`open`, `resolving`, `cleared`), the debugging run and todo, and the last resolve error.
- **First check** of a job (no earlier successful check): its problems are recorded as the
  backlog. No push, no conversation. *My call:* this keeps the existing Sentry issues from
  starting six conversations at once. The user can start one by hand.
- **Later checks:** a key that wasn't open before (new, or back after it cleared) is new:
  - one push, `<watcher> · <title>`, silent during quiet hours;
  - if the job has a debug tool and the key **never had a debugging conversation**, one is
    queued. At most 3 automatic ones per job per 24 hours; past that the push says to start it
    from the app. *My call:* the cap answers the "bad deploy" anti-goal.
- A key that was open and isn't in the report anymore is `cleared`, unless the report says
  `"partial": true` (the watcher couldn't list everything); then nothing is cleared.
- "One conversation per issue" is held on the hub: a problem with a debugging run is never given
  another, automatic or by button. If that run never starts (missed, skipped, failed before its
  conversation existed), the problem gets its chance back, but only from the button.
- Check runs that find nothing new are hidden from Activity and pruned after 2 days.

### Debugging conversations

- They run as runs of a hidden manual conversation job per watch job, `Debug · <watch job>`:
  urgent, always run, the watch job's tool, project and computer. Unlike other jobs, several of
  its runs may be at work at once: a second issue doesn't wait for the first conversation to
  finish. *My call:* waiting could take days; the 3-a-day cap already limits the number. The hub fills in the problem's
  `folder` for the run, so the runner makes the worktree in the right repo.
- Todo title `Debug: <problem title>`. The prompt: the problem's title, details and URL, marked
  as data; find the cause, write a fix with a test where possible, commit it on the worktree's
  branch, summarize cause, fix and how to verify; do not resolve or change anything in Sentry; do
  not push or deploy. Then the job's extra instructions.
- Because they are urgent, their "needs you" and "finished" pushes work as usual.

### Resolve in Sentry

- The app asks the hub to resolve a problem. The hub marks it `resolving` and lists it to the
  watch job's computer in the runner's due answer.
- The runner runs `<watcher> resolve <key>` and reports the result. Success clears the problem.
  A failure puts it back to `open` with the error, shown in the app.
- A problem still `resolving` after 30 minutes (the Mac asleep or offline) goes back to `open`
  with "this Mac didn't answer". *My call.*
- For 15 minutes after a successful resolve, a check that still lists the key is ignored for
  it (Sentry's API can lag). *My call.*
- If the issue comes back in Sentry, the next check reports it again: a push, and no new
  conversation (it already had one); the push and the app link the earlier conversation.

### The `sentry` watcher

- Shipped in `scripts/todo/watchers/sentry`, installed to `~/.ai-remote/watchers/sentry` by
  install.sh. The env file is never written by the installer.
- Settings in the env file: `SENTRY_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECTS` (comma list),
  `SENTRY_API` (default `https://de.sentry.io/api/0`), and `SENTRY_FOLDERS`
  (`go-http=sigma-revenue-backend,sigma-revenue-webapp=sigma-revenue-webapp`).
- `check`: all unresolved issues of each project, following Sentry's pagination up to 500 per
  project; past that it reports `"partial": true`. Key `sentry:<issue id>`. Title
  `<short id>: <title>`. Details: culprit, level, event and user counts, first and last seen,
  and, fetched once per issue and cached in `~/.ai-remote/watchers/state/`, the latest event's
  message and top stack frames (4000 characters at most).
- `resolve sentry:<id>`: `PUT /organizations/<org>/issues/<id>/` with `{"status": "resolved"}`.
- It never prints the token.

### The app

- Automation's sidebar gets **Watchers**, with a badge of open problems (Mac and iPhone).
- The list: open problems grouped by watch job (title, project, first and last seen, a mark when
  a conversation exists), then "Cleared in the last 7 days". Each job shows when it last checked
  and, if the last check failed, why.
- A problem's pane: details, **Open in Sentry**, **Open debugging conversation** (or **Start
  debugging conversation** when it never had one), **Resolve in Sentry** (asks first; shows
  "Resolving…" and any error).
- The job form gets the Watch kind: watcher name, computer, project, debug tool, extra prompt.

## Left to the builder

Table and endpoint names, how the hub stores the backlog flag, the exact push wording, the
list's layout within the existing Automation look, and where tests go.
