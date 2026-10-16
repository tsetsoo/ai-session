# Projects, Memories and Stats — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement your track task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. You own ONE track (S, H or A). The spec is the contract between tracks: never change a JSON shape, an endpoint, a CLI flag or a file location it fixes. If the spec is wrong or ambiguous, stop and report it instead of guessing.

**Goal:** Projects, conversation memories (extracted on each computer with `claude -p`) fed back through a managed digest file, and per-day usage stats, across todo-server, the host scripts and the SwiftUI app.

**Architecture:** The Pi stores data (schema v3: `projects`, `sessions`, `session_days`, `memories`, `todos.project_id`). Each computer's `ai-todo-memory` and `ai-todo-sessions stats` do all the reading, extracting and rendering, and push only memories and numbers. The app displays and edits.

**Tech Stack:** Rust (nightly, Actix-web 4, rusqlite + r2d2, serde); POSIX sh + embedded Python 3 (stdlib only); Swift 5.9 / SwiftUI (iOS 17, macOS 14), xcodegen.

**Spec:** `todo-app/docs/superpowers/specs/2026-10-16-todo-projects-memories-design.md` (branch `docs/projects-memories-spec`). Read it fully before starting. Section names below refer to it.

## Global Constraints

- Section codes `Sp`, `I`, `Si`, `P` are opaque. Never expand or describe them anywhere: code, UI, prompts, docs or tests.
- Schema version 3 via a numbered `migrate()` step with `backup_before_migration(conn, db_path, 3)`. Additive only; no table rebuilds.
- New fields on existing JSON types are optional and omitted when null (`#[serde(default, skip_serializing_if = "Option::is_none")]`). Old apps and old scripts must keep working unchanged.
- No nesting: on one computer, a project folder may not be inside, or contain, another project's folder. Violations → `409`.
- Memory kinds are exactly `decision | gotcha | open_thread | done | files_changed`. Text is 1–400 chars, `files` ≤ 20, `confidence` 0–1.
- `text_key` normalization is Unicode-aware. Lowercase, then each maximal run of characters that are not `char::is_alphanumeric` (Rust) / `str.isalnum` (Python) becomes one space, then trim. Cyrillic text must keep its letters.
- Host scripts must not edit `~/.claude/settings.json` beyond what `install.sh` already merges. They never call the real `claude` in tests, and never read or write the real `~/.claude`, `~/.codex` or `~/.ai-remote` in tests.
- Never `git push` to main, never force-push, never merge. Commit on your track's branch only.
- Rust: `cargo test -p todo-server -p todo-shared` and `cargo clippy -p todo-shared -p todo-server -- -D warnings` must be green. The frontend also depends on `todo-shared`, so `cargo clippy -p todo-frontend --target wasm32-unknown-unknown -- -D warnings` must stay green (install the target with rustup if missing).
- Swift: `swift test` (AISessionCore) plus both schemes built with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:
  - iOS: `xcodebuild -scheme AISessionRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
  - macOS: `xcodebuild -scheme AISessionRemoteMac -destination 'platform=macOS' build`

  After adding files, regenerate the project with `xcodegen generate` and commit the regenerated `project.pbxproj`.

## Review Focus

1. **Partial last line in a transcript** (Claude is writing while we read): the reader must ignore a trailing line without `\n`. The offset may only ever point just past a complete `\n`-terminated line that ends a complete turn. → Track H, Task H3 test `partial_trailing_line_is_not_consumed`.
2. **Hub unreachable or erroring during a run:**
   - No offset advances.
   - The digest is **not** removed or emptied: a failed memories fetch is not the same as "no memories".
   - `projects.json` keeps its last good copy.

   → Track H, Task H5 tests `hub_down_keeps_offsets` and `hub_down_keeps_digest`.
3. **Cyrillic and emoji text** in memories and titles:
   - `text_key` keeps the letters, so two different Bulgarian memories don't collide as duplicates.
   - Redaction doesn't mangle them.
   - The 400-char limit counts characters, not bytes, in Rust and Python alike.

   → S3 test `cyrillic_memories_are_not_duplicates`, H2 test `redaction_keeps_unicode`.
4. **Path spellings of the same folder:** `~/x`, `/Users/<username>/x`, `~/x/`, `~//x`, and the macOS `/private/var/...` vs `/var/...` temp paths in tests. Matching must treat the first four as equal and must never match `~/xy` against `~/x`. → S1 tests, H4 test `digest_target_accepts_trailing_slash`.
5. **Older installs:**
   - A host whose `ai-todo-hook` runs without `ai-todo-memory` installed, or with a `todo-hub.conf` lacking `TODO_COMPUTER_ID`, must still exit 0 and post status as before.
   - An app build from before this change must still decode `Todo` and `Conversation` JSON that now carry `project_id`.

   → H6 test `hook_without_memory_binary_still_posts_status`, A1 test `decodesTodoWithAndWithoutProjectId`.

