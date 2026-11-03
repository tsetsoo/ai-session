# Watchers, stage 3: Sigma Sentry

Stage 3 of the scheduler (`2026-11-02-scheduler-design.md`, section 5), narrowed by the user's
decisions on 2026-11-02. This document replaces section 5 where they differ.

## Intent

Sigma Revenue's errors land in Sentry and nobody looks until a hotel complains. The user wants
**zero open Sentry issues**: the existing backlog worked off, and every new issue picked up by a
debugging conversation without them asking. Conversations must not trip over each other: an
issue one conversation has taken is never worked on by another. Once a fix is out, a button
resolves the issue in Sentry.

## User's decisions

- Sigma Revenue Sentry only, for now. The Spread laptop's log watcher is deferred.
- The goal is zero open issues, backlog included.
- Debugging conversations start automatically, **at most 2 at work at once**.
- A conversation takes only issues **no other conversation has taken**, and may take many.
- If it gets overwhelmed, the user is notified.
- A **"Resolve in Sentry"** button in the app.
- The watcher runs on this Mac (tsvetelins-macbook-pro, `78e7ef89-…`). The Sentry token lives
  only in `~/.ai-remote/watchers/env` (mode 600) on this Mac, never on the hub.
- Debugging conversations run with Claude in auto mode in their own git worktree, as scheduled
  conversations do. Nothing is pushed, merged or deployed without the user.
- New issues push even during quiet hours, but **silently** (no sound) inside them, as other
  scheduled pushes do.

## Facts

- Sentry API base: `https://de.sentry.io/api/0/` (EU region). Org `sigma-revenue`. Projects
  `go-http` (Go backend) and `sigma-revenue-webapp` (React).
- Hub project `sigma-revenue` (`00aa5759-…`), folder `~/programming/sigma-revenue`, section Si,
  which is this Mac. That folder is **not** a git repo. The code is in two repos inside it:
  `sigma-revenue-backend` (go-http) and `sigma-revenue-webapp`.
- Some open issues come from outside services (SerpApi requests failing, a PMS connection).
  Those count too: the fix is better handling on our side (retry, clearer error, an honest log
  level).

## Goals

1. A watch job checks Sentry every 10 minutes on this Mac.
2. Every open issue is taken by a debugging conversation, at most 2 at once, none taken twice.
3. A new issue pushes once.
4. The app lists open issues with who has them and what came of it, links each to its
   conversation and to Sentry, and resolves it in Sentry on request.

## Non-goals

- Other watchers or other computers' secrets (the contract stays generic, but only `sentry`
  ships).
- Re-pushing an issue that stays open. Open issues are listed in the app (and later in the
  morning briefing). *My call:* the main spec's "again after 24 hours" would push the same
  backlog every day.
- The debugging agent resolving issues. It must not touch Sentry; resolving is the user's button.

## Anti-goals

