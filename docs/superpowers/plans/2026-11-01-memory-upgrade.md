# Memory Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the hub's memory into a small, usage-ranked index that every Claude and Codex session gets at start, plus search, an approve-first `add`, Claude memory import and pruning of unused facts.

**Architecture:**
- **Hub (Rust, todo-server):** owns storage, search (FTS5), usage counting, active days and pruning.
- **`ai-todo-memory` (Python inside a shell wrapper) on each computer:** extracts, imports, keeps a local cache, and prints the index for a session-start hook that both Claude and Codex run.
- **App:** gains a "Waiting for OK" section for memories that agents add.

**Tech Stack:** Rust (actix-web, rusqlite 0.31 bundled, so FTS5 is available), Python 3 standard library, POSIX shell tests, Swift/SwiftUI (AISessionCore package and app).

**Spec:** `docs/superpowers/specs/2026-11-01-memory-upgrade-design.md`

## Global Constraints

- The index budget is 2,048 bytes, including the two hint lines.
- The hint lines, exactly:
  - `More: ai-todo-memory search <words>`
  - `Save a fact: ai-todo-memory add "<text>" (the user approves it)`
- **Extraction kinds:** only `decision`, `gotcha` and `open_thread`. The server still accepts `done` and `files_changed` from old hosts.
- **Text limit:** 400 characters, except `source = "claude-memory"`, which allows 8,000.
- **Usefulness:** grace is 7 active days. A memory is archived (`archived_reason = 'unused'`) after 14 active days without use. Pinned, pending and non-archived `claude-memory` memories are exempt.
- **Signals of use:** `relied`, `search`, `user`, `duplicate`. Being shown in an index is never a use.
- **Active days** are local-time `YYYY-MM-DD` strings sent by the host, and only hosts that post uses send them (`POST /api/memories/uses`). Existing memories age from the migration day (no backfill).
- **Global memory:** `project_id` and `todo_id` are both null and `computer_id` is set. It is only visible to that computer's index, search and cache.
- **Session start never waits on the network.** The hook reads only the local cache, always exits 0, and returns within 300 ms.
- **Redaction:** everything posted goes through `ai_todo_redact.py`, as today.
- **Search query text** is never written to any log.
- **Git:** work in a worktree, never in the shared checkout at `~/programming/ai-session`. Push to `main` only at Task 10.

## Review Focus

1. **Hub down or slow at session start.** The hook still prints the cached index, exits 0, and never blocks. Test: `session_start_hub_down_uses_cache` (Task 7).
2. **A folder that belongs to no project** (`/tmp`, `~`). Index and search show this computer's global memories only and don't crash. Test: `index_outside_project_globals_only` (Task 6).
3. **Secrets in `add` text or an imported Claude memory file** are redacted before posting. Tests: `add_redacts_secret` (Task 6), `import_redacts_secret` (Task 8).
4. **Old hosts and the old app keep working.**
   - A bulk post with `done` or `files_changed` from an old host is still accepted and stays non-pending.
   - A list call without `pending` never returns pending memories.
   - Tests: `bulk_accepts_old_kinds`, `list_hides_pending_by_default` (Task 2).
5. **A pinned memory longer than the whole budget** (an 8,000-character Claude import). The index shows its first line cut to 200 characters instead of dropping it or overflowing. Test: `index_long_pinned_shows_first_line` (Task 6).

---

