# Watchers Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Issue pages say what happened, where the fix is and what to do next, rows open their conversation, and watchers are self-describing plugins in their own folder that the app can list per computer.

**Architecture:** Hub v16 adds `job_runs.branch`, `watch_issues.commits`, `computers.watchers` (all additive). The runner sends the branch at start and reports installed watchers (manifests + which settings are set). `ai-todo-watch outcome` takes `--commit`. The app shows the new fields and picks watchers from the computer's list.

**Spec:** `docs/superpowers/specs/2026-11-03-watchers-followup-design.md`

## Global Constraints

- Setting values never leave the Mac: the watcher report carries only `set: bool` per key.
- Commits accepted only as hex 7–40 characters, at most 20 per issue.
- Group title copy: `Fixed on a branch · waiting for your merge`.
- Watchers folder: `ai-session-remote/watchers/<name>/watcher` + `watcher.json`; installed to `~/.ai-remote/watchers/<name>` and `<name>.json`.
- Runner re-reports watchers when the report changes, or once every 24 h.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; clippy `-D warnings` before push.

## Review Focus

1. An old runner (no `branch` in start) and an old hub (404 on the watchers report) must keep working — tests in Task 1 (`start_without_branch_still_works`) and Task 2 (`runner_watchers_report_404_is_quiet`).
2. A watcher manifest that is missing or bad JSON must not stop the others from being reported — Task 2 (`runner_reports_watchers_skipping_bad_manifest`).
3. An issue whose conversation todo was deleted still lists (branch/worktree null) — Task 1 (`issue_lists_without_conversation`).

---

### Task 1: Hub — branch, commits, worktree, watchers per computer

**Files:** `todo-shared/src/lib.rs`, `todo-server/src/{db.rs,runner_api.rs,watch.rs,conversations.rs or watch.rs,main.rs}`

**Produces:**
- `StartRequest.branch: Option<String>` → `job_runs.branch`.
- `OutcomeRequest.commits: Vec<String>` (default empty) → `watch_issues.commits` (JSON array text); invalid sha → 400.
- `WatchIssue` gains `branch: Option<String>`, `worktree: Option<String>`, `commits: Vec<String>` (serde default).
- `WatcherInfo { name, title, description, settings: Vec<WatcherSetting{key,label,secret,set}>, resolve: bool, resolve_label: Option<String> }`; `PUT /api/computers/{id}/watchers` (body `Vec<WatcherInfo>`, 404 unknown computer) and `GET /api/computers/{id}/watchers` (empty list when never reported).
- `FIX_PROMPT` outcome line becomes `~/.ai-remote/bin/ai-todo-watch outcome <key> fixed|needs_you|cant_fix "<one-line note>" [--commit <sha>]...` and asks to name the fix's commits.

- [ ] Tests: `start_stores_branch`, `start_without_branch_still_works`, `outcome_keeps_commits_and_rejects_bad_sha`, `issue_lists_branch_worktree_commits`, `issue_lists_without_conversation`, `watchers_report_round_trips`, `v15_migrates_to_v16`.
- [ ] RED, implement, GREEN, clippy, commit `feat(hub): branch, commits and watchers per computer`.

### Task 2: Scripts — plugin folder, branch, watchers report, --commit

**Files:** move `scripts/todo/watchers/sentry` → `ai-session-remote/watchers/sentry/watcher`; create `ai-session-remote/watchers/sentry/watcher.json`; modify `install.sh`, `ai-todo-runner`, `ai-todo-watch`, `test-todo-scripts.sh`, `fixtures/fake-hub.py`.

- install.sh: `WATCHERS_SRC` = `${SRC_DIR}/../../watchers` when it exists, else `${SRC_DIR}/watchers` (the helper tarball carries it as `watchers/`); copies `watcher` → `<name>`, `watcher.json` → `<name>.json`.
- Runner: start body gains `branch`; each tick builds the watchers report (every `<name>.json` with an executable `<name>` beside it; settings `set` from the env file), sends `PUT /api/computers/<id>/watchers` when its hash changed or 24 h passed (state in `runner-state/watchers.json`); 404 → remember and retry after 24 h, no error.
- `ai-todo-watch outcome … [--commit <sha>]...` → body `commits`.

- [ ] Tests: `runner_start_sends_branch`, `runner_reports_watchers_skipping_bad_manifest` (no values, only `set`), `runner_watchers_report_once_until_changed`, `runner_watchers_report_404_is_quiet`, `watch_helper_outcome_with_commits`, `install_places_watcher_plugin_and_manifest`; existing sentry tests point at the new path.
- [ ] RED, implement, GREEN (full suite), commit `feat(scripts): watcher plugins with manifests; runner reports watchers and branches`.

### Task 3: Swift core

**Files:** `Sources/AISessionCore/TodoHub/WatchModels.swift`, `TodoHubClient.swift`; test `Tests/AISessionCoreTests/WatchTests.swift`.

- `WatchIssue`: `branch`, `worktree`, `commits` (decode missing as nil/[]); `outcomeText` ("Fixed by the conversation", "Needs your decision", "Can't be fixed in code", "Being worked on", "Waiting for a conversation", "Resolving…", "Cleared"); `nextSteps: [String]` per group as the spec says.
- `WatchIssueGroup.fixed.title` = `Fixed on a branch · waiting for your merge`.
- `WatcherInfo`/`WatcherSetting` models; `missingSettings`; client `listWatchers(computerId:)`.

- [ ] Tests: `issueDecodesNewFieldsAndOldHub`, `nextStepsPerGroup`, `fixedGroupTitle`, `watcherInfoMissingSettings`, `clientListsWatchers`.
- [ ] RED, implement, GREEN, commit `feat(core): issue story, next steps, watcher info`.

### Task 4: App

**Files:** `WatchersPanes.swift`, `JobsPanes.swift`, `TodoHubStore.swift`.

- Issue page: What happened / Where the fix is (branch, worktree, commits with Copy) / Next steps; Resolve button label from the watcher's `resolve_label`, hidden when `resolve` is false (unknown watcher info → shown as "Resolve").
- Rows: trailing Open Conversation button and context-menu item when `todoId` exists.
- Job form (Watch): Computer first; watcher Picker from `store.watchers(computerId)` (falls back to the text field when the list is empty); description and missing settings shown.
- Store: `watchersByComputer`, `loadWatchers(computerId:)`.

- [ ] App tests + Mac build pass; commit `feat(app): what happened, where the fix is, watcher picker`.
