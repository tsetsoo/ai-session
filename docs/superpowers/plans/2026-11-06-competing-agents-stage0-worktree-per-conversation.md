# Competing agents, stage 0: worktree per conversation, implementation plan

> **Superseded (2026-11-06).** Another session shipped worktree per conversation to main first (855de62, e861274), so this plan's implementation (branch `scheduled/research-now-ai-session-20261106-3ff0dec9`) was not merged. Only what main lacked was ported: worktrees of not-done todos are kept by cleanup (`keep_worktrees`, commit 130d944).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new conversation started from the app in a project with worktrees on runs in its own git worktree, `~/.ai-remote/worktrees/<project>/<conversation>`. That worktree survives while its todo is open, and a missing one is recreated when the conversation is reopened.

**Architecture:**
1. The hub plans the worktree when it creates the conversation: `cwd` = the planned path, plus `worktree_from` (the project folder) and `branch`.
2. The host makes the worktree lazily. The app passes `--worktree <from> <branch> --conversation <id>` to `ai-todo-open`. When the cwd is missing, `ai-todo-open` runs `ai-todo-workspace prepare`, which creates the worktree, or re-adds it from its branch. If the actual cwd differs (a folder that isn't a repo, or a monorepo subfolder), prepare PUTs it to the hub.
3. The runner's cleanup sweep skips every worktree the hub lists as belonging to a not-done todo on that computer.

Everything happens on the host, so the Mac, the iPhone, attach and detached starts all share one path.

**Tech Stack:** Rust (actix-web, rusqlite) in `todo-app/crates`; Python 3 host scripts in `ai-session-remote/scripts/todo`; POSIX sh `ai-todo-open`; Swift (AISessionCore + SwiftUI app).

**Spec:** `docs/superpowers/specs/2026-11-06-competing-agents-design.md` (stage 0)

## Global Constraints

- Worktree path: `~/.ai-remote/worktrees/<project_id>/<conversation_id>`. Branch: `ai/<slug of todo title, ≤40>-<first 8 of conversation id>`.
- On by default in every project (`projects.worktrees` default 1). Each project can opt out.
- Existing conversations are never moved. Only conversations created after this change get `worktree_from`.
- A folder that isn't a git repo: the conversation runs in the project folder, as today.
- Schema: bump `SCHEMA_VERSION` to the next free value. It is 22 on `main` today; another unmerged branch plans 23, so re-check before merging.
- Older hosts and apps keep working: no `worktree_from` → no new arguments. Deploy order is hosts (`install.sh`), then the hub, then the apps.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. In this scheduled conversation: no push, merge, install or deploy.

## Review Focus

1. **Monorepo subfolder project** (folder = `repo/app`): the conversation opens in `<worktree>/app`, and the hub's cwd is updated to it. → test in Task 2.
2. **Reopen after the worktree directory was deleted but the branch remains**: re-added from the branch, with commits intact, not a fresh branch. → test in Task 1.
3. **Branch deleted too** (for example, merged and pruned): a fresh worktree on the same branch name from origin/HEAD, with a one-line notice printed in the terminal. It never falls back to the shared project folder. → test in Task 1.
4. **Hub unreachable during a tick**: no sweep at all, rather than a sweep with an empty keep list that deletes kept worktrees. → test in Task 5.
5. **Two opens of the same new conversation at once** (Mac and iPhone): the second `prepare` finds the worktree already there and reuses it. → test in Task 1.

---

### Task 1: `ai_todo_workspace`: base, prepare, keep-aware sweep

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai_todo_workspace.py` (`create`, new `prepare`, `sweep`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new block after the merged-cleanup block near line 3200)

**Interfaces:**
- Produces:
  - `create(folder, path, branch, base=None) -> (cwd, entry)`. `base` is a sha or ref; `None` keeps today's `origin/HEAD` else `HEAD`.
  - `prepare(folder, path, branch) -> dict` with keys `cwd`, `is_git: bool`, `branch: str|None`, `base: str|None`, `entry: dict|None`, `notice: str|None`.
  - `sweep(registry_path, older_than, log=..., keep=())`. `keep` is an iterable of absolute paths.

- [ ] **Step 1: Write failing tests** in the shell harness (Python heredoc, the style of the surrounding blocks), using a temp repo with an origin:
  - `prepare` on a fresh path: `is_git` true, the worktree exists on `branch`, and `base` equals `git rev-parse origin/HEAD`.
  - Calling `prepare` again with the same args: the same `cwd`, and no error (Review Focus 5).
  - Delete the worktree directory and run `git worktree prune`, keeping the branch with one extra commit; then `prepare`: that commit is in `HEAD`, and `notice` is None (Review Focus 2).
  - Delete the branch too, then `prepare`: a new worktree on the same branch name at origin/HEAD, and `notice == "The worktree's branch was gone; started a new one from origin/HEAD."` (Review Focus 3).
  - `prepare` on a non-repo folder: `{"cwd": folder, "is_git": False, "branch": None, "base": None}`.
  - A repo subfolder `app`: `cwd` ends with `/app`.
  - `sweep(..., keep=[<worktree path>/app])` on a clean, old entry: kept. The same call without `keep`: removed.
- [ ] **Step 2: Run** `scripts/todo/test-todo-scripts.sh` from `ai-session-remote/`. Expected: the new block fails (`prepare` is not defined).
- [ ] **Step 3: Implement.**
  - `create`: use `base` when given.
  - `prepare` has three cases:
    - The path is already a worktree on `branch`: return it.
    - The path is missing and `git rev-parse --verify refs/heads/<branch>` succeeds: run `git worktree prune`, then `git worktree add <path> <branch>`, then `bring_local_files`.
    - Otherwise: `create`.
    - `NotARepo` → the non-git dict.
  - `sweep`: skip any entry whose real path equals, or is a parent of, the real path of any `keep` item.
- [ ] **Step 4: Run** the harness. Expected: `PASS` lines for the new block, and no regressions.
- [ ] **Step 5: Commit** `feat(scripts): workspace prepare re-adds a worktree from its branch; sweep keeps listed paths`

### Task 2: `ai-todo-workspace prepare` command

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-workspace` (usage docstring, `cmd_prepare`)
- Modify: `ai-session-remote/scripts/todo/fixtures/fake-hub.py` (record `PUT /api/conversations/<id>/workspace`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`

**Interfaces:**
- Consumes: `workspace.prepare` (Task 1).
- Produces: CLI `ai-todo-workspace prepare <folder> <path> <branch> [--conversation <id>]`.
  - Prints JSON `{"cwd","is_git","branch","base","notice"}`, with paths in `~` form.
  - Registers the entry in `worktrees.json` under the key `conv:<id>` (or `path:<path>` without `--conversation`).
  - With `--conversation`, when the returned cwd ≠ `<path>` or `is_git` is false, it PUTs `/api/conversations/<id>/workspace` with `{"cwd": <~cwd>, "branch": <branch|null>, "base_sha": <base|null>}`, using `~/.ai-remote/todo-hub.conf`. A hub error goes to stderr and the exit stays 0.
  - Exit codes: 64 bad args, 1 git failure.

- [ ] **Step 1: Write failing tests**: prepare in a temp repo prints JSON with `is_git: true` and registers `conv:c1`; the subfolder case makes the fake hub receive the PUT with cwd ending in `/app`; the non-repo case PUTs `branch: null`.
- [ ] **Step 2: Run** the harness. Expected: FAIL (unknown command).
- [ ] **Step 3: Implement `cmd_prepare(args)`**. The registry write goes under `workspace.locked_registry`. For the hub call, use the same request helper pattern as `ai-todo-idea`.
- [ ] **Step 4: Run** the harness. Expected: PASS.
- [ ] **Step 5: Commit** `feat(scripts): ai-todo-workspace prepare, reporting a changed cwd to the hub`

### Task 3: `ai-todo-open --worktree`

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-open` (option loop around line 100; the cwd check at line 382)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`

**Interfaces:**
- Consumes: `ai-todo-workspace prepare` (Task 2).
- Produces: leading options `--worktree <from> <branch>` and `--conversation <id>`, in any order with the existing ones.

- [ ] **Step 1: Write failing tests**, using the existing fake-claude setup:
  - With `--worktree` and a missing cwd, the tool starts in the prepared worktree: the fake records its `pwd`.
  - With an existing cwd, prepare is not called. Use an `AI_TODO_WORKSPACE_BIN` stub that fails if run.
  - When prepare prints a `notice`, it appears on stderr before the tool starts.
  - When prepare fails, the exit code is 93 with `worktree could not be prepared: <stderr tail>`.
- [ ] **Step 2: Run.** Expected: FAIL (usage error on `--worktree`).
- [ ] **Step 3: Implement.**
  - Parse both options; the branch must match `[A-Za-z0-9._/-]+`.
  - Before the `[ -d "$cwd" ]` check: if `--worktree` was given and the cwd is missing, run `${AI_TODO_WORKSPACE_BIN:-$(dirname "$0")/ai-todo-workspace} prepare "$from" "$cwd" "$branch" ${conv:+--conversation "$conv"}` and set `cwd` from the JSON `cwd`, read with `python3 -c`.
  - The running-session fast path (line ~180) stays first, so attaching to a live session costs nothing extra.
- [ ] **Step 4: Run.** Expected: PASS, with the existing ai-todo-open tests unchanged.
- [ ] **Step 5: Commit** `feat(scripts): ai-todo-open prepares a conversation's worktree when it is missing`

### Task 4: Hub: plan worktrees, workspace report, keep list

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs`:
  - migration: `projects.worktrees INTEGER NOT NULL DEFAULT 1`, `conversations.worktree_from TEXT`, `conversations.branch TEXT`;
  - `conversations_ddl`, `projects_ddl`, `SCHEMA_VERSION`.
- Modify: `todo-app/crates/todo-shared/src/lib.rs`: `Project.worktrees: bool`, `UpdateProjectRequest.worktrees: Option<bool>`, `Conversation.worktree_from: Option<String>`, `Conversation.branch: Option<String>`.
- Modify: `todo-app/crates/todo-server/src/conversations.rs`: `open_conversation_in`, new `set_conversation_workspace_by_id`, and the row loaders.
- Modify: `todo-app/crates/todo-server/src/projects.rs`: `update_project_db` and the loaders.
- Modify: `todo-app/crates/todo-server/src/runner_api.rs`: `DueResponse.keep_worktrees: Vec<String>`.
- Modify: `todo-app/crates/todo-server/src/main.rs`: route `PUT /api/conversations/{id}/workspace`.
- Test: in-file `#[cfg(test)]` modules of `conversations.rs`, `projects.rs`, `runner_api.rs`, and the migration test in `db.rs`.

**Interfaces:**
- Produces:
  - `POST /api/todos/{id}/conversation` for a new conversation in a project with `worktrees = 1`: `cwd = "~/.ai-remote/worktrees/<project_id>/<id>"`, `worktree_from = <project folder>`, `branch = "ai/<slug>-<id[..8]>"`. With `worktrees = 0`: as today, with both fields null.
  - `PUT /api/conversations/{id}/workspace` with body `{cwd: String, branch: Option<String>, base_sha: Option<String>}`. It sets `cwd` and `branch`; when `branch` is null it also clears `worktree_from`. Returns the Conversation, 404 if unknown, 400 for an empty cwd. `base_sha` is accepted but not stored yet (stage 2 stores it).
  - `GET /api/runner/due` gains `keep_worktrees`: the `cwd`s of conversations on that computer whose todo has `completed = 0` and whose cwd starts with `~/.ai-remote/worktrees/`.
  - `slug(title) -> String` in `conversations.rs`: lowercase, runs of non-`[a-z0-9]` become `-`, trimmed, ≤40 chars, `"todo"` when empty. Same rule as the runner's `slug`.

- [ ] **Step 1: Write failing tests:**
  - `open_plans_worktree`: a project with the default setting gives the cwd, `worktree_from` and branch above, for todo title "Fix the Login!" → branch prefix `ai/fix-the-login-`.
  - `open_without_worktrees_keeps_folder`: PATCH `worktrees:false`, then open → cwd = project folder, both fields null.
  - `reopen_keeps_planned_cwd`: a closed conversation reopened keeps its cwd and branch.
  - `workspace_report_updates_cwd`: PUT a subfolder cwd → returned; PUT `branch:null` → `worktree_from` null.
  - `due_lists_keep_worktrees`: two conversations under `~/.ai-remote/worktrees/` (one with an open todo, one completed) and one in a plain folder → only the open one listed, and only for its computer.
  - Migration test: a v22 database gains the three columns, with existing rows null and projects `worktrees = 1`.
- [ ] **Step 2: Run** `cargo test` in `todo-app/`. Expected: compile errors or FAIL.
- [ ] **Step 3: Implement.**
  - In `open_conversation_in`, after `insert_conversation` returns the id, run `UPDATE conversations SET cwd, worktree_from, branch` in the same transaction when the project's `worktrees = 1`.
  - Return `keep_worktrees` from the same `checked_in` closure that builds `DueResponse`.
- [ ] **Step 4: Run** `cargo test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(hub): conversations get their own worktree by default; workspace report; runner keep list`

### Task 5: Runner sweeps with the keep list

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-runner` (`cleanup_worktrees`, `cmd_tick` around line 619, header comment)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (fake hub: `keep_worktrees` in the due answer)

**Interfaces:**
- Consumes: `workspace.sweep(..., keep=)` (Task 1), `due["keep_worktrees"]` (Task 4).
- Produces: `cleanup_worktrees(keep)`, called only after a successful `GET /api/runner/due`, with `keep` expanded from `~`.

- [ ] **Step 1: Write failing tests**:
  - An old, clean worktree whose path is in `keep_worktrees` survives a tick.
  - With the fake hub returning 500 for due, the same tick removes nothing (Review Focus 4).
  - The existing merged-cleanup block still passes when `keep_worktrees` is absent: treat a missing key as `[]` only when due succeeded.
- [ ] **Step 2: Run.** Expected: FAIL (kept worktree removed).
- [ ] **Step 3: Implement.** Move the cleanup call after the due fetch and skip it on `HubError`. Update the header comment: "kept while a not-done todo's conversation works in it".
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(runner): never sweep a worktree an open todo's conversation uses`

### Task 6: App: pass the worktree to `ai-todo-open`; project toggle

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift` (`Conversation.worktreeFrom`, `branch`, optional, snake_case keys)
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/ProjectModels.swift` (`Project.worktrees: Bool`, decoding a missing key as `true`; the update request field)
- Modify: `ai-session-remote/Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`: `openTodoConversation(...)` and `freshTodoConversation(...)` gain `worktree: (from: String, branch: String)? = nil, conversationId: String? = nil`.
- Modify: every caller that has a `Conversation`: `App/AISessionRemote/Views/Frame/ConversationLoader.swift`, `App/AISessionRemote/Services/TodoHubStore.swift` (`openConversation`). Pass `conversation.worktreeFrom`/`branch`/`id`.
- Modify: `App/AISessionRemote/Views/Projects/ProjectEditorSheet.swift`: a toggle "Own worktree for each new conversation", saved through the existing project update.
- Test: `ai-session-remote/Tests/AISessionCoreTests/TmuxCommandBuilderTests.swift` (or the existing builder test file), plus a model decoding test.

**Interfaces:**
- Consumes: hub fields from Task 4; `ai-todo-open` options from Task 3.

- [ ] **Step 1: Write failing tests:**
  - `openTodoConversation(..., worktree: ("~/w/app", "ai/x-1234abcd"), conversationId: "c1")` contains `--worktree '~/w/app' 'ai/x-1234abcd' --conversation 'c1'` before the tmux name.
  - With `worktree: nil` the command is byte-identical to today's.
  - The same two checks for `freshTodoConversation`.
  - `Conversation` decodes `worktree_from`/`branch`, and decodes without them.
  - `Project` without `worktrees` decodes as `true`.
- [ ] **Step 2: Run** `swift test` in `ai-session-remote/`. Expected: FAIL.
- [ ] **Step 3: Implement.** Options go after `--mcp`, using the existing `shellQuote`.
- [ ] **Step 4: Run** `swift test`, then `xcodegen generate && xcodebuild -scheme AISessionRemoteMac -configuration Debug build` (and the iOS scheme). Expected: tests pass, both build.
- [ ] **Step 5: Commit** `feat(app): conversations open in their worktree; per-project worktree toggle`

### Task 7: End-to-end check on this Mac (manual, after review)

- [ ] Rebuild the hub locally with `cargo run -p todo-server` against a copy of the DB, or verify with the test suites only if the user doesn't want a local hub. Run the scripts from the worktree with `AI_TODO_*` test hooks. Confirm that a new conversation in `ai-session` starts in `~/.ai-remote/worktrees/<project>/<id>` on branch `ai/...`. Then delete the directory, reopen, and confirm it is re-added from the branch.
- [ ] Report the result. Installing on hosts, the Pi deploy and the app rebuild wait for the user's go.