### Task 1: Schema v12, memory columns, active days, FTS

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs` (`memories_ddl` near line 263, `SCHEMA_VERSION` and the doc list near line 324, `migrate` near line 396, tests module)

**Interfaces:**
- Produces:
  - **Table `memories`**, with the new columns:
    - `pending INTEGER NOT NULL DEFAULT 0`
    - `use_count INTEGER NOT NULL DEFAULT 0`
    - `last_used_at TEXT`
    - `aged_from TEXT NOT NULL DEFAULT (date('now'))`
    - `archived_reason TEXT CHECK(archived_reason IN ('unused','duplicate','superseded','retired','user'))`
    - `source_key TEXT`
    - `source` CHECK in `('extracted','manual','claude-memory','agent')`
    - Unique index `memories_source_key ON memories(computer_id, source_key) WHERE source_key IS NOT NULL`
  - **Table `memory_active_days`**: `scope TEXT NOT NULL, day TEXT NOT NULL, PRIMARY KEY(scope, day)`. `scope` is `project:<id>` or `computer:<id>`.
  - **FTS5 table `memories_fts`**: external-content on `memories(text)`, kept in sync by insert, update and delete triggers.
  - `SCHEMA_VERSION = 12`.

- [ ] **Step 1: Write the failing tests** in `db.rs` tests:
  - `migrates_v11_to_v12_rebuilds_memories`: build a v11 database with three memories (one `done`, one archived `gotcha`, one live `decision`), run migrate, then assert:
    - `user_version == 12`
    - the `done` row has `archived = 1, archived_reason = 'retired'`
    - the archived gotcha has `archived_reason = 'duplicate'`
    - the live decision has `aged_from` equal to today's date and `use_count = 0`
    - inserting `source = 'claude-memory'` succeeds
    - `SELECT rowid FROM memories_fts WHERE memories_fts MATCH 'decision-word'` finds the decision
  - `fresh_database_has_v12_memory_objects`: a new database has `memory_active_days`, `memories_fts` and the `pending` column.
- [ ] **Step 2: Run them and confirm they fail.**
  Run: `cd todo-app && cargo test -p todo-server migrates_v11_to_v12 fresh_database_has_v12`. Expected: FAIL.
- [ ] **Step 3: Implement `migrate_v11_to_v12(conn: &Connection) -> rusqlite::Result<()>`.**
  - Rebuild the table: create `memories_new` from the new DDL, `INSERT … SELECT` with `aged_from = date('now','localtime')`, drop the old table, rename, then recreate indexes, the FTS table, triggers and `INSERT INTO memories_fts(memories_fts) VALUES('rebuild')`.
  - Then: `UPDATE … SET archived = 1, archived_reason = 'retired' WHERE kind IN ('done','files_changed') AND archived = 0`, and `archived_reason = 'duplicate'` for rows already archived.
  - Back up first, the way the other steps do (`backup_before_migration(conn, db_path, 12)`).
  - Add the v12 line to the version doc comment.
- [ ] **Step 4: Run all server tests.** Run: `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(server): memory schema v12 (usage, pending, FTS, active days)`

### Task 2: Writes: global memories, pending, imports, duplicates as uses

**Files:**
- Modify: `todo-app/crates/todo-server/src/memories.rs` (`checked_text`, `create_memory_db`, `insert_bulk_db`, `update_memory_db`, `MemoryQuery`, `list_memories_db`, `row_to_memory`, `MEMORY_COLS`)
- Modify: `todo-app/crates/todo-server/src/models.rs` (Memory, CreateMemoryRequest, BulkMemoriesRequest, UpdateMemoryRequest)

**Interfaces:**
- Consumes: the v12 columns (Task 1).
- Produces:
  - **Memory JSON** gains `pending: bool`, `use_count: i64`, `last_used_at: Option<String>`, `archived_reason: Option<String>`, `source_key: Option<String>`.
  - **`CreateMemoryRequest`** gains `source: Option<String>` (`manual` default, or `agent`), `pending: Option<bool>` and `computer_id`. With no project and no todo it's accepted when `computer_id` is set; otherwise 400 as today.
  - **`BulkMemoriesRequest` items** accept optional `source_key`. With `source = "claude-memory"`, an item upserts on `(computer_id, source_key)`: it updates text and kind, and a changed text un-archives an `unused` row.
  - **`PATCH`** accepts `pending: false`. Any PATCH that changes `pinned`, `text` or `pending` sets `last_used_at = now` and `use_count += 1` (the `user` signal).
  - **Bulk:** a duplicate match calls `record_use(conn, id, "duplicate")`. Superseding copies `use_count` and `last_used_at` onto the new row and sets `archived_reason = 'superseded'` on the old one.
  - **New query params:**
    - `pending=true|false`, default false: pending rows are hidden unless asked for.
    - `computer_id=<id>`
    - `global=true` (`project_id IS NULL AND todo_id IS NULL`)
    - `ids=<id>,<id>` (at most 100, includes archived rows)
  - `pub(crate) fn record_use(conn: &Connection, id: &str, signal: &str) -> rusqlite::Result<bool>`: bumps `use_count` and `last_used_at`. If the row is archived with reason `unused`, it un-archives it. Returns false for an unknown id.

- [ ] **Step 1: Write the failing tests** in `memories.rs` tests, one per behaviour:
  - `create_global_memory_needs_computer`
  - `create_agent_memory_pending`
  - `list_hides_pending_by_default`
  - `patch_pending_false_approves_and_counts_use` (`use_count == 1`)
  - `bulk_duplicate_counts_use` (the matched row's `use_count` goes 0→1)
  - `bulk_supersede_inherits_usage`
  - `bulk_accepts_old_kinds` (a `done` item is inserted, `pending == false`)
  - `claude_memory_upsert_by_source_key` (a second post with the same key updates text, row count unchanged)
  - `claude_memory_text_limit_8000` (8,000 characters OK, 8,001 is 400; for `extracted`, 401 is 400)
  - `list_global_for_computer` (`global=true&computer_id=c1` returns only c1's globals)
  - `list_by_ids`
- [ ] **Step 2: Run them and confirm they fail.** Run: `cd todo-app && cargo test -p todo-server memories::`. Expected: FAIL.
- [ ] **Step 3: Implement.** Make `checked_text(text, source)` take the source so the limit is 400 or 8,000.
- [ ] **Step 4: Run all server tests.** Run: `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(server): global, pending, imported memories; duplicates count as uses`

### Task 3: Search, usage endpoint, active days and pruning

**Files:**
- Create: `todo-app/crates/todo-server/src/memory_usage.rs` (uses, active days, prune)
- Modify: `todo-app/crates/todo-server/src/memories.rs` (`q=` and `include_unused`)
- Modify: `todo-app/crates/todo-server/src/main.rs` (route `POST /api/memories/uses` next to the other memory routes near line 100; `mod memory_usage;`)

**Interfaces:**
- Consumes: `record_use` (Task 2).
- Produces:
  - **`GET /api/memories?q=<words>`:**
    - FTS5 match over `text`. Each word is quoted as a prefix term so user input can't inject FTS syntax.
    - Ordered by `bm25`, combinable with every other filter.
    - With `include_unused=true`, rows archived as `unused` are included after all live rows.
    - With `q` absent, behaviour is unchanged.
  - **`POST /api/memories/uses`**, body:
    `{"computer_id": "...", "day": "YYYY-MM-DD", "project_ids": ["..."], "uses": [{"id": "...", "signal": "relied|search"}]}`
    - Inserts `computer:<computer_id>` and each `project:<id>` for `day` into `memory_active_days` (ignoring duplicates).
    - Calls `record_use` for each use.
    - Then calls `prune_unused`.
    - Returns `{"recorded": n, "unknown": [ids], "archived": [ids]}`.
  - **`pub(crate) fn prune_unused(conn: &Connection) -> rusqlite::Result<Vec<String>>`:**
    - Archives with `archived_reason = 'unused'` every row that is not archived, not pinned, not pending and not `claude-memory`, whose scope has at least 14 rows in `memory_active_days` with `day > max(aged_from, date(last_used_at))`.
    - The scope is `project:<project_id>`, or `computer:<computer_id>` when `project_id` is null. A row with neither is never pruned.
    - Returns the archived ids.

- [ ] **Step 1: Write the failing tests:**
  - `search_matches_words_and_ranks`
  - `search_quotes_fts_syntax` (`q=foo"bar OR` doesn't error)
  - `search_include_unused_after_live`
  - `uses_records_active_days_once` (posting the same day twice gives one row)
  - `prune_after_14_active_days` (13 days: not archived; 14: archived with reason `unused`)
  - `prune_counts_from_last_use` (a use on day 10 resets the count)
  - `prune_skips_pinned_pending_claude_memory`
  - `prune_global_uses_computer_scope`
  - `search_use_revives_unused` (a `search` use on an `unused` row un-archives it)
  - `old_memories_age_from_migration` (`aged_from` = migration day means 13 days later nothing is pruned)
