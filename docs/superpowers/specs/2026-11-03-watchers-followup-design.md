# Watchers follow-up: what happened, and watcher plugins

Follow-up to `2026-11-02-watchers-design.md`, from the user's first look at the live Sigma
Sentry watcher (2026-11-03).

## Intent

The first debugging conversation fixed 5 issues on a branch, but the app said only "Fixed ·
deploy, then resolve". The user couldn't tell what had happened, where the fix was, or what to
do, and wanted an easy way from a fixed issue to the conversation that owns it. Watchers should
also be pluggable: kept in the repo, but in their own folder, each describing itself.

## User's decisions

- An easy way from a fixed issue to its conversation.
- The issue page explains what happened, where the fix is, and the next steps.
- Watchers stay in the repo, in their own folder (not a separate repo).
- "The rest sounds fine": each watcher describes itself (name, description, settings it needs,
  whether it can resolve); the app lists the watchers installed on each computer; the job form
  picks from them.

## Design

### What happened, where the fix is, what next

- The runner tells the hub the branch it made for a run (start request gains `branch`). The hub
  keeps it on the run.
- `ai-todo-watch outcome <key> <outcome> "<note>" [--commit <sha>]...`: the agent names the
  commits of its fix. The prompt asks it to. The hub keeps them on the issue.
- A watcher issue (API) gains `branch`, `worktree` (the conversation's folder) and `commits`.
- The "fixed" group is renamed **Fixed on a branch · waiting for your merge**.
- The issue page has three parts:
  - **What happened:** the outcome in words and the agent's note.
  - **Where the fix is:** branch, worktree folder and commits, each copyable. Nothing was
    merged, pushed or deployed.
  - **Next:** for fixed issues, 1. review it in the conversation, 2. merge and deploy it
    yourself, 3. press Resolve in Sentry. For needs-you, answer in the conversation, then Try
    Again. For can't-fix, read why; Resolve if it was a one-off, or Try Again.
- Every issue row taken by a conversation has an **Open Conversation** button (and context-menu
  item); the page's button stays.

### Watcher plugins

- Watchers live in `ai-session-remote/watchers/<name>/`: the executable `watcher` and a
  `watcher.json` manifest:
  `{"name", "title", "description", "settings": [{"key", "label", "secret"}], "resolve": bool,
  "resolve_label"}`.
- `install.sh` copies each to `~/.ai-remote/watchers/<name>` (executable, unchanged contract)
  and `~/.ai-remote/watchers/<name>.json`. The env file is untouched.
- The runner reports the installed watchers to the hub when they change (and at least once a
  day): manifest fields plus, per setting, whether it is set in the env file. Never values.
- The hub keeps them per computer (`GET /api/computers/{id}/watchers` or in the computer list).
- The app's job form: Watch kind picks the computer first, then a watcher installed there, and
  shows its description and which settings are missing. Issue buttons use the watcher's
  `resolve_label` ("Resolve in Sentry"), and Resolve is hidden for watchers that can't resolve.

## Left to the builder

Endpoint and column names, how often the runner re-reports, layout within the existing panes.
