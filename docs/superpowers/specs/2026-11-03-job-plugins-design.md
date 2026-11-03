# Stage 5: job plugins (weekly upkeep, memory gardener)

Stage 5 of the scheduler (`2026-11-02-scheduler-design.md`, section 8), narrowed by the user on
2026-11-03: only **Weekly upkeep** and **Memory gardener** for now, and ready-made jobs are
**plugins**, like the Sentry watcher.

## User's decisions

- Build Weekly upkeep (Sunday 10:00, per chosen project: dependency updates and advisories,
  changes on a branch) and Memory gardener (Sunday 03:00: merge duplicates, retire stale).
- The gardener **acts directly** (archives; undoable in the app), no approval step.
- Ready-made jobs are plugins in their own folder of the repo, each a manifest plus a prompt.
  Memory actions belong to `ai-todo-memory` (memories are core), not to the plugin.

## Design

### Job plugins

- `ai-session-remote/jobs/<name>/job.json` + `prompt.md`. Manifest: `name`, `title`,
  `description`, `cron`, `tool` (`claude`|`codex`), `model` (optional), `priority`
  (`background`|`urgent`), `limit` (`wait`|`always`), `project` (`choose`, or a project name
  as the default, e.g. `ai-session`).
- `install.sh` copies them to `~/.ai-remote/jobs/<name>/` (beside `scripts/todo`, like watchers).
- The runner reports installed job plugins (manifest + prompt) to the hub with the watchers
  report: `PUT /api/computers/<id>/job-templates`. The hub keeps them per computer; `GET
  /api/job-templates` returns them across computers (one per name, the newest).
- The app's Jobs "+" menu gets **From template**: picking one fills the job form (name
  "<title> · <project>", cron, conversation with the prompt, tool/model/priority/limit,
  computer = the one that reported it). The user chooses the project and saves; it's then an
  ordinary job.

### Weekly upkeep (`jobs/weekly-upkeep`)

- Sunday 10:00, background, waits for headroom, Claude; project: choose.
- Prompt: find the project's package managers; check updates and advisories with what's there
  (`cargo update --dry-run`/`cargo audit`, `npm outdated`/`npm audit`, `go list -m -u all`/
  `govulncheck`, Swift packages); apply safe updates (patch/minor, and anything fixing an
  advisory) with tests passing; commit on the branch; summarize what changed and what was left
  (majors, breaking changes). Never push.

### Memory gardener (`jobs/memory-gardener`)

- Sunday 03:00, background, waits for headroom, Claude; project default `ai-session` (memories
  of all projects are in scope).
- `ai-todo-memory` gains:
  - `garden [--json]`: from the local cache (refreshed first): groups of near-duplicates within a
    project (word overlap ≥ 0.6 on normalized text), and per project the memories never used
    and older than 60 days. Never lists pinned, manual or archived ones.
  - `retire <id>... --reason duplicate|retired`: archives them with that reason (the hub's
    `archived_reason`; the user's own archives are `user`). Refuses pinned and manual ones.
  - `edit <id> "<text>"`: replaces a memory's text (for a merge, the one kept absorbs the
    others' details). Refuses manual ones. Redacted.
- The hub's memory update accepts `archived_reason: duplicate|retired` with `archived: true`.
- Prompt: run `garden`; for each duplicate group keep the best one (edit it to include
  anything only the others say), retire the rest as `duplicate`; retire memories that are
  outdated or contradicted by newer ones as `retired`; when unsure, leave it; end with a list
  of what was archived and why.

## Non-goals

Nightly health, stale sweep, release watch, re-ping (not now). A model call on the hub.