- [ ] **Step 2: Run them and confirm they fail.** Run: `cd todo-app && cargo test -p todo-server memory_usage:: memories::tests::search`. Expected: FAIL.
- [ ] **Step 3: Implement** the module and routes as specified.
- [ ] **Step 4: Run all server tests.** Run: `cd todo-app && cargo test`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(server): memory search, usage, active days and pruning`

### Task 4: Fake hub support for the new API

**Files:**
- Modify: `ai-session-remote/scripts/todo/fixtures/fake-hub.py`

**Interfaces:**
- Produces: fake-hub handlers for `GET /api/memories` with `q`, `global`, `computer_id`, `pending` and `include_unused` (substring match is enough for `q`), `POST /api/memories/uses` (recorded in its request log), and `POST /api/memories` with `pending`.
- Requests are logged in the existing log format, so shell tests can assert on them.

- [ ] **Step 1:** Extend the handlers. Keep existing behaviour for current tests.
- [ ] **Step 2:** Run `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Expected: everything that passed before still passes.
- [ ] **Step 3: Commit.** Message: `test(scripts): fake hub speaks memory search, uses and pending`

### Task 5: Extraction: fewer kinds, "used" ids, usage and active-day posts

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-memory` (`KINDS`, `SYSTEM_PROMPT`, `SCHEMA`, `fetch_known`, the per-chunk post near line 839, `run`)
- Modify: `ai-session-remote/scripts/todo/fixtures/claude-reply.json` (add `used`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (memory extraction section near line 1650)

**Interfaces:**
- Consumes: `POST /api/memories/uses` (Task 3).
- Produces:
  - `EXTRACT_KINDS = ("decision", "gotcha", "open_thread")`, used in the prompt and the schema enum. `KINDS` stays for validating hub data.
  - **Schema:** top level `{"memories": [...], "used": [ids]}`, where `used` is optional, `maxItems` 20, strings.
  - **Prompt:** add the rule "used: ids from ALREADY KNOWN that this excerpt actually relied on (acted on, or that answered a question). Do not list ids that were merely visible."
  - `fetch_known` also includes the ids in `STATE_DIR/sessions/<tool>-<sid>.shown` (one id per line, written by Task 7), fetched with `GET /api/memories?ids=…` (Task 2).
  - `post_uses(ctx, day: str, project_ids: list[str], uses: list[dict]) -> None` posts once per run. `day` is the local date of the conversation's last turn. `project_ids` is the matched project plus its ancestor projects (folders containing it, from the existing project matching). Uses are the deduplicated `used` ids with `signal: "relied"`. Unknown ids in the answer are dropped before posting.
  - **Digest writing stops:** `run` and `nightly` no longer call the digest code. The `digest` command stays, so `digest --remove-all` still works.

- [ ] **Step 1: Write the failing tests** in the extraction section:
  - `extract_schema_has_three_kinds` (the fake claude receives a schema whose enum is exactly the three kinds)
  - `extract_posts_relied_uses` (fixture reply `used: ["<known id>", "bogus"]` gives one uses post containing only the known id, with `day` and `project_ids`)
  - `extract_project_ids_include_ancestor` (a project inside another project's folder posts both ids)
  - `extract_writes_no_digest` (after `run`, no `AGENTS.md` marker block exists)
- [ ] **Step 2:** Run `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4:** Run the same script. Expected: PASS. Update or remove the old digest-writing tests that assert digests are written during `run` and `nightly`.
- [ ] **Step 5: Commit.** Message: `feat(memory): extract facts only, report relied-on memories and active days`