---

## Track S — todo-server (repo `todo-app`)

Worktree `/Users/tsvetelinpantev/programming/todo-app/.claude/worktrees/projects-memories-server`, branch `feature/projects-memories-server` (from `origin/main`). Follow the existing style of `conversations.rs`: small `*_db(conn, …)` functions with unit tests on a `TestDb`, and thin async handlers that map errors to the `error()` helpers. New modules: `paths.rs`, `projects.rs`, `sessions.rs` (sessions + stats + weekly), `memories.rs`. Shared types go in `todo-shared/src/lib.rs`.

### Task S1: Schema v3, path matching, shared types

**Files:** Modify `crates/todo-server/src/db.rs`, `crates/todo-shared/src/lib.rs`, `crates/todo-server/src/handlers.rs` (`SELECT_COLS` + `project_id`), `crates/todo-server/src/models.rs`, `crates/todo-frontend` only if it fails to compile. Create `crates/todo-server/src/paths.rs`.

**Interfaces — Produces:**
- `db::SCHEMA_VERSION = 3`. `db::projects_ddl()`, `sessions_ddl()`, `session_days_ddl()`, `memories_ddl()`, plus the indexes, exactly as in the spec's "Data model".
- `paths::normalize(path: &str, username: &str) -> String`: `~`-form, no trailing `/`, `//` collapsed. `/Users/<username>` and `/home/<username>` become `~`.
- `paths::is_within(path: &str, folder: &str) -> bool`: segment-prefix test, equality included.
- `paths::best_project<'a>(cwd: &str, projects: &'a [(String /*id*/, String /*folder*/)]) -> Option<&'a str>`: longest folder that `cwd` is within.
- `paths::suggestion_folder(cwd: &str) -> String`: strip `/.claude/worktrees/<x>…`, then cut to 2 segments below `~` (3 for absolute paths).
- `todo_shared`: `Project`, `CreateProjectRequest`, `UpdateProjectRequest`, `ProjectSuggestion`, `Session`, `SessionStats`, `SessionDay`, `SessionStatsUpload { computer_id, sessions: Vec<SessionUpload> }`, `SessionUpload`, `SetSessionProjectRequest`, `Memory`, `MemoryKind`, `CreateMemoryRequest`, `BulkMemoriesRequest`, `NewMemory`, `BulkMemoriesResponse`, `UpdateMemoryRequest`, `WeeklyStats`, `StatsCounters`, `ProjectRollup`, `SectionRollup`, `ComputerRollup`.
  - Field names: exactly the spec's JSON keys.
  - `Todo.project_id`, `Conversation.project_id`, `CreateTodoRequest.project_id`: `Option<String>`.
  - `UpdateTodoRequest.project_id`: `Option<Option<String>>` (as `due_date`).
  - Nullable PATCH fields in `UpdateProjectRequest.repo_url` and `UpdateMemoryRequest.{project_id,todo_id}` use the same `Option<Option<_>>` pattern.