- Two conversations working on the same issue.
- More than 2 debugging conversations at work at once (usage, and the user's attention).
- An issue that can't be fixed being picked up again and again.
- The token showing up anywhere but the env file: not on the hub, not in logs, not in prompts.
- Issue text steering the agent. Error messages can contain text written by anyone; the prompt
  says the issue text is data.

## Design

### Watch jobs

- A new job action kind `watch`: `{project_id, computer_id, watcher, debug_tool, prompt}`.
  - `computer_id` is required (the watcher and its secrets are on one Mac).
  - `debug_tool`: `claude`, `codex`, or none (push only, no conversations).
  - `prompt`: optional extra instructions for the debugging conversations.
- Its cron is a normal job cron (default `*/10 * * * *`). The daily run cap doesn't apply to
  watch jobs.
- Check runs are due for the job's computer and go through that Mac's runner like conversation
  runs, without the usage-limit guard.
- Check runs that find nothing new are hidden from Activity and pruned after 2 days.

### The watcher contract

- An executable at `~/.ai-remote/watchers/<name>`. The runner runs it with the variables from
  `~/.ai-remote/watchers/env` added to its environment, 60 s at most.
- `<name> check` prints JSON:
  `{"problems": [{"key", "title", "details", "url", "folder"}], "partial": false}`: every
  problem open right now. `folder` (optional) is relative to the project folder: the repo a
  debugging conversation should work in. `partial` (optional) says the list may be incomplete.
- `<name> resolve <key>` resolves one problem at the source. Exit 0 is success; its stdout or
  stderr is the message.
- A non-zero exit or bad JSON is a failed check: the run fails with the message and problems are
  left as they are.

### Issues on the hub

- Stored per watcher name and `key` (not per job), so deleting or recreating the watch job keeps
  what each issue went through. *My call.* Each has: title, details, url, folder, first and last
  seen, state, the conversation that took it (if any), its outcome and note, and the last resolve
  error.
- **States:**
  - `open`, untaken: waiting for a conversation.
  - `open`, taken by a conversation, with an outcome once the agent reports one: `fixed` (a fix
    is committed on its branch), `needs_you` (a decision only the user can make), `cant_fix`.
  - `resolving`: the user pressed Resolve; waiting for this Mac.
  - `cleared`: Sentry no longer lists it (resolved there, or by the button).
- A key not in a check's report is `cleared`, unless the report is `partial`.
- A cleared key that comes back is a new appearance: it pushes, and it's untaken again unless its
  last conversation said `cant_fix`. *My call:* a regression after a fix deserves another look;
  a known can't-fix doesn't.
- **"Taken" is held on the hub**, in one transaction with starting the conversation, so two
  conversations never get the same issue.

### Starting debugging conversations

- After each successful check, if the job has a debug tool, there are untaken open issues, and
  fewer than 2 of the job's debugging conversations are at work, the hub queues one more.
  "At work" means its conversation exists and isn't finished, or it's queued or being started.
  A conversation counts as finished once it's idle after its first turn, or closed.
- The conversation works in one repo: the folder with the most untaken issues (ties: the oldest
  issue). When it starts, it **takes every untaken open issue of that repo**. The prompt lists
  them. *My call:* "pick up many if needed" with no cap; the agent narrows it down (next bullet).
- The agent can give issues back and report on them with a helper on the Mac,
  `ai-todo-watch`:
  - `ai-todo-watch release <key>…`: untakes issues it won't get to, so the next conversation
    can take them.
  - `ai-todo-watch outcome <key> fixed|needs_you|cant_fix "<note>"`.
  - `ai-todo-watch overwhelmed "<why>"`: pushes the user (with sound outside quiet hours). The
    prompt tells the agent to use it when there are more issues than it can handle well, or the
    work is bigger than a fix it can verify, and then to release what it won't do.
- **The hub also notifies "overwhelmed"** on its own, once per day at most, when more than 20
  issues are open and untaken, or an issue has been open and untaken for over 24 hours. *My
  call* on both numbers.
- When a conversation finishes, issues it took without reporting an outcome go back to untaken.
  Issues marked `cant_fix` or `needs_you` stay taken until the user presses **Try again** in the
  app. *My call:* this is what stops the endless loop.
- The conversations run as runs of a hidden manual conversation job per watch job,
  `Debug · <watch job>`: urgent, always run, the watch job's tool, project and computer. The hub
  fills in the repo folder per run, so the runner makes the worktree there. Two of its runs may be
  at work at once, which other jobs don't allow.
- Todo title `Fix Sentry issues · <repo> · <date>`. The prompt: the issues' titles, details and
  URLs, marked as data; group issues that share a cause; for each, find the cause, write a fix
  with a test where possible, commit it on the worktree's branch, and report its outcome with
  `ai-todo-watch outcome`; summarize at the end; do not resolve or change anything in Sentry; do
  not push or deploy. Then the job's extra instructions.
- Being urgent, their "needs you" and "finished" pushes work as usual.

### New-issue pushes

- An issue appearing (first seen by the watcher, or back after clearing) pushes once:
  `<watcher> · <title>`, silent during quiet hours. Several in one check make one push
  ("3 new Sentry issues").
- The first check of a job pushes nothing: the backlog is listed in the app and taken by
  conversations, without a burst of pushes. *My call.*

### Resolve in Sentry

- The app asks the hub to resolve an issue. The hub marks it `resolving` and lists it to the watch
  job's computer in the runner's due answer.
- The runner runs `<watcher> resolve <key>` and reports the result. Success clears the issue.
  A failure puts it back with the error, shown in the app.
- Still `resolving` after 30 minutes (the Mac asleep or offline): back, with "this Mac didn't
  answer". *My call.*
- For 15 minutes after a successful resolve, a check that still lists the key is ignored for it
  (Sentry's API can lag). *My call.*

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

- Automation's sidebar gets **Watchers**, with a badge of open issues (Mac and iPhone).
- The list: open issues grouped by state (untaken; being worked on, by conversation; needs you;
  can't fix; fixed, waiting for deploy and resolve), then "Cleared in the last 7 days". The job's
  last check time and, if it failed, why.
- An issue's pane: details, the outcome note, **Open in Sentry**, **Open conversation**,
  **Resolve in Sentry** (asks first; shows "Resolving…" and any error), and **Try again** for
  needs-you and can't-fix issues.
- The job form gets the Watch kind: watcher name, computer, project, debug tool, extra prompt.

## Left to the builder

Table and endpoint names, the push wording, the list's layout within the existing Automation
look, how `ai-todo-watch` finds its conversation (it runs inside the worktree, like
`ai-todo-idea findings`), and where tests go.