### Task 6: Cache, `index`, `search`, `add`, `list --global`

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-memory` (new subcommands and usage header)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new section `--- ai-todo-memory: index and search ---`)

**Interfaces:**
- Consumes: hub filters and search (Tasks 2–3), `post_uses` (Task 5).
- Produces:
  - **Cache file `STATE_DIR/cache.json`:** `{"fetched_at": epoch, "computer_id": "...", "projects": [{"id","folder"}], "memories": [Memory JSON]}`.
    - Holds the non-archived, non-pending `gotcha` and `decision` rows plus pinned rows for every project on this computer, and this computer's globals.
    - Written atomically (temp file plus rename) under the existing lock.
  - `refresh_cache(ctx) -> bool`. It runs at the end of `run`, `nightly` and `import`, and from `ai-todo-memory refresh`.
  - `ai-todo-memory index [--cwd PATH] [--budget BYTES] [--json]` prints the index from the cache only, never the network. `--json` prints `{"text": "...", "ids": [...]}`.
    - **Selection:** the cwd's project, its ancestors and globals. `claude-memory` rows are skipped unless pinned. `open_thread` is never included.
    - **Order:** pinned first; then up to 512 bytes for rows still in grace, newest first; then the rest by `last_used_at` (newest first), then `use_count`, with the nearest project winning ties.
    - **Lines:** `- <text on one line>`. A pinned row that doesn't fit is shown with its first line cut to 200 characters. Other rows that don't fit are dropped whole.
    - **Grace:** "in grace" means `use_count == 0` and `created_at` within 7 calendar days. That's an approximation of active days, acceptable for ordering only.
    - The two hint lines from Global Constraints always end the output.
  - `ai-todo-memory search <words> [--project auto|ID|all] [--limit N] [--cwd PATH]`. The default is `auto`: the cwd's project, its ancestors and globals, limit 8.
    - It calls `GET /api/memories?q=…&include_unused=true` with a 3 s timeout, falling back to a substring match over the cache.
    - It prints `[kind] text — YYYY-MM-DD`. A `claude-memory` hit prints its first line plus 160 characters.
    - It then posts the printed ids as `search` uses, best effort.
    - The log line is `search hits=N source=hub|cache` and never includes the query.
  - `ai-todo-memory add "<text>" [--kind gotcha|decision] [--global] [--cwd PATH]`:
    - Redacts the text, then posts `POST /api/memories` with `source: "agent"` and `pending: true`, plus the project (or `computer_id` with `--global`).
    - Prints `Saved for approval in the app.`
    - Exit codes: 1 when the hub is unreachable, 64 when the text is empty or the kind is invalid.
  - `ai-todo-memory list --global` prints this computer's global memories.

- [ ] **Step 1: Write the failing tests** (cache fixture built by the test, fake hub from Task 4):
  - `index_budget_and_hints` (output ≤ 2048 bytes, the last two lines are the hints)
  - `index_order_pinned_grace_used` (pinned, then grace, then most recently used)
  - `index_skips_open_threads_and_unpinned_imports`
  - `index_outside_project_globals_only`
  - `index_long_pinned_shows_first_line`
  - `index_json_lists_ids`
  - `index_never_calls_hub` (the fake hub's log is unchanged)
  - `search_uses_hub_and_posts_search_uses`
  - `search_falls_back_to_cache` (hub stopped)
  - `search_log_has_no_query` (the query word is absent from `memory.log`)
  - `add_posts_pending_agent`
  - `add_redacts_secret` (a value from `fixtures/secrets.txt` is not in the posted body)
  - `add_global_sets_computer`
- [ ] **Step 2:** Run the test script. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4:** Run the test script. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(memory): local cache, session index, search and approve-first add`