- [ ] **Step 1: Write failing tests:**
  - **In `db.rs` tests**, with a `V2_SCHEMA` fixture (today's Pi schema: v1 fixture tables in their v2 form plus rows):
    - `migrates_v2_to_v3_keeping_rows`: one backup; `user_version == 3`; all todos/conversations kept; `todos.project_id` exists and is NULL; the 4 new tables exist; a second open takes no new backup.
    - `fresh_database_is_v3_without_backup`.
    - `schema_version_reads_stored_3`.
  - **In `paths.rs`:**
    - `normalize_equates_spellings`: `~/x`, `/Users/me/x`, `~/x/` and `~//x` → `~/x` for username `me`.
    - `within_respects_segments`: `~/x/y` is within `~/x`; `~/xy` is not.
    - `best_project_picks_longest`.
    - `suggestion_folder_strips_worktrees`: `~/programming/sigma-revenue/sigma-revenue-backend/.claude/worktrees/x` → `~/programming/sigma-revenue`; `~/programming` → `~/programming`; `/opt/a/b/c/d` → `/opt/a/b`.
  - **In `todo-shared`:**
    - `todo_without_project_omits_field`.
    - `update_todo_project_null_vs_absent`: `{"project_id":null}` → `Some(None)`; `{}` → `None`.
- [ ] **Step 2:** Run `cargo test -p todo-server -p todo-shared`; the new tests fail.
- [ ] **Step 3: Implement.**
  - `migrate()`: `if version == 2 { backup_before_migration(conn, db_path, 3)?; migrate_v2_to_v3(conn)?; }`. Run after the v1→v2 step, so v1 goes all the way to v3.
  - `migrate_v2_to_v3`: `ALTER TABLE todos ADD COLUMN project_id …` only if the column is missing, then the CREATEs.
  - `init_pool`: create the v3 tables and the index for fresh DBs (`IF NOT EXISTS`).
  - Add `project_id` to `SELECT_COLS` and `row_to_todo`.
- [ ] **Step 4:** All tests are green (old and new), then clippy (server, shared, frontend-wasm).
- [ ] **Step 5:** Commit `Add schema v3, path matching and shared types for projects, sessions and memories.`

### Task S2: Projects + todo project_id + suggestions

**Files:** Create `crates/todo-server/src/projects.rs`. Modify `handlers.rs` (create/update todo with `project_id`, `?project_id=` filter), `main.rs` (routes; register `/api/projects/suggestions` **before** `/api/projects/{id}`).

**Interfaces — Produces:**
- `projects::rematch_sessions(conn: &Connection, computer_id: &str) -> rusqlite::Result<()>`:
  - re-matches sessions without an override on that computer;
  - moves their memories (`UPDATE memories SET project_id = (session's) WHERE tool, session_id`);
  - clears overrides that point to a missing project.

  S3/S4 call it.
- `projects::project_for(conn, computer_id: &str, cwd: &str) -> rusqlite::Result<Option<String>>`.
- Handlers `list_projects, create_project, get_project, update_project, delete_project, project_suggestions`.

- [ ] **Step 1: Write failing tests:**
  - `create_rejects_duplicate_and_nested`:
    - `~/a` exists → `~/a` → 409;
    - `~/a/b` → 409 (inside);
    - `~/a/b` exists, then `~/a` → 409 (contains);
    - the same folders on another computer → OK.
  - `patch_folder_into_nesting_is_409`.
  - `create_and_patch_rematch_sessions`: sessions at `~/a/x` and `~/b` + project `~/a` → the first is matched. PATCH the folder to `~/b` → it flips. An overridden session never moves.
  - `delete_project_keeps_memories_and_clears_todos`.
  - `delete_computer_with_project_is_409`.
  - `suggestions_group_and_exclude`:
    - cwds `~/programming/sigma-revenue/x`, `~/programming/sigma-revenue/y/.claude/worktrees/z` and `~/Spread/Repository` → 2 suggestions, counts 2/1, ordered by count;
    - after creating `~/Spread/Repository`, only one is left;
    - a cwd `~/programming` is dropped while `~/programming/sigma-revenue` is a project (it would contain it).
  - `todo_project_id_create_patch_clear_filter`: unknown project → 404; `PATCH {"project_id":null}` clears; `GET /api/todos?project_id=` filters. The existing todo tests are still green.
  - `project_counts`: `open_todos`, `sessions`, `memories` (non-archived), `last_activity`.
- [ ] **Step 2:** The tests fail.
- [ ] **Step 3: Implement.**
  - Normalize `folder` with the computer's `username` on write.
  - Nesting check: load that computer's folders and test `is_within` both ways.
  - Suggestions use `paths::suggestion_folder` over `sessions.cwd ∪ conversations.cwd` per computer. A folder that is within, or contains, an existing project folder on that computer is excluded.
  - `repo_url`: from a session whose `repo_root` equals the folder.
- [ ] **Step 4:** Tests and clippy are green.
- [ ] **Step 5:** Commit `Add projects with nesting checks, suggestions and todo project assignment.`

### Task S3: Memories

**Files:** Create `crates/todo-server/src/memories.rs`; routes in `main.rs` (`/api/memories/bulk` before `/api/memories/{id}`).

**Interfaces — Produces:**
- `memories::text_key(text: &str) -> String`.
- `memories::jaccard(a: &str, b: &str) -> f64` (token sets of `text_key`).
- `memories::insert_bulk_db(conn, req: &BulkMemoriesRequest) -> Result<BulkMemoriesResponse, MemoryError>`: one IMMEDIATE transaction. It upserts a minimal session row via `sessions::ensure_session_db` (S4; until S4 lands, implement it in `sessions.rs` now).
- Handlers `list_memories, create_memory, bulk_memories, update_memory, delete_memory`.

- [ ] **Step 1: Write failing tests:**
  - `bulk_creates_session_and_resolves_project_and_todo`: a session linked to a todo through `conversations` → the memory has `todo_id`.
  - `dedup_exact_across_sessions_of_project`.
  - `dedup_fuzzy_same_kind_90_days`: Jaccard ≥ 0.8 → duplicate; 0.6 → inserted; a different kind → inserted.
  - `dedup_not_across_projects`.
  - `cyrillic_memories_are_not_duplicates`: `"Миграцията прави резервно копие"` vs `"Деплойът чака билда"` → both inserted, and their `text_key`s are non-empty.
  - `archived_memory_still_blocks_duplicate`.
  - `supersedes_archives_unpinned_same_project_only`: pinned, other-project and unknown ids are ignored.
  - `validation`: 401 chars → 400; 400 chars of Cyrillic → OK; 21 files → 400; confidence 1.5 → 400; bad kind → 400.
  - `list_filters_and_order`: `project_id`, `todo_id`, `kind=gotcha,decision`, `since`, `tool+session_id`, `pinned`, `include_archived`, `limit` capped at 1000; pinned first, then newest.
  - `patch_rekeys_and_conflicts`: an edit that collides with a same-session memory → 409.
  - `manual_create_requires_scope_and_inherits_todo_project`.
  - `todo_delete_nulls_memory_todo_id`.
- [ ] **Step 2:** The tests fail.
- [ ] **Step 3: Implement.** Fuzzy dedup loads `text_key` + kind of the project's memories from the last 90 days. A `NULL` project means session-scoped only.
- [ ] **Step 4:** Tests and clippy are green.
- [ ] **Step 5:** Commit `Add memories with project-wide dedup, supersedes and filters.`

### Task S4: Sessions, stats upload, overrides, weekly rollup

**Files:** Create `crates/todo-server/src/sessions.rs`. Modify `conversations.rs` (`Conversation.project_id` via the session row, else `project_for`), `main.rs`.

**Interfaces — Produces:**
- `sessions::ensure_session_db(conn, computer_id, tool, session_id, cwd) -> rusqlite::Result<Option<String /*project_id*/>>`.
- `sessions::upload_stats_db(conn, &SessionStatsUpload) -> Result<Vec<(String, String, Option<String>)>, …>`.
- `sessions::weekly_db(conn, week_start: NaiveDate-like &str, project_id: Option<&str>) -> rusqlite::Result<WeeklyStats>`.
- Handlers `upload_stats, list_sessions, set_session_project, weekly_stats`.

- [ ] **Step 1: Write failing tests:**
  - `upload_is_idempotent_and_replaces_days`: the same upload twice → same rows; a second upload without one day deletes that day.
  - `upload_keeps_override`.
  - `override_set_null_auto`:
    - `{"project_id":X}` on another computer's project → 409;
    - `{"project_id":null}` → override to none;
    - `{"auto":true}` → re-matched;
    - memories move with it.
  - `list_sessions_joins_todo_status`.
  - `weekly_rollup_groups`. Fixture: a Mac with sections Si+P, spread with Sp; a linked todo in I on the Mac; days inside and outside the week. Expect:
    - `by_section` has I (linked), Sp (spread, unlinked), and `null` (unlinked Mac);
    - `by_computer` and `by_project` include the `null` project;
    - `sessions` counts distinct sessions;
    - tokens are null when all are null.
  - `weekly_project_filter`.
  - `weekly_rejects_non_monday` → 400.
  - `weekly_defaults_to_this_monday`.
  - `conversation_json_has_project_id`.
  - `unknown_computer_is_404`.
- [ ] **Step 2:** The tests fail.
- [ ] **Step 3: Implement.** Store `files_touched`/`models` as JSON text (serde_json). The section rule is exactly the spec's "Section of a conversation". Compute dates without a new crate if possible: the week end is the start + 6 days via a `julianday` SQL expression. Adding `chrono` is acceptable if simpler.
- [ ] **Step 4:** Tests and clippy are green.
- [ ] **Step 5:** Commit `Add sessions with per-day stats, project overrides and the weekly rollup.`

### Task S5: describe + WebSocket + final pass

**Files:** `crates/todo-server/src/describe.rs`, all new handlers.

- [ ] **Step 1:** Write a failing test `describe_lists_new_endpoints_without_section_names`. Every new path is present, and the output contains no expansion of any section code (assert that the only section strings present are the codes themselves).
- [ ] **Step 2:** Implement. Confirm that every mutating handler calls `broadcaster.send()`.
- [ ] **Step 3:** Run the full `cargo test`, the 3 clippy commands, and `cargo build -p todo-server --release`.
- [ ] **Step 4:** Commit `Describe the projects, sessions, stats and memories endpoints.`, then push the branch (`git push -u origin feature/projects-memories-server`).

---

## Track H — host scripts (repo `ai-session-remote`, `scripts/todo`)

Worktree `/Users/tsvetelinpantev/programming/ai-session-remote/.claude/worktrees/projects-memories-scripts`, branch `feature/projects-memories-scripts` (from `origin/main`). Tests extend `scripts/todo/test-todo-scripts.sh` (same sandbox: temp HOME, `pass`/`fail`, a fake hub). Add a small Python fake hub that records every request body to a file and serves canned `GET` responses from a JSON file, if the existing one can't. Fixtures live in `scripts/todo/fixtures/` (new): Claude and Codex transcripts. Python is stdlib only, embedded in sh wrappers like `ai-todo-sessions`.

### Task H1: `ai-todo-sessions stats --json`

**Interfaces — Produces:** the CLI `ai-todo-sessions stats --json [--since DAYS] [--session tool:id]... [--tool claude|codex]`. It prints a JSON array of `SessionUpload` objects (spec JSON, without `computer_id`). The env var `AI_TODO_TZ` (test hook) overrides the local timezone for day bucketing.

- [ ] **Step 1: Write the fixtures and failing tests:**
  - `fixtures/claude-stats.jsonl`: 3 prompts across 2 local days; one response split over 3 entries sharing a `message.id`; a 15-min gap; a sidechain entry; Write + Edit + MultiEdit tool calls (one outside cwd).
  - `fixtures/codex-stats.jsonl`: 2 turns, 3 `token_count` events, an `apply_patch` with Add/Update/Delete.
  - Test `stats_claude_numbers`: exact `prompts`, `assistant_turns`, token sums (split usage counted once), `active_seconds` (the 15-min gap excluded), per-day split, `files_touched` (relative + `~`-relative, deduped), `models`.
  - Test `stats_codex_numbers`: the cumulative→delta per day; `cache_creation_tokens` null.
  - Test `stats_repo_fields`:
    - a fixture git repo with a worktree → `repo_root` is the main repo, with `~`;
    - `repo_url` has `user:pass@` stripped;
    - a missing cwd → nulls.
  - Test `stats_title_redacted` (uses H2's redactor; the test lands with H2 if H2 is done second).
- [ ] **Step 2:** Run `bash scripts/todo/test-todo-scripts.sh`; the new tests fail.
- [ ] **Step 3:** Implement `cmd_stats` in `ai-todo-sessions`, reusing `read_jsonl`, `real_prompt` and the copy merging. Update the header usage.
- [ ] **Step 4:** All script tests pass.
- [ ] **Step 5:** Commit `Add ai-todo-sessions stats --json with per-day usage numbers.`

### Task H2: Redaction + transcript rendering library

`ai-todo-memory` embeds its Python. Keep the redaction rules in **one** place: a heredoc'd Python module installed as `~/.ai-remote/bin/ai_todo_redact.py`, which both scripts import via `sys.path.insert(0, <bin dir>)`. In tests, both import it from `scripts/todo/`.

**Interfaces — Produces:**
- `ai_todo_redact.redact(text: str, extra_secrets: list[str]) -> str`.
- `ai_todo_redact.secret_values_from_env(env) -> list[str]`.

- [ ] **Step 1:** Write failing tests in `test-todo-scripts.sh` that call `python3 -c` on `fixtures/secrets.txt`, one sample per spec rule:
  - each rule is replaced by `[REDACTED:<type>]`;
  - `redaction_keeps_unicode` (Cyrillic and emoji survive);
  - `redaction_exceptions`: a 40-hex git SHA, a UUID, and normal prose with "token" in it are unchanged;
  - `key_value_keeps_key`: `password=hunter2` → `password=[REDACTED:secret]`.
- [ ] **Step 2:** They fail.
- [ ] **Step 3:** Implement `scripts/todo/ai_todo_redact.py`.
- [ ] **Step 4:** They pass.
- [ ] **Step 5:** Commit `Add shared secret redaction for memory extraction and stats.`

### Task H3: `ai-todo-memory` core: incremental reading, rendering, extraction, posting

**Files:** Create `scripts/todo/ai-todo-memory`.

**Interfaces — Produces:**
- The CLI from the spec (`run | trigger | nightly | digest | status`).
- The state layout in `~/.ai-remote/memory-state/`.
- Test hooks:
  - `AI_TODO_CLAUDE_BIN`;
  - `AI_TODO_HUB_CONF`;
  - `AI_TODO_MEMORY_STATE_DIR`;
  - `AI_TODO_NOW` (epoch seconds);
  - `AI_TODO_SESSIONS_BIN` (path to `ai-todo-sessions`);
  - `AI_TODO_MEMORY_CHUNK_CHARS` (override 48000).

**Fake `claude`:** `fixtures/fake-claude`. It writes argv, env `AI_TODO_MEMORY_RUN`, cwd and stdin to `$FAKE_CLAUDE_LOG/<n>.*`, then prints `$FAKE_CLAUDE_REPLY` (a file holding the `--output-format json` envelope with `structured_output`). It exits `$FAKE_CLAUDE_EXIT`.

- [ ] **Step 1: Write failing tests:**
  - `run_posts_memories_from_complete_turns`. Fixture: 2 complete turns + 1 in-progress turn.
    - The fake hub receives one `POST /api/memories/bulk` with the canned memories, `computer_id`, `tool`, `session_id` and `cwd`.
    - The rendered stdin contains turns 1–2 but not turn 3.
    - The offset in the state file ends after turn 2.
  - `partial_trailing_line_is_not_consumed`: the transcript ends in a half-written line without `\n` → the offset stops before it, and stdin doesn't contain it.
  - `second_run_sends_nothing_new`: no claude call, no POST.
  - `appending_a_turn_sends_only_it`.
  - `claude_flags_and_env`:
    - argv contains `-p --no-session-persistence --output-format json --json-schema` (valid JSON equal to the spec schema), `--tools ""`, `--strict-mcp-config`, `--setting-sources ""`, `--model sonnet` and `--system-prompt`;
    - env `AI_TODO_MEMORY_RUN=1`;
    - cwd `$HOME/.ai-remote/memory-state/run`.
  - `stdin_has_no_secrets`: a transcript with the `fixtures/secrets.txt` samples → none of the raw values appear in the fake claude's stdin or in the POSTed body.
  - `already_known_is_sent`: the fake hub serves this session's memories + project open threads → stdin's `ALREADY KNOWN:` lists their ids.
  - `low_confidence_dropped`.
  - `claude_failure_keeps_offset`: exit 1, or `is_error`, or no `structured_output` → no POST, offset unchanged, exit non-zero.
  - `chunking_caps`: with `AI_TODO_MEMORY_CHUNK_CHARS=2000` and a long transcript:
    - `trigger` makes at most 3 claude calls;
    - the offset advances per successful chunk;
    - a later `run` continues where it stopped.
  - `not_in_project_skips_extraction_but_pushes_stats`: claude is never called; `POST /api/sessions/stats` is still sent. With `AI_TODO_STATS=off`, no stats.
  - `memory_off_switch`: `AI_TODO_MEMORY='off'` → no claude call.
  - `dry_run_changes_nothing`: prints the memories JSON; no POST, no state change, no digest.
  - `codex_session_extracts_by_task_complete`.
  - `inode_change_resumes_after_last_entry_id`.
  - `computer_id_autodetect`: the conf has no id, and the fake hub lists two computers, one matching `$USER` + the fake `hostname -s` (via `AI_TODO_HOSTNAME`) → that one is used. Two matches → exit 65.
- [ ] **Step 2:** They fail.
- [ ] **Step 3: Implement.**
  - Locks via `fcntl.flock`. `projects.json` is cached for 10 min, and the old copy is kept on fetch failure.
  - Rendering rules and limits exactly as in the spec's pipeline steps 2–4.
  - The prompt and schema text come verbatim from the spec.
  - `memory.log` holds ids, counts and errors only.
- [ ] **Step 4:** They pass.
- [ ] **Step 5:** Commit `Add ai-todo-memory: incremental, redacted memory extraction with claude -p.`

### Task H4: Digest writer

**Interfaces — Produces:** `ai-todo-memory digest [--project ID] [--dry-run] [--remove-all]`. Rendering and placement follow the spec's "Feeding memories back".

- [ ] **Step 1: Write failing tests:**
  - **Fake projects:** a git repo `~/work/app` with a worktree `~/work/app/.claude/worktrees/w`, and a plain folder `~/work/multi` with two repos inside.
  - `digest_writes_claude_local_md`: the content equals the expected fixture `fixtures/digest-expected.md`, covering:
    - group order;
    - pinned first;
    - date format;
    - the done/files_changed 14-day and 5-item limits;
    - the 40-item / 8 KB cap.

    The path lands in `.git/info/exclude` exactly once.
  - `digest_is_idempotent`: a second run leaves the mtime unchanged (`stat` before and after, with sleep 1).
  - `digest_respects_users_own_claude_local_md`: a CLAUDE.local.md without our marker → untouched, and `.claude/rules/todo-hub-memories.md` is written instead.
  - `codex_block_in_place`:
    - AGENTS.md with user text above and below an existing block → only the block changes, and the outside bytes are identical;
    - no Codex sessions → no AGENTS.md is created;
    - a tracked AGENTS.md is skipped and `status` reports it;
    - unbalanced markers → untouched + logged;
    - the block is ≤ 6 KB;
    - a worktree Codex cwd is skipped.
  - `digest_disabled_removes_only_ours`: `digest_enabled=false` → our CLAUDE.local.md is deleted, the AGENTS.md we created is deleted, and the user's AGENTS.md keeps its text with the block removed.
  - `hub_down_keeps_digest`: hub unreachable → the files are untouched, exit non-zero.
  - `digest_target_accepts_trailing_slash`: folder `~/work/app/` is written correctly.
- [ ] **Step 2:** They fail.
- [ ] **Step 3:** Implement. Atomic writes (temp file + `os.replace`); `digests.json` records `created_by_us`.
- [ ] **Step 4:** They pass.
- [ ] **Step 5:** Commit `Add the project memory digest for Claude (CLAUDE.local.md) and Codex (AGENTS.md block).`

### Task H5: trigger / nightly orchestration

- [ ] **Step 1: Write failing tests:**
  - `trigger_debounce`: two triggers within 30 min → one claude call; with `AI_TODO_NOW` +31 min → a second call.
  - `trigger_skips_when_locked`: hold the global lock from the test → trigger exits 0 immediately.
  - `nightly_pushes_stats_then_extracts_oldest_first_within_cap`, with `AI_TODO_MEMORY_MAX_CHUNKS_NIGHT=2`.
  - `first_run_backfill_window`: a transcript with mtime 10 days ago gets offset=EOF and no claude call.
  - `hub_down_keeps_offsets`: the hub isn't listening → no offsets change.
  - `nightly_rewrites_digests`.
- [ ] **Step 2:** They fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** They pass.
- [ ] **Step 5:** Commit `Add the idle trigger and nightly run for memory extraction and stats.`

### Task H6: Hook + installer

**Files:** `scripts/todo/ai-todo-hook`, `scripts/todo/install.sh`, plus the plist template inside `install.sh`.

- [ ] **Step 1: Write failing tests:**
  - `hook_noop_under_memory_run`: `AI_TODO_MEMORY_RUN=1` → no POST, no trigger.
  - `hook_idle_triggers_memory_detached`: a fake `ai-todo-memory` in a sandbox `bin` records its argv `trigger claude <sid> --transcript <path>` and sleeps 5. The hook returns in under 1 s. It also triggers for a session **not** in an `ai/claude/todo-*` tmux session. `waiting`/`busy`/`tool` don't trigger.
  - `hook_without_memory_binary_still_posts_status`.
  - `install_memory_and_launchd`. A fake `launchctl` on PATH records its calls. Expect:
    - `ai-todo-memory` + `ai_todo_redact.py` installed;
    - `memory-state` has mode 700;
    - the plist is in the sandbox `~/Library/LaunchAgents/com.ai-remote.todo-memory.plist` with 03:30 and `nightly`;
    - `bootout` then `bootstrap gui/<uid>`;
    - `--computer-id` is written to the conf.
  - `install_no_nightly`.
  - `uninstall_removes_job_keeps_state`.
  - `uninstall_remove_digests_runs_remove_all_first`.
  - The existing installer tests are still green; `settings.json` hooks are unchanged versus today's install.
- [ ] **Step 2:** They fail.
- [ ] **Step 3:** Implement. The hook:
  - `[ -n "${AI_TODO_MEMORY_RUN:-}" ] && exit 0` right after the status case;
  - on `idle` (the argument), parse `session_id` and `transcript_path` from stdin before the tmux filter;
  - `if [ -x "$HOME/.ai-remote/bin/ai-todo-memory" ]; then nohup … trigger … </dev/null >/dev/null 2>&1 & fi`.

  The test hook `AI_TODO_MEMORY_BIN` overrides the path.
- [ ] **Step 4:** The whole `test-todo-scripts.sh` passes; `sh -n` and, if installed, `shellcheck` are clean.
- [ ] **Step 5:** Commit `Trigger memory extraction from the Stop hook and install the nightly job.`, then push the branch.

---

## Track A — SwiftUI app (repo `ai-session-remote`)

Worktree `/Users/tsvetelinpantev/programming/ai-session-remote/.claude/worktrees/projects-memories-app`, branch `feature/projects-memories-app` (from `origin/main`). Follow `TodoHubClient` / `TodoHubModels` / `TodoHubStore` / `TodosView` patterns. JSON is snake_case on the wire, converted by the client's decoder.

### Task A1: Core models + client + cache

**Files:**
- Modify `Sources/AISessionCore/TodoHub/TodoHubModels.swift`, `TodoHubClient.swift`, `TodoHubCache.swift`.
- Create `Sources/AISessionCore/TodoHub/ProjectModels.swift` (Project, ProjectSuggestion, Memory, MemoryKind, HubSession, SessionStats, WeeklyStats, StatsCounters, the rollups and the requests). Name the session type `HubSession`, so it doesn't clash with `RemoteSession`.
- Tests in `Tests/AISessionCoreTests/ProjectsClientTests.swift`.

**Interfaces — Produces:** client methods:
- `listProjects()`, `createProject(_:)`, `updateProject(id:_:)`, `deleteProject(id:)`, `projectSuggestions()`;
- `listSessions(projectId:computerId:since:limit:)`, `setSessionProject(tool:sessionId:projectId:)`, `setSessionProjectAuto(tool:sessionId:)`;
- `listMemories(_ query: MemoryQuery)`, `createMemory(_:)`, `updateMemory(id:_:)`, `deleteMemory(id:)`;
- `weeklyStats(weekStart: String?, projectId: String?)`;
- `listTodos(section:filter:projectId:)` (new optional parameter, default nil).

`Todo.projectId` and `Conversation.projectId` are `String?`. `UpdateTodoRequest` gains a `projectId: ProjectChange?` with `enum ProjectChange { case set(String), clear }`; `clear` encodes `"project_id": null` explicitly. `TodoHubSnapshot.projects: [Project]` decodes with a default of `[]`.

- [ ] **Step 1: Write failing tests:**
  - `decodesTodoWithAndWithoutProjectId`;
  - `decodesProjectMemorySessionWeekly` (from spec JSON samples, nulls included);
  - `updateTodoClearEncodesExplicitNull`;
  - `oldCacheFileWithoutProjectsLoads`;
  - per method, path + method + query + body through the existing URLProtocol stub. Include `memoriesQueryKinds` (`kind=gotcha,decision`) and `setSessionProjectAutoBody` (`{"auto":true}`).
- [ ] **Step 2:** `swift test` fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` passes.
- [ ] **Step 5:** Commit `Add project, memory, session and weekly stats models and client calls.`

### Task A2: Store + grouping helpers

**Files:** Modify `App/AISessionRemote/Services/TodoHubStore.swift`. Create `Sources/AISessionCore/TodoHub/MemoryGrouping.swift` (pure, testable) and `Tests/AISessionCoreTests/MemoryGroupingTests.swift`.

**Interfaces — Produces:**
- `MemoryGrouping.grouped(_ memories: [Memory]) -> [(MemoryKind, [Memory])]`: kind order open_thread, decision, gotcha, done, files_changed; pinned first, then newest.
- `MemoryGrouping.forConversation(_ memories: [Memory], sessionId: String?) -> [Memory]`: this session's memories first.
- `WeekMath.monday(of: Date, calendar: Calendar) -> String`.
- Store state:
  - `projects: [Project]` (refreshed with todos);
  - `suggestions`;
  - `func memories(projectId:) async throws -> [Memory]`;
  - `func sessions(projectId:) async throws -> [HubSession]`;
  - `func weekly(projectId:weekStart:)`;
  - mutations through the existing `mutate`/`perform`.
- [ ] **Step 1:** Write failing tests for grouping order, conversation ordering and `monday` (Sunday → the previous Monday; Monday → itself).
- [ ] **Step 2:** They fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** They pass, and both schemes build.
- [ ] **Step 5:** Commit `Add project and memory state to the hub store.`

### Task A3: Projects tab, project page, suggestions

**Files:** Create `App/AISessionRemote/Views/Projects/ProjectsView.swift`, `ProjectDetailView.swift`, `ProjectEditorSheet.swift`, `WeeklyStatsCard.swift`, `MemoryViews.swift` (row, editor sheet, grouped list used by both the page and the panel). Modify `RootView.swift` (tab between Todos and Hosts).

- [ ] **Step 1:** Build the views exactly as in the spec's "App" section.
  - Opening a linked session reuses the todo-conversation opening path. Extract the needed bit of `TodosView` into a shared helper rather than duplicating it.
  - Delete confirms.
  - The digest toggle PATCHes `digest_enabled`.
  - A nesting `409` shows the server message.
- [ ] **Step 2:** `xcodegen generate`, then both schemes build. Add a `#if DEBUG` demo launch argument `-demoProjects` with canned data, like the existing `-demoConversationPicker`, so the views can be screenshotted without a hub.
- [ ] **Step 3:** Commit `Add the Projects tab with project pages, memories and weekly stats.`

### Task A4: Todo assignment + terminal memories panel

**Files:** Modify `Views/Todos/TodosView.swift` (context-menu "Project ▸", label on rows), `AddTodoSheet` (project picker), the conversation destination (toolbar button; Mac `.inspector`, iOS `.sheet`) with `MemoriesPanel` from `MemoryViews.swift`. Conversation rows on the project page get "Move to project…" (`setSessionProject`) and "Match automatically".

- [ ] **Step 1:** Implement. The terminal view itself (`TerminalScreen`) is not modified, only wrapped.
- [ ] **Step 2:** Both schemes build; `swift test` is green; the existing app unit tests build (`xcodebuild … build-for-testing` for iOS).
- [ ] **Step 3:** Commit `Assign projects to todos and show memories next to the conversation terminal.`, then push the branch.

---

## Integration (lead, after all tracks)

1. Merge `feature/projects-memories-scripts` and `feature/projects-memories-app` into `feature/projects-memories` (ai-session-remote) and regenerate the Xcode project. Open draft PRs: todo-app `feature/projects-memories-server` (including this spec and plan) and ai-session-remote `feature/projects-memories`.
2. **End-to-end on this Mac:**
   - A local `todo-server --db <copy of the Pi DB>` on a free port.
   - The scripts run with a sandbox `AI_TODO_HUB_CONF` pointing at it, and the real HOME transcripts.
   - Stats push for all sessions.
   - Create projects from the suggestions.
   - `ai-todo-memory run claude <one real session> --dry-run --no-digest` → **show the user the memories and stop**.
   - Only after approval: a real post, then `digest --dry-run` shown, then written.
3. Code review of both PRs, fix the findings, re-run all suites and both Xcode builds.
4. Rollout only on the user's go.