### Task 7: Session-start hook for Claude and Codex, install and cleanup

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-memory` (subcommand `session-start`)
- Modify: `ai-session-remote/scripts/todo/install.sh` (hook merge near line 139: add `SessionStart` for Claude and Codex, trust the Codex hook the way the others are trusted, then run `ai-todo-memory digest --remove-all` once)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`. Also extend `test-claude-live.py` and `test-codex-live.py` with one live check each.

**Interfaces:**
- Consumes: `index --json` logic (Task 6).
- Produces:
  - `ai-todo-memory session-start [--codex]`:
    - Reads the hook JSON on stdin (`session_id`, `cwd`).
    - Prints `{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "<index text>"}}`. Both Claude and Codex 0.164 read `additionalContext`. Codex 0.164's binary includes `SessionStart` and `additionalContext`; verify the exact JSON in the live test.
    - Writes the ids to `STATE_DIR/sessions/<tool>-<session_id>.shown`.
    - If the cache is older than 3,600 s, starts `ai-todo-memory refresh` detached.
    - Always exits 0. On any error it prints nothing.
    - Skipped when `AI_TODO_MEMORY_RUN=1` (the extractor's own `claude -p`) or `AI_TODO_MEMORY_DIGEST=off`.
  - **Hook commands:** Claude `~/.ai-remote/bin/ai-todo-memory session-start`; Codex `~/.ai-remote/bin/ai-todo-memory session-start --codex`.

- [ ] **Step 1: Write the failing tests:**
  - `session_start_prints_additional_context`
  - `session_start_writes_shown_ids`
  - `session_start_hub_down_uses_cache` (exit 0, output present, finishes in under 300 ms with the hub stopped)
  - `session_start_noop_under_memory_run`
  - `install_adds_session_start_hooks` (both `settings.json` and `hooks.json` in the sandbox HOME)
  - `install_removes_old_digest_blocks`
- [ ] **Step 2:** Run the test script. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4:** Run the test script. Expected: PASS. Then run `python3 ai-session-remote/scripts/todo/test-codex-live.py` and `test-claude-live.py`. Expected: a fresh session started in a project folder can quote a line from its index.
- [ ] **Step 5: Commit.** Message: `feat(memory): deliver the index at session start for Claude and Codex`

### Task 8: Import Claude memory files

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-memory` (subcommand `import`, called from `nightly`)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`

**Interfaces:**
- Consumes: bulk upsert by `source_key` (Task 2), `refresh_cache` (Task 6).
- Produces:
  - `ai-todo-memory import [--dry-run]`:
    - Reads `~/.claude/projects/*/memory/*.md`, except `MEMORY.md`.
    - Decodes the folder name to a path (`-` back to `/`; ambiguous decodes are resolved by checking which candidate path exists) and matches it to the nearest hub project whose folder contains it. No match makes the memory global.
    - Kind is `decision` for `user` and `feedback`, `gotcha` for `project` and `reference`. Missing or unknown frontmatter gives `gotcha`.
    - Text is the `description` line, a newline, then the body, redacted and cut to 8,000 characters.
    - Posts are bulk with `source: "claude-memory"`, `source_key: "<dir>/<file>"`, `confidence: 1.0`.
    - Files that are now gone are archived with `PATCH archived: true`, tracked in `STATE_DIR/imports.json`.
    - Non-UTF-8 files are skipped with a log line.
  - `nightly` runs `import` after extraction.

- [ ] **Step 1: Write the failing tests:**
  - `import_maps_project_and_kind`
  - `import_global_when_no_project`
  - `import_upserts_unchanged_key` (a second run posts the same key, and the fake hub has one row)
  - `import_archives_deleted_file`
  - `import_redacts_secret`
  - `import_skips_memory_md_and_bad_utf8`
- [ ] **Step 2:** Run the test script. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the test script. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(memory): import Claude's curated memory files to the hub`

### Task 9: Status reports usefulness

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-memory` (`status`, near line 1842)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh`

**Interfaces:**
- Consumes: hub list filters (Task 2), `memory.log` lines (Tasks 5–6), `imports.json` (Task 8).
- Produces: `status` and `status --json` gain the following keys:
  - `posted_per_day` (last 7 local days, from the log)
  - `cache_age_s`
  - `cache_memories`
  - `index_bytes` (for the cwd)
  - `searches_7d`
  - `last_import`
  - `hooks: {"claude": bool, "codex": bool}`
  - `most_used` (top 5 by `use_count`)
  - `never_used` (count)
  - `archived_unused_7d` (count)
  
  The hub calls use a 3 s timeout. When the hub is unreachable, the hub-backed keys are `null`.

- [ ] **Step 1: Write the failing test:** `status_json_has_usefulness_keys` (all keys present; hub-backed keys are null with the hub stopped).
- [ ] **Step 2:** Run the test script. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the test script. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(memory): status shows collection, delivery and usefulness`

### Task 10: App: approve or reject pending memories

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/ProjectModels.swift` (`Memory` near line 610: add `pending: Bool`, `useCount: Int`, `lastUsedAt: String?`, `archivedReason: String?`, each decoding with a default when absent; `UpdateMemoryRequest` near line 750: add `pending: Bool?`; `MemoryQuery` near line 681: add `pending: Bool?`, `computerId: String?`, `global: Bool?`)
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubClient.swift` (`listMemories` query items)
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift` (`memories(...)` near line 938: add `pending: Bool = false`; new `pendingMemoryCount: Int` refreshed with projects)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Projects/MemoryViews.swift` (a "Waiting for OK" section on top of `MemoriesPanel`, with Approve calling `updateMemory(m, UpdateMemoryRequest(pending: false))` and Reject using the existing delete confirmation)
- Modify: `ai-session-remote/App/AISessionRemote/Views/Lists/ComputerDetailView.swift` (the same section for `global=true&computer_id&pending=true`)
- Modify: the Projects tab item (`ProjectsView.swift`) to show a `.badge(store.pendingMemoryCount)`
- Test: `ai-session-remote/Tests/AISessionCoreTests/ProjectsClientTests.swift`

**Interfaces:**
- Consumes: hub fields and filters (Task 2).

- [ ] **Step 1: Write the failing tests:**
  - `testMemoryDecodesWithoutNewFields` (old JSON decodes; `pending == false`)
  - `testMemoryDecodesPendingAndUsage`
  - `testMemoryQueryPendingGlobalItems` (the query items include `pending=true`, `global=true`, `computer_id=c1`)
  - `testUpdateMemoryRequestEncodesPending`
- [ ] **Step 2:** Run `cd ai-session-remote && swift test --filter ProjectsClientTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the model, client, store and views.
- [ ] **Step 4:** Run `swift test`, then `xcodegen generate` and a build of both app targets:
  - `xcodebuild -scheme AISessionRemote -destination 'generic/platform=iOS' build`
  - the same for `AISessionRemoteMac`
  
  Expected: tests PASS and BUILD SUCCEEDED.
- [ ] **Step 5: Commit.** Message: `feat(app): approve or reject memories agents propose`

### Task 11: Roll out and verify on real data

**Files:** none (deploy and check).

- [ ] **Step 1:** Run the whole-branch review, then merge to `main` and push. Server changes publish `pi-latest`. Wait for the Pi to update, then check `GET /api/memories?q=signing` answers.
- [ ] **Step 2:** On each computer (this Mac, the Spread Mac, the Codbex Mac): update the helpers with `install.sh`, then run `ai-todo-memory import` and `ai-todo-memory refresh`.
- [ ] **Step 3:** Check `ai-todo-memory status --json` shows both hooks installed and a cache, and that `index --cwd ~/programming/ai-session` is at most 2,048 bytes.
- [ ] **Step 4:** Start a fresh Claude session and a fresh Codex session in `~/programming/ai-session`, and ask each "what's the signing team id?". Expected: each answers from the index or with one `ai-todo-memory search`, without reading `project.yml`.
- [ ] **Step 5:** Rebuild the Mac app with `ai-session-remote/scripts/rebuild-mac-app.sh`, and install on the iPhone following the deploy-over-SSH memory. Run `ai-todo-memory add "test fact" --cwd ~/programming/ai-session`, check it appears under "Waiting for OK", and reject it.
- [ ] **Step 6:** Report to the user: the index size, search hits, and whether the old `~/programming/AGENTS.md` digest block is gone.
