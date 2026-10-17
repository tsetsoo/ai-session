# Todo Projects, Conversation Memories and Usage Stats Design

**Date:** 2026-10-16  
**Status:** Approved 2026-10-16  
**Repos:** todo-app (this spec: data + API, schema v3), ai-session-remote (host scripts in `scripts/todo` + SwiftUI app)  
**Builds on:** `2026-10-15-todo-ai-conversations-design.md`

## Goal

Group work into **projects** (a folder on a computer), and keep what was learned in AI conversations:

1. **Projects:** a todo can belong to a project. Conversations are matched to a project automatically by computer + folder.
2. **Memories:** each computer extracts short memories from the *new* part of its Claude/Codex transcripts with `claude -p`. Kinds: decision, gotcha, open thread, done, files changed. It posts only those memories to the Pi.
3. **Feeding back:** each computer writes a bounded digest of a project's memories into a separate managed file, which new Claude/Codex conversations in that folder load automatically.
4. **Stats:** per-conversation usage numbers (prompts, turns, tokens, active time, files), computed without an LLM, with a weekly rollup per project, section and computer.
5. **App:** a Projects tab, project pages, a memories panel next to the terminal, and project assignment for todos.

## Principles (unchanged, restated)

- **The Pi only stores data.** It never reads transcripts, runs models, SSHes or writes files on computers. Rendering a digest, computing stats and extracting memories all happen on the computer that owns the transcripts.
- **Computers do the work** with `~/.ai-remote/bin/*` scripts, using the existing Claude subscription (`claude -p`). There is no API key anywhere.
- **Apps display** and edit what the Pi stores; terminals still go app → computer over SSH.
- Section codes `Sp`, `I`, `Si`, `P` are opaque labels. They are never expanded: not in the UI, the API docs, the extraction prompt or the digests.
- Old apps and scripts keep working. Every change is additive: new tables, new optional fields, new endpoints.

## Context (current, verified 2026-10-16)

- todo-server schema v2 (`PRAGMA user_version`), `migrate()` with a `VACUUM INTO <db>.pre-vN-<ts>` backup before rewriting steps. Tables:
  - `todos`, `daily_days`, `computers`, `section_computers`;
  - `conversations`, keyed by `todo_id` (one per todo), `UNIQUE(tool, session_id)`.
  - Conversations exist only for todos. Most transcripts on a computer are not linked to any todo.
- Computers on the hub. All three are Macs, so launchd is the only scheduler needed:
  - `tsvetelins-macbook-pro` (Si, P → `~/programming`)
  - `spreads-macbook-pro` (Sp → `~/Spread/Repository`)
  - `codbexs-macbook-pro` (I → `~/Repositories`)
- Host scripts (ai-session-remote `scripts/todo`):
  - `ai-todo-open`.
  - `ai-todo-hook <busy|waiting|idle|tool>`. It runs from Claude hooks and reports only for tmux sessions named `ai/claude/todo-*`.
  - `ai-todo-sessions list|delete|prune`, a sh wrapper around embedded Python with the Claude and Codex transcript parsers.
  - `install.sh [--uninstall]`. It already merges the hooks into `~/.claude/settings.json`; this design adds **no** new settings.json entries.
- Transcript facts used below (checked on this Mac, Claude Code 2.1.301, codex-cli 0.163.0):
  - **Claude:** `~/.claude/projects/<slug>/<id>.jsonl`.
    - Each entry has a `timestamp`.
    - A turn ends with an `assistant` entry whose `message.stop_reason == "end_turn"`, followed by a `system`/`turn_duration` entry.
    - One API response is split over several `assistant` entries that share `message.id` and carry the same `message.usage`, so usage must be counted once per `message.id`.
    - Tool calls are `tool_use` parts with `input.file_path` (Write/Edit/MultiEdit/NotebookEdit).
    - `isSidechain: true` marks sub-agent entries.
  - **Codex:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
    - It starts with `session_meta`.
    - Each turn runs `event_msg/task_started` … `event_msg/task_complete`.
    - `event_msg/token_count.info.total_token_usage` is cumulative.
    - File edits are `apply_patch` calls (`*** Add File:` / `*** Update File:` / `*** Delete File:` lines).
- `claude -p` facts (checked):
  - `--no-session-persistence` writes no transcript. Verified: a probe's session id never appeared on disk.
  - `--json-schema` returns the parsed object in `structured_output` (with `--output-format json`).
  - `--tools ""` disables tools.
  - `--bare` is **not** usable: it skips hooks but forces API-key auth.
- Instruction loading (checked with throwaway repos and `claude -p`):
  - `CLAUDE.local.md` is loaded from the cwd **and every ancestor directory**. That includes subfolders and nested worktrees (`<repo>/.claude/worktrees/<x>`), which are 9 of the 27 Claude project folders on this Mac.
  - `.claude/rules/*.md` loads in the repo and its subfolders but **not** in a nested worktree, which is its own working copy.
  - Auto-memory only auto-loads `MEMORY.md`; its other files are read on demand.
  - `@`-imports must live in a file we'd have to edit, and imports from outside the cwd show an approval dialog.
  - **Codex:** reads at most one file per directory from the git root down to the cwd (`AGENTS.override.md` > `AGENTS.md` > fallbacks), and concatenates them up to `project_doc_max_bytes` (32 KiB). `AGENTS.override.md` *replaces* `AGENTS.md` in the same directory, so it would hide the user's own instructions.
  - `sigma-revenue/sigma-revenue-backend/AGENTS.md` is tracked by git.

## Product decisions

| Topic | Decision |
|---|---|
| Project | A folder on one computer. Fields: name, computer, folder (may start with `~`), optional repo URL. Unique per (computer, folder). **No nesting:** on one computer, a project's folder may not be inside, or contain, another project's folder (decided 2026-10-16). Otherwise a parent's `CLAUDE.local.md` digest would load in the child project's conversations. Projects don't have a section. |
| Todos ↔ projects | A todo keeps its section and may also have one project (`todos.project_id`, nullable). Projects group todos *within* the section system, not instead of it. |
| Conversation → project | Automatic: the project on the same computer whose folder is the **longest path-segment prefix** of the conversation's cwd. `~/programming/sigma-revenue` matches `~/programming/sigma-revenue/sigma-revenue-backend/.claude/worktrees/x` but not `~/programming/sigma-revenue-old`. The app can override it per conversation; an override is never replaced by auto-matching. Creating, editing or deleting a project re-matches every conversation that has no override. |
| Conversation cwd (added during the end-to-end test, 2026-10-17) | A conversation's cwd is its **effective cwd**, not the first one in the transcript. Most sessions here start in `~/programming` and then work in a repo or worktree below it, so the first cwd would put almost every conversation in no project. Rule: count the cwd of every (non-sidechain) user/assistant entry; Codex uses the cwd from `turn_context`. Drop a cwd that is an ancestor of other cwds used in the session when those account for ≥ 25% of the entries. The most used remaining cwd wins; ties go to the most recent. `repo_root` / `repo_url` of a cwd that no longer exists (a removed worktree) come from its nearest existing parent, at most 4 levels up and never HOME or above. |
| Which conversations | Every Claude/Codex transcript on a computer can become a known **session** (stats, project). This is the new `sessions` table; todo links stay in `conversations`. Memory extraction only runs on sessions inside a project folder. |
| Memory kinds | `decision`, `gotcha`, `open_thread`, `done`, `files_changed` |
| Memory size | One or two sentences (≤ 400 chars), an optional list of files relative to the project folder, a confidence from 0 to 1. Memories below 0.5 confidence are dropped on the computer. |
| Memory scope | Each memory belongs to the session's project (moves with it on override) and, if the session is linked to a todo, to that todo. A manual memory from the app has no session. |
| Resolving | The model may list the ids of earlier memories that a new one resolves or replaces (`supersedes`), e.g. a `done` closing an `open_thread`. The server archives those. Pinned memories are never archived this way. |
| Dedup | Server-side, **across the whole project**: a new memory is a duplicate, and is not inserted, when either of these holds:<br>• its normalized text equals that of any memory of the same project (any session, archived included);<br>• its token-set Jaccard is ≥ 0.8 against a memory of the same project and kind from the last 90 days.<br>Without this, every later conversation that reads the digest would re-extract the same gotchas. The unique index stays per session as a hard backstop. The script sends the model, as "already known" (see pipeline step 5), this session's memories plus the project's pinned memories, open threads and recent memories. So `supersedes` can close an open thread from another session. *(my call)* |
| When extraction runs | (a) on demand (`ai-todo-memory run`); (b) after a Claude conversation goes idle (Stop hook → detached, throttled to at most one run per conversation every 30 min: a leading-edge throttle, as asked ("processed at most every N minutes"). Turns that arrive inside the window are picked up by the next trigger after it, or by the nightly run); (c) nightly via launchd at 03:30. Codex has no hook, so it is covered by (a) and (c). |
| Cost bounds | 48 000 chars per chunk; at most 3 chunks per idle trigger and 40 per night per computer. The first run only backfills sessions active in the last 7 days; older history is marked as already read. Default model `sonnet`, configurable. |
| Digest | Per project, on the project's own computer only: the pinned and recent memories, newest first and grouped by kind, ≤ 40 items / 8 KB. It goes into a **separate managed file** (see Feeding memories back). It is on by default and can be switched off per project in the app (`digest_enabled`) or for a whole computer in `todo-hub.conf`. |
| Stats | No LLM. Computed per conversation **and per local day** by `ai-todo-sessions stats --json`, pushed by `ai-todo-memory`, stored per session and per day. The weekly rollup sums days. |
| Section of a conversation (for rollups) | The linked todo's section. Otherwise the single section mapped to the conversation's computer (`spreads-macbook-pro` → Sp, `codbexs-macbook-pro` → I). Otherwise `null` ("unassigned": e.g. an unlinked conversation on this Mac, which serves both Si and P). |
| Terminal | Unchanged. Memories show in an inspector next to it on the Mac and in a sheet on iOS. |

## Data model (schema v3)

v3 only **adds**: three tables, one column on `todos`, and indexes. `migrate()` gets a numbered step `v2 → v3`. Like v1→v2, it takes the `VACUUM INTO <db>.pre-v3-<ts>` backup first, even though nothing is rewritten: rollback safety is the same rule for every step. A fresh database gets everything from `init_pool` directly, with no backup. An older binary that opens a v3 database already logs "schema is newer" and leaves it alone; it ignores the extra column because every `SELECT` names its columns.

```sql
CREATE TABLE IF NOT EXISTS projects (
  id             TEXT PRIMARY KEY,                    -- uuid v4
  name           TEXT NOT NULL,
  computer_id    TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
  folder         TEXT NOT NULL,                       -- may start with ~, no trailing /
  repo_url       TEXT,
  digest_enabled INTEGER NOT NULL DEFAULT 1,
  created_at     TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE(computer_id, folder)
);

ALTER TABLE todos ADD COLUMN project_id TEXT REFERENCES projects(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS todos_project ON todos(project_id);

-- A Claude/Codex conversation known from a computer's transcripts (linked to a todo or not).
CREATE TABLE IF NOT EXISTS sessions (
  tool                  TEXT NOT NULL CHECK(tool IN ('claude','codex','cursor')),
  session_id            TEXT NOT NULL,
  computer_id           TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  cwd                   TEXT NOT NULL,                -- with ~
  title                 TEXT,                         -- first prompt, redacted, ≤ 120 chars
  repo_root             TEXT,                         -- git top level of cwd (main repo for worktrees), with ~
  repo_url              TEXT,                         -- origin URL, credentials stripped
  project_id            TEXT REFERENCES projects(id) ON DELETE SET NULL,
  project_override      INTEGER NOT NULL DEFAULT 0,   -- 1 = set in the app; auto-matching leaves it alone
  prompts               INTEGER NOT NULL DEFAULT 0,
  assistant_turns       INTEGER NOT NULL DEFAULT 0,
  input_tokens          INTEGER,                      -- NULL when the transcript has none
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  active_seconds        INTEGER NOT NULL DEFAULT 0,
  first_activity        TEXT,                         -- ISO 8601 UTC
  last_activity         TEXT,
  files_touched         TEXT NOT NULL DEFAULT '[]',   -- JSON array, relative to cwd, ≤ 200
  models                TEXT NOT NULL DEFAULT '[]',   -- JSON array
  stats_updated_at      TEXT,
  created_at            TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (tool, session_id)
);
CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project_id);
CREATE INDEX IF NOT EXISTS sessions_computer ON sessions(computer_id);

CREATE TABLE IF NOT EXISTS session_days (
  tool                  TEXT NOT NULL,
  session_id            TEXT NOT NULL,
  day                   TEXT NOT NULL,                -- YYYY-MM-DD, the computer's local date
  prompts               INTEGER NOT NULL DEFAULT 0,
  assistant_turns       INTEGER NOT NULL DEFAULT 0,
  input_tokens          INTEGER,
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  active_seconds        INTEGER NOT NULL DEFAULT 0,
  files_touched         INTEGER NOT NULL DEFAULT 0,   -- distinct files edited that day
  PRIMARY KEY (tool, session_id, day),
  FOREIGN KEY (tool, session_id) REFERENCES sessions(tool, session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS session_days_day ON session_days(day);

CREATE TABLE IF NOT EXISTS memories (
  id          TEXT PRIMARY KEY,                       -- uuid v4
  project_id  TEXT REFERENCES projects(id) ON DELETE SET NULL,
  todo_id     TEXT REFERENCES todos(id) ON DELETE SET NULL,
  computer_id TEXT REFERENCES computers(id) ON DELETE SET NULL,
  tool        TEXT,                                   -- NULL for manual memories
  session_id  TEXT,
  kind        TEXT NOT NULL CHECK(kind IN ('decision','gotcha','open_thread','done','files_changed')),
  text        TEXT NOT NULL,
  text_key    TEXT NOT NULL,                          -- normalized text for dedup
  files       TEXT NOT NULL DEFAULT '[]',             -- JSON array
  confidence  REAL,
  source      TEXT NOT NULL DEFAULT 'extracted' CHECK(source IN ('extracted','manual')),
  pinned      INTEGER NOT NULL DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS memories_project ON memories(project_id, archived, created_at);
CREATE INDEX IF NOT EXISTS memories_session ON memories(tool, session_id);
CREATE INDEX IF NOT EXISTS memories_todo ON memories(todo_id);
CREATE UNIQUE INDEX IF NOT EXISTS memories_dedup ON memories(tool, session_id, kind, text_key)
  WHERE session_id IS NOT NULL;
```

Notes:

- **`text_key`:** lowercase, every run of non-alphanumeric characters becomes one space, trimmed. It is recomputed whenever the text is edited.
- **Deleting a project:** todos lose their project, sessions are re-matched to the remaining projects (overrides pointing at the deleted project are cleared), and memories follow their session's new project or become project-less. Nothing is deleted.
- **Deleting a todo:** its memories lose `todo_id` but stay with the project.
- **Deleting a computer:** still `409` while a project uses it. Otherwise its sessions and their days are removed (cascade), and memories keep their text with `computer_id = NULL`.
- **Path normalization for matching** (server, `paths.rs`): the input is a path with or without `~`. Strip trailing `/`, collapse `//`, and compare segment lists. Both sides are stored with `~` (the scripts already send `~`-relative cwds). A folder given as `/Users/<username>/…` for the computer's `username` is normalized to `~/…` on write.
- **Upserting a session** from stats keeps `project_override` and the overridden `project_id`. Otherwise it re-runs matching.
- **The todo `SELECT`** gains `project_id`. `Conversation` responses gain `project_id`: the session's project, or matched on the fly when the session isn't known yet.

## API (all under `/api`, Bearer token as today)

Shared types go in `todo-shared`. New fields on existing types use `#[serde(default, skip_serializing_if = "Option::is_none")]`, so old clients and old scripts are unaffected. Every mutation calls `broadcaster.send()`. `/api/describe` lists the new endpoints; section codes appear only as codes.

### Todos (extended)

| Method | Path | Change |
|---|---|---|
| `GET` | `/todos` | New optional filter `?project_id=<id>`. Each todo gains `project_id` (omitted when null). |
| `POST` | `/todos` | Body may include `project_id` (must exist: `404 Project not found`). |
| `PATCH` | `/todos/{id}` | Body may include `"project_id": "<id>"` or `"project_id": null` (clear). The field is absent when the project is unchanged (same `Option<Option<_>>` pattern as `due_date`). |

### Projects

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/projects` | List, with counts: `open_todos`, `sessions`, `memories` (not archived), `last_activity`. Ordered by name. |
| `POST` | `/projects` | `{name, computer_id, folder, repo_url?, digest_enabled?}` → `201`. `409` on a duplicate (computer, folder) or when the folder is inside, or contains, another project's folder on the same computer (the message names the conflicting project). Re-matches sessions. |
| `GET` | `/projects/{id}` | One project (same shape as list items). |
| `PATCH` | `/projects/{id}` | Any of `name, folder, repo_url (nullable), digest_enabled`. A folder change re-matches sessions; the same nesting `409` applies. |
| `DELETE` | `/projects/{id}` | See "Deleting a project". → `{deleted: id}` |
| `GET` | `/projects/suggestions` | Suggested projects, from session and conversation cwds (see below). |

`Project` JSON:

```json
{"id":"…","name":"sigma-revenue","computer":{…Computer…},"folder":"~/programming/sigma-revenue",
 "repo_url":null,"digest_enabled":true,"created_at":"…","updated_at":"…",
 "open_todos":3,"sessions":41,"memories":57,"last_activity":"2026-10-16T09:12:03Z"}
```

**Suggestions:**

- **Folders:** for every known cwd (`sessions.cwd`, `conversations.cwd`) of a computer, strip a `/.claude/worktrees/<x>` suffix and everything after it. Then cut to the first two segments below `~`, or the first three for absolute paths outside home. Examples: `~/programming/sigma-revenue`, `~/Spread/Repository`. A folder with fewer segments is used as is, e.g. `~/programming`.
- **Grouping:** by (computer, folder), counting sessions and the latest activity.
- **Dropped:** folders that already are a project, lie inside one, or contain one, since those could not be created.
- **Name:** the folder's last segment.
- **Repo URL:** the `repo_url` of a session whose `repo_root` equals the folder, if there is one.
- **Order:** by session count, descending.

```json
[{"computer":{…},"folder":"~/programming/sigma-revenue","name":"sigma-revenue","repo_url":null,
  "sessions":19,"last_activity":"2026-10-16T09:12:03Z","example_cwds":["~/programming/sigma-revenue/sigma-revenue-backend"]}]
```

The app accepts a suggestion through `POST /projects` (adjusting the name or folder first if needed). There is no separate "accept" endpoint.

### Sessions and stats

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/sessions/stats` | Bulk upsert from a computer (script). Body below. → `{upserted: n, sessions: [{tool, session_id, project_id}]}`. `404` for an unknown `computer_id`. |
| `GET` | `/sessions` | Filters: `project_id`, `computer_id`, `since` (last_activity ≥), `limit` (default 200). Each item: the session fields plus `todo_id` and `status` when linked to a todo (joined from `conversations`). Newest first. |
| `PUT` | `/sessions/{tool}/{session_id}/project` | `{"project_id":"<id>"}` sets an override (the project must be on the session's computer, else `409`). `{"project_id":null}` sets an override to "no project". `{"auto":true}` clears the override and re-matches. Memories of the session move with it. |
| `GET` | `/stats/weekly` | `?week_start=YYYY-MM-DD` (must be a Monday; default: the Monday of the server's local today), optional `project_id`. Body below. |

`POST /sessions/stats` request (the `stats --json` output wrapped with the computer id):

```json
{"computer_id":"78e7ef89-…",
 "sessions":[{"tool":"claude","session_id":"…","cwd":"~/programming/todo-app","title":"Add projects…",
   "repo_root":"~/programming/todo-app","repo_url":"git@github.com:tsetsoo/todo-app.git",
   "stats":{"prompts":12,"assistant_turns":12,"input_tokens":4021,"output_tokens":51234,
            "cache_read_tokens":9123456,"cache_creation_tokens":402311,"active_seconds":5400,
            "first_activity":"2026-10-16T07:01:12Z","last_activity":"2026-10-16T09:12:03Z",
            "files_touched":["crates/todo-server/src/db.rs"],"models":["claude-opus-5-5"]},
   "days":[{"day":"2026-10-16","prompts":12,"assistant_turns":12,"input_tokens":4021,"output_tokens":51234,
            "cache_read_tokens":9123456,"cache_creation_tokens":402311,"active_seconds":5400,"files_touched":1}]}]}
```

`days` replaces all of that session's day rows; a day missing from the list is deleted. Stats are a full recompute per transcript, so the upsert is idempotent.

`GET /stats/weekly` response:

```json
{"week_start":"2026-10-12","week_end":"2026-10-18",
 "totals":{"sessions":23,"prompts":180,"assistant_turns":176,"input_tokens":…,"output_tokens":…,
           "cache_read_tokens":…,"cache_creation_tokens":…,"active_seconds":61200,"files_touched":88},
 "by_project":[{"project_id":"…","name":"todo-app", …same counters…},{"project_id":null,"name":null, …}],
 "by_section":[{"section":"Sp", …},{"section":null, …}],
 "by_computer":[{"computer_id":"…","name":"spreads-macbook-pro", …}]}
```

- **Counting:** `sessions` = distinct sessions with at least one day in the week. Tokens are summed over non-null values; when every value is null, the token fields are null.
- **Project filter:** every grouping is restricted to that project's sessions.

### Memories

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/memories` | Filters: `project_id`, `todo_id`, `kind` (repeatable or comma-separated), `since` (created_at ≥), `tool` + `session_id`, `pinned`, `include_archived` (default false), `limit` (default 200, max 1000). Order: pinned first, then `created_at` descending. |
| `POST` | `/memories` | One manual memory: `{kind, text, files?, project_id?, todo_id?, pinned?}`. At least one of project/todo is required. A todo without a project → the memory takes the todo's project. → `201` |
| `POST` | `/memories/bulk` | From the script, one session per call (body below). |
| `PATCH` | `/memories/{id}` | Any of `text, kind, files, pinned, archived, project_id (nullable), todo_id (nullable)`. Editing `text` recomputes `text_key`; a clash with another memory of the same session → `409`. |
| `DELETE` | `/memories/{id}` | Hard delete → `{deleted: id}` |

Pinning and archiving are `PATCH {"pinned":true}` / `PATCH {"archived":true}`; there are no separate verbs. `Memory` JSON:

```json
{"id":"…","project_id":"…","todo_id":null,"computer_id":"…","tool":"claude","session_id":"…",
 "kind":"gotcha","text":"…","files":["deploy/pi/todo-update.sh"],"confidence":0.8,
 "source":"extracted","pinned":false,"archived":false,"created_at":"…","updated_at":"…"}
```

`POST /memories/bulk`:

```json
{"computer_id":"…","tool":"claude","session_id":"…","cwd":"~/programming/todo-app",
 "memories":[{"kind":"decision","text":"…","files":["…"],"confidence":0.85,"supersedes":["<memory id>"]}]}
```

- **Session row:** the server creates a minimal one if it is missing (cwd only, matched to a project), so memories always get a project.
- **Todo:** `todo_id` comes from `conversations` on (tool, session_id).
- **Validation:** `text` is trimmed, 1–400 chars (longer → `400`); `files` ≤ 20 entries; `confidence` is 0–1.
- **`supersedes`:** applied to non-pinned memories of the same project, from any session; anything else is ignored silently.
- **Dedup:** project-wide, as in Product decisions. Each memory found to be a duplicate is counted in `duplicates`.
- **Response:** `{"inserted":[Memory…],"duplicates":2,"archived":["<id>"],"project_id":"…","todo_id":null}`. `201`, even when everything was a duplicate.

### Existing endpoints

Unchanged. `Conversation` and `Todo` gain only the optional `project_id`. The hook endpoint, `ai-todo-open` and `ai-todo-sessions list/delete/prune` keep their contracts.

## Host side (ai-session-remote `scripts/todo`)

### Configuration (`~/.ai-remote/todo-hub.conf`, existing file, new optional keys)

```sh
TODO_HUB_URL='http://100.118.255.23:8080'
TODO_API_TOKEN='…'
TODO_COMPUTER_ID='78e7ef89-…'          # new; install.sh --computer-id, or auto-detected (below)
AI_TODO_MEMORY='on'                     # on|off — master switch for extraction on this computer
AI_TODO_STATS='on'                      # on|off — push stats (numbers, cwd/repo, redacted title) to the Pi
AI_TODO_MEMORY_DIGEST='on'              # on|off — write digests on this computer
AI_TODO_MEMORY_MODEL='sonnet'
AI_TODO_MEMORY_DEBOUNCE_MIN='30'
AI_TODO_MEMORY_BACKFILL_DAYS='7'
AI_TODO_MEMORY_MAX_CHUNKS_NIGHT='40'
AI_TODO_MEMORY_MIN_CONFIDENCE='0.5'
```

Auto-detecting `TODO_COMPUTER_ID` when it is unset: `GET /api/computers`, then keep those whose `username == $USER` and whose `hostname` is one of `tailscale ip -4`, the Tailscale MagicDNS name, or `hostname -s`. If exactly one matches, use it and log a hint to set it. Otherwise refuse with exit 65.

### `ai-todo-sessions stats --json` (new subcommand)

```
ai-todo-sessions stats --json [--since DAYS] [--session <claude|codex>:<id>]... [--tool claude|codex]
```

- **Scope:** sessions whose transcript changed in the last `DAYS` days (default 1), or exactly the listed sessions.
- **Output:** a JSON array of the `sessions[]` items from `POST /sessions/stats`, without the wrapper.
- **Parsers:** reuses the existing ones and skips sidechain/sub-agent entries.
- **Prompts:** real prompts (same `real_prompt` rule as `list`).
- **Assistant turns:** Claude: `end_turn` assistant entries. Codex: `task_complete` events.
- **Tokens:** Claude: `message.usage` summed once per `message.id`. Codex: the latest `total_token_usage`, with per-day deltas between `token_count` events. Codex has no cache-creation figure, so that field is null.
- **Active time:** the sum of gaps under 10 min between consecutive timestamped user/assistant entries. Each gap counts on the later entry's local day.
- **Files touched:** distinct paths from Write/Edit/MultiEdit/NotebookEdit `file_path` (Claude) and `apply_patch` headers (Codex). Relative to cwd when inside it, else `~`-relative; capped at 200.
- **`repo_root`:** `git -C <cwd> rev-parse --path-format=absolute --git-common-dir` → its parent (so worktrees resolve to the main repo), with `~`.
- **`repo_url`:** `git remote get-url origin` with any `user:pass@` stripped. Both are cached per cwd within a run; when the cwd no longer exists, both are null.
- **Title:** first real prompt, redacted (same rules as memories), ≤ 120 chars.

### `ai-todo-memory` (new script, sh wrapper + embedded Python, same style as ai-todo-sessions)

```
ai-todo-memory run <claude|codex> <session_id> [--dry-run] [--no-post] [--no-digest] [--force]
ai-todo-memory trigger <claude|codex> <session_id> [--transcript PATH]   # from ai-todo-hook; detached
ai-todo-memory nightly                                                   # from launchd
ai-todo-memory digest [--project <id>] [--dry-run]
ai-todo-memory status [--json]
```

- **Flags:** `--dry-run` prints the extracted memories (JSON) and changes nothing: no POST, no offset update, no digest. `--no-post` / `--no-digest` skip one step. `--force` ignores the debounce and the "not in a project" check.
- **`run`** is the on-demand path. It is used by the end-to-end test and is available to the app later over SSH.
- **State:** `~/.ai-remote/memory-state/` (mode 700).
  - `sessions/<tool>-<id>.json`: `{path, inode, offset, last_entry_id, last_run, last_ok}`.
  - `projects.json`: the cached `GET /api/projects` for offline matching.
  - `digests.json`: what was written where, including `created_by_us` flags.
  - `nightly.json`: last stats push.
  - `memory.log`: ids, counts and errors only, **never transcript text**; rotated at 1 MB.
- **Locks:** `fcntl` locks. `trigger` takes the global lock non-blocking and exits if another run holds it; the nightly run catches up later. `run`/`nightly` wait for it.

**Pipeline for one session:**

1. **Stats first, independent of memories:** unless `AI_TODO_STATS=off`, push this session's stats (step 6) for **every** session, in a project or not. This is cheap and needs no LLM.

   **Skip checks** for extraction:
   - `AI_TODO_MEMORY=off`.
   - The session's cwd is not inside a project of *this* computer (from `projects.json`, refreshed when older than 10 min). `--force` bypasses this.
   - For `trigger`: last run less than `AI_TODO_MEMORY_DEBOUNCE_MIN` ago.
   - The cwd is under `~/.ai-remote` or a temp dir.
2. **Read only the new part:**
   - Start at the stored `offset`. If the file shrank or its inode changed, look for `last_entry_id` (Claude `uuid` / Codex line hash) and continue after it. If it isn't found, start from 0; server dedup and the "already known" list keep this safe.
   - **Never past the last complete turn:** stop at the last Claude `end_turn` assistant entry (+ its `turn_duration`) or Codex `task_complete`. A turn that is still running is left for the next run; this is how "skip conversations running mid-turn" is enforced.
   - If the new part has no real prompt or no complete turn, there is nothing to do.
3. **Render compactly:**
   - User prompts: full, each cut at 4 000 chars.
   - Assistant text: each cut at 2 000 chars.
   - Tool calls as one line each, e.g. `[Edit crates/todo-server/src/db.rs]`, `[Bash: cargo test -p todo-server]` (command cut at 200 chars).
   - Tool results only when they are errors, first 300 chars.
   - Thinking, attachments, system entries, sidechains and images are dropped.
4. **Redact** (rules below), then **chunk** at 48 000 chars on entry boundaries. A trigger processes up to 3 chunks; the rest waits for the nightly run, which is capped at 40 chunks per computer.
5. **For each chunk:**
   - **Already known:** (id, kind, text), capped at 80 items / 12 000 chars, which is counted inside the chunk budget:
     - this session's memories (`GET /api/memories?tool=&session_id=&include_archived=true&limit=100`);
     - the project's pinned memories and non-archived `open_thread`s;
     - the project's newest other non-archived memories from the last 30 days;
     - the memories from earlier chunks in this run.
   - **Extraction run:** with `AI_TODO_MEMORY_RUN=1`, in the fixed empty dir `~/.ai-remote/memory-state/run` as cwd. No CLAUDE.md or rules load there, and repeated runs never leave a new folder under `~/.claude/projects` each time. (A probe without `--setting-sources ""` left an empty `memory/` folder for its cwd; with it, nothing was created.)

     ```
     claude -p --no-session-persistence --output-format json --json-schema "$SCHEMA" \
            --tools "" --strict-mcp-config --setting-sources "" --model "$AI_TODO_MEMORY_MODEL" \
            --system-prompt "$SYSTEM_PROMPT"
     ```

     The user message goes on stdin.
   - **Result:** read `structured_output`; on `is_error`, a non-zero exit or no structured output, abort this session, keep the old offset and log it. Validate against the schema again locally, drop confidence < `AI_TODO_MEMORY_MIN_CONFIDENCE`, and redact the output a second time.
   - **Post:** `POST /api/memories/bulk`. On success, save `offset` = the end of this chunk.
6. **Push stats:** `ai-todo-sessions stats --json --session <tool>:<id>` → `POST /api/sessions/stats`. It runs in step 1, before any memories are posted, so the session row has its title and repo fields, and again after extraction. It is governed by `AI_TODO_STATS` only, not by `AI_TODO_MEMORY`.
7. **Refresh digests** for the projects that got new memories (unless `--no-digest`).

**`nightly`:**

1. Unless `AI_TODO_STATS=off`: push stats for every session changed since the last successful push (`--since` derived from `nightly.json`, minimum 1 day). In a project or not, and regardless of `AI_TODO_MEMORY`.
2. Run the pipeline for every project session with unread complete turns, oldest activity first, within the chunk cap.
3. Rewrite the digests of all of this computer's projects.

**First run:** sessions whose transcript was last modified more than `AI_TODO_MEMORY_BACKFILL_DAYS` ago get `offset = EOF` without extraction.

**`launchd`:** `~/Library/LaunchAgents/com.ai-remote.todo-memory.plist`, `StartCalendarInterval` 03:30, running `~/.ai-remote/bin/ai-todo-memory nightly`, with stdout/stderr going to `memory-state/launchd.log`. A missed run (Mac asleep) runs on wake.

### Safety requirements (how each is met)

| Requirement | Mechanism |
|---|---|
| No transcript of its own | `--no-session-persistence` (verified), `-p` only |
| Can't trigger itself | `AI_TODO_MEMORY_RUN=1` in the child env; `ai-todo-hook` exits 0 immediately when it is set. In addition, `--setting-sources ""` loads no user hooks, the run has no tools, and its cwd (`~/.ai-remote/…`) is skipped by step 1. |
| Skip mid-turn | Only complete turns are read (pipeline step 2); `trigger` fires from the Stop hook, i.e. right after a turn ends |
| Cap input | 48 000-char chunks, 3 per trigger, 40 per night, a 7-day backfill window; per-entry truncation |
| Redact | Before anything leaves the script (model input, titles, memories, file names) |
| Only memories to the Pi | The Pi receives memories, stats numbers, file paths, cwd/repo fields and a redacted 120-char title. Never transcript text. |
| Codex | Same pipeline, with the Codex parser and turn boundary (`task_complete`) |

### Redaction rules (shared by `ai-todo-memory` and `stats`)

Each match is replaced with `[REDACTED:<type>]`:

- **PEM private keys:** `-----BEGIN [A-Z ]*PRIVATE KEY-----` … `END` blocks.
- **Prefixed tokens:** `sk-ant-…`, `sk-…` (≥ 20 chars), `ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` / `github_pat_…`, `glpat-…`, `xox[abposr]-…`, `AKIA[0-9A-Z]{16}`, `AIza[0-9A-Za-z_-]{35}`, Stripe `[rs]k_(live|test)_…`.
- **JWTs:** `eyJ….….…`
- **Bearer tokens:** `Bearer <token>`.
- **Credentials in URLs:** `scheme://user:pass@`.
- **Key/value secrets:** `(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)\s*[:=]\s*\S+`, case-insensitive. The key is kept and the value redacted.
- **Known local secrets:** the literal values of `TODO_API_TOKEN` and of every `*_TOKEN|*_KEY|*_SECRET|*_PASSWORD` variable in the script's own environment.
- **Long random strings:** high-entropy strings of ≥ 32 chars of `[A-Za-z0-9+/_=-]` that contain both letters and digits, except hex git SHAs of 40 chars and UUIDs.

Tests cover each rule plus the "not redacted" exceptions.

### `ai-todo-hook` changes

- First line after argument parsing: `[ -n "${AI_TODO_MEMORY_RUN:-}" ] && exit 0`.
- On `idle` **from the Stop event**, the hook starts `~/.ai-remote/bin/ai-todo-memory trigger claude <sid> --transcript <transcript_path>`. It is fully detached (`nohup … </dev/null >/dev/null 2>&1 &`) and runs **before** the `ai/claude/todo-*` tmux filter, because memories apply to every conversation in a project folder, not only todo conversations. The hook still returns immediately, and the Python trigger exits within milliseconds when the cwd isn't in a project.
- Telling Stop from Notification needs no parsing: Stop already calls the hook as `ai-todo-hook idle`, while Notification calls `ai-todo-hook waiting`, which only later becomes idle for `idle_prompt`. So the trigger fires when the argument is `idle`. Nothing else changes; status posting is untouched.

### `install.sh` changes

- Install `ai-todo-memory`. Create `~/.ai-remote/memory-state` (700).
- New `--computer-id ID`, written to `todo-hub.conf` the same way as `--hub-url` / `--token`.
- macOS: write the LaunchAgent plist and `launchctl bootstrap gui/$UID` it (`bootout` first when re-installing). With `--no-nightly`, skip it.
- `--uninstall`: `bootout` + remove the plist and `ai-todo-memory`. Keep `memory-state/` and print its path. It does **not** remove written digests; that is `ai-todo-memory digest --remove-all`, which runs before the binary is removed when `--uninstall --remove-digests` is passed.
- No changes to `~/.claude/settings.json` beyond what the installer already merges: the existing Stop hook entry is reused.

## Feeding memories back (digest)

### Mechanism (decision)

**Claude Code:**

- The script owns `<project folder>/CLAUDE.local.md` when the project has none of its own. It never edits a CLAUDE.local.md that it didn't create: one without our marker on line 1.
- In that case it falls back to `<project folder>/.claude/rules/todo-hub-memories.md`.

Why this beats the candidates:

| Candidate | Loads automatically in | Touches user files | Verdict |
|---|---|---|---|
| **`CLAUDE.local.md` (chosen)** | cwd **and every ancestor**, so the folder, all subfolders and nested `.claude/worktrees/*` (verified) | No (only when absent or already ours) | Reaches every conversation in the project, including the worktrees that a third of this Mac's conversations run in. It is personal by design (never meant to be committed), needs no approval dialog, and is a single file we own entirely. |
| `.claude/rules/todo-hub-memories.md` | repo + subfolders, **not** nested worktrees (verified) | No | Fallback only: it misses worktree conversations. |
| Auto-memory file + pointer line in `MEMORY.md` | Only `MEMORY.md` auto-loads; the digest file is read only if the model decides to | Yes: a line in a Claude-managed file that Claude itself rewrites | Rejected: not reliably loaded, and it edits a memory file. |
| `@`-import line | Wherever the hosting file loads | Yes: needs a line in CLAUDE.md / CLAUDE.local.md; external paths trigger an approval dialog | Rejected: edits the user's file. |

Git safety:

- **Inside a git work tree:** when the managed file isn't already ignored (`git check-ignore -q`), the script appends its path once to `$(git rev-parse --git-common-dir)/info/exclude`. That file is local-only and never committed, so the managed file can't land in a commit.
- **A plain folder** that contains repos (e.g. `~/programming/sigma-revenue`) needs nothing; the ancestor walk still reaches every repo below it.

**Codex:**

- **Where:** a managed block in `AGENTS.md` at the **working-copy top level** of each Codex conversation's cwd in the project.
  - The script computes it locally with `git -C <cwd> rev-parse --show-toplevel`; nothing new is stored on the Pi. It falls back to the project folder when that is itself a top level.
  - Linked worktrees (`--git-dir` ≠ `--git-common-dir`) are skipped: they are short-lived, and their AGENTS.md is usually tracked anyway. *(my call)*
  - Codex only walks down from its own working copy's top level, so a block in the main repo or in a plain parent folder would never be read from a worktree.
- **No Codex sessions:** no Codex block is written, so Claude-only projects never get an AGENTS.md.
- **Not `AGENTS.override.md`:** it would *replace* the user's AGENTS.md in that directory.
- **Markers:**

  ```
  <!-- BEGIN ai-todo-memory: managed by todo-hub, rewritten automatically; edit memories in the app -->
  …digest…
  <!-- END ai-todo-memory -->
  ```

  The block is replaced in place, and every byte outside the markers is preserved. A missing block is appended after one blank line. A file with an unbalanced or duplicated marker is left untouched and the error is logged.
- **Missing AGENTS.md:** the file is created with only the block, git-excluded as above, and `created_by_us` is recorded. Removing the block deletes the file again if nothing else is in it.
- **Tracked AGENTS.md** (e.g. sigma-revenue-backend): **skipped**, and `status` and the log report it. The block would otherwise show in `git diff` and end up in commits.
- **Size:** the block is capped at 6 KB to stay well inside Codex's 32 KiB doc budget.

### Digest format (both tools; Codex gets the same body inside the markers)

```markdown
<!-- Managed by ai-todo-memory (todo-hub). Rewritten automatically — edit, pin or archive memories in the todo app. -->
# Project memory: todo-app

Notes extracted from earlier AI conversations in this project (newest first). They can be out of date — verify before relying on them.

## Open threads
- (pinned) Decide whether Codex digests should go into tracked AGENTS.md files. — 2026-10-16
- Weekly rollup ignores sessions without day rows. — 2026-10-15 · crates/todo-server/src/stats.rs

## Decisions
- …

## Gotchas
- …

## Recently done
- …

## Files changed
- …
```

Rules:

- **Order:** groups in the order open threads, decisions, gotchas, recently done, files changed. Within a group, pinned first, then newest. Empty groups are omitted.
- **Selection:** all pinned memories, plus non-archived ones from the last 60 days. `done` and `files_changed` only from the last 14 days, at most 5 each.
- **Bounds:** at most 40 items and 8 KB in total (6 KB for Codex). Lower-priority items are cut first, from the end of the group order.
- **No churn:** the content has no generation timestamp or run id, only memory dates (`YYYY-MM-DD`). The script renders, compares the bytes with what is on disk, and writes (temp file + rename) only if they differ, so an unchanged digest never touches the file and its mtime stays put.
- **Section codes** appear only as written in memories; the digest adds no section text.
- **No memories selected:** the managed file is removed (or the block is removed).

### Switching off

- **Per project:** the app's "Feed memories into new conversations" toggle (`digest_enabled = false`). On its next run (trigger, nightly or `digest`), the computer removes our CLAUDE.local.md / rules file and the AGENTS.md block (deleting the AGENTS.md if we created it and it's now empty).
- **Per computer:** `AI_TODO_MEMORY_DIGEST='off'`, followed by `ai-todo-memory digest --remove-all`.
- **Idempotent:** running `digest` twice in a row changes nothing the second time. A test asserts the mtimes.

## Extraction prompt and schema

### System prompt (fixed, in the script)

```
You extract durable project memory from an excerpt of an AI coding conversation.

Return only facts that would help a future conversation in the same project:
- decision: a choice that was made and why (architecture, library, approach, convention).
- gotcha: a non-obvious pitfall, constraint, environment quirk or failure cause, and how it was handled.
- open_thread: work that was started or agreed but is not finished, or a question left open.
- done: a meaningful piece of work that was completed (not every small step).
- files_changed: a one-sentence summary of a coherent change with the files involved.

Rules:
- One or two plain sentences per memory, self-contained, no "the user said". At most 12 memories.
- Never include secrets, tokens, passwords, keys, personal data or customer data, even if present.
- Do not repeat anything in ALREADY KNOWN. If a new memory resolves or replaces an already-known one
  (e.g. an open thread is now done, or a decision was reversed), put that memory's id in "supersedes".
- Section codes like Sp, I, Si and P are opaque labels: copy them as-is, never expand or interpret them.
- File paths relative to the project folder.
- Skip what only matters to this session: temporary or scratch paths (e.g. under ~/.claude/jobs/ or /tmp),
  which agent or reviewer is currently working on what, and progress that the next step will make stale.
- confidence: 0.9+ explicitly stated and confirmed; 0.6–0.8 clearly implied; below 0.5 speculative.
- If nothing durable happened, return an empty list.
```

### User message (stdin)

```
PROJECT: <name> (<folder>) on <computer name>
CONVERSATION: <tool> <session_id>, cwd <cwd>, excerpt <n>/<m>, <first ts> – <last ts>

ALREADY KNOWN:
- [<id>] <kind>: <text>
…

EXCERPT:
USER: …
ASSISTANT: …
[Edit crates/todo-server/src/db.rs]
…
```

### JSON schema (`--json-schema`)

```json
{"type":"object","additionalProperties":false,"required":["memories"],
 "properties":{"memories":{"type":"array","maxItems":12,"items":{
   "type":"object","additionalProperties":false,"required":["kind","text","confidence"],
   "properties":{
     "kind":{"type":"string","enum":["decision","gotcha","open_thread","done","files_changed"]},
     "text":{"type":"string","minLength":10,"maxLength":400},
     "files":{"type":"array","maxItems":20,"items":{"type":"string","maxLength":300}},
     "confidence":{"type":"number","minimum":0,"maximum":1},
     "supersedes":{"type":"array","maxItems":10,"items":{"type":"string"}}}}}}}
```

## Privacy rules

1. Transcripts never leave the computer, except as **redacted excerpts sent to Claude through the user's own `claude -p`**: the same service the conversation already ran on, with no new third party. That run writes no transcript.
2. The Pi stores only:
   - memories (≤ 400 chars, redacted twice);
   - stats numbers;
   - edited file paths;
   - cwd, repo root, and repo URL without credentials;
   - a redacted title of ≤ 120 chars.
3. No secret ever goes into the prompt, the Pi or a digest (redaction rules above). The script's logs hold ids, counts and errors only.
4. Digests are written only on the project's own computer, only into our managed file or block, and are git-excluded or skipped so they can't be committed.
5. Every memory can be edited, archived or deleted in the app. Deleting a project or todo never deletes memories silently; deleting a memory is permanent.
6. Kill switches: `AI_TODO_MEMORY=off` (extraction), `AI_TODO_STATS=off` (stats, titles and cwd/repo fields), `AI_TODO_MEMORY_DIGEST=off`, per-project `digest_enabled`, `install.sh --no-nightly`.

## App (ai-session-remote, iOS + macOS)

Core (`AISessionCore/TodoHub`):

- **Models:** `Project`, `ProjectSuggestion`, `Memory`, `MemoryKind`, `Session` (stats + link), `SessionStats`, `WeeklyStats`, `StatsCounters`, and the requests.
- **New optional fields:** `projectId` on `Todo` / `Conversation` / `CreateTodoRequest` / `UpdateTodoRequest`. In `UpdateTodoRequest`, an explicit `null` must encode for "clear".
- **Client methods:** one per endpoint above.
- **Cache:** extends the snapshot with `projects`, decoded with a default (`[]`) so old cache files still load.

UI:

- **Projects tab** (iOS and Mac, between Todos and Hosts):
  - Projects grouped by computer, each showing open todos, last activity and memory count.
  - A **Suggested** section on top. Tapping a suggestion opens a prefilled create sheet where name and folder can be edited. The same sheet is used for "New project", with a computer picker and a folder field.
- **Project page:**
  - Header: computer, folder, repo link, digest toggle.
  - **This week** card: active time, prompts, turns, tokens (output + total), sessions, files, with a week stepper.
  - **Todos:** the project's todos, using the existing row with its conversation status badge.
  - **Conversations:** sessions newest first, with title, tool, last activity and a status badge when linked to a todo. Tapping a linked one opens its todo's conversation as today. An unlinked one offers the existing "New todo from conversation" flow and "Move to project…".
  - **Memories:** grouped by kind. Rows show text, files, date and a pin marker. Swipe or context menu: Pin/Unpin, Archive, Delete (with confirmation). Tap to edit (text, kind, files). "Add memory". A "Show archived" toggle.
- **Todos:**
  - A project picker in the add sheet and in the todo's context menu ("Project ▸").
  - The todo row shows a small project label when the section list isn't filtered by project.
- **Terminal:** unchanged.
  - **Mac:** a toolbar button toggles `.inspector` with the **Memories panel**: memories of the conversation's project, with this session's memories first, editable as above.
  - **iOS:** the same panel in a sheet from a toolbar button.
  - Changes refresh through `/api/ws` as everything else does.
- **Not in v1:** editing the extraction settings from the app, or triggering `ai-todo-memory run` over SSH.

## Tests

- **Rust** (`cargo test`, `cargo clippy --all-targets -- -D warnings` as CI does):
  - **Migration:** a v2 fixture DB (today's Pi schema plus rows) → v3 keeps every row, takes exactly one backup, re-running is a no-op, and a fresh DB has no backup. A v3 DB opened by `schema_version` reports 3. Todos keep working with `project_id` NULL.
  - **Path matching:** longest-prefix, segment boundaries, `~` vs `/Users/<u>`, trailing slash, worktree paths, other computers ignored, override kept, re-match on project create/update/delete.
  - **Projects:** CRUD, duplicate folder → 409, nested/containing folder → 409 on create and on PATCH (other computers are unaffected), computer delete → 409 while used, suggestions grouping/truncation/exclusion.
  - **Memories:** bulk insert, exact and fuzzy dedup across sessions of a project (and not across projects), supersedes (incl. pinned/other-project ignored), filters, PATCH re-key + 409, manual create needing project/todo, todo delete → `todo_id` null.
  - **Stats:** upsert idempotence, day replacement, weekly rollup grouping (project, section rules incl. the ambiguous Mac → null, computer), null tokens, the project filter, a non-Monday → 400.
  - **Compatibility:** old-shape requests (no `project_id`) still deserialize; `Todo` JSON omits `project_id` when null.
- **Scripts** (`scripts/todo/test-todo-scripts.sh`, the existing sandbox: temp HOME, fake hub, private tmux):
  - **Fixtures:** Claude and Codex transcripts with complete and incomplete turns, split assistant entries sharing a `message.id`, sidechains, and secrets of every redaction type.
  - **Fake `claude`:**
    - returns canned `structured_output` JSON;
    - records its argv, env (`AI_TODO_MEMORY_RUN`), cwd and stdin;
    - fails on demand.
  - **Assertions:**
    - the required flags are present (`--no-session-persistence`, `--json-schema`, `--tools ""`, `--setting-sources ""`);
    - stdin holds no secret;
    - only complete turns are read and the offset advances only after a successful POST;
    - a second run sends nothing new;
    - chunking caps hold;
    - the debounce works;
    - the hook is a no-op under `AI_TODO_MEMORY_RUN=1`, and the Stop trigger detaches;
    - `stats --json` numbers match hand-computed fixtures (token dedup, active-time gaps, day split, files);
    - the digest is written into a fake project, re-running doesn't change the mtime, the user's own CLAUDE.local.md is never touched (fallback to the rules file), the AGENTS.md block is replaced in place with outside bytes intact, a tracked AGENTS.md is skipped, `.git/info/exclude` gets one line, and switching off removes our files only;
    - `install.sh` writes, bootstraps and boots out the plist through a fake `launchctl`.
- **Swift:** decoding of every new model (including absent optional fields and old cache files), client paths, queries and bodies via the existing URLProtocol stub (including the explicit `project_id: null` clear), and the store helpers for grouping memories by kind. Both Xcode schemes (iOS + macOS) build green.

## Implementation order and branches

The contract above is the source of truth. Three parallel workers, each in its own worktree created with `git -C <repo> worktree add <absolute path>`:

1. **Server:**
   - Worktree: `todo-app` → `/Users/tsvetelinpantev/programming/todo-app/.claude/worktrees/projects-memories-server`.
   - Branch: `feature/projects-memories-server`.
   - Work: schema v3 + migration, `paths.rs`, `projects.rs`, `memories.rs`, `stats.rs`, shared types, describe, tests.
2. **Scripts:**
   - Worktree: `ai-session-remote` → `/Users/tsvetelinpantev/programming/ai-session-remote/.claude/worktrees/projects-memories-scripts`.
   - Branch: `feature/projects-memories-scripts`.
   - Work: `stats` subcommand, `ai-todo-memory`, the hook change, the installer, script tests.
3. **App:**
   - Worktree: `ai-session-remote` → `/Users/tsvetelinpantev/programming/ai-session-remote/.claude/worktrees/projects-memories-app`.
   - Branch: `feature/projects-memories-app`.
   - Work: core models and client, store, views, Swift tests.

After those:

- Scripts and app merge into one ai-session-remote PR; the server is one todo-app PR.
- **End-to-end on this Mac:**
  - A local `todo-server` on a copy of the Pi DB, local `HOME`-isolated digests, and a real transcript.
  - Extraction from **one** real conversation with `--dry-run --no-digest`, shown to you before anything is posted or written into a project.
- Code review of both PRs, fixes, then all tests again.
- **Rollout only on your go:**
  - Back up the Pi DB.
  - Merge. The Pi updater deploys and the v3 migration runs with its own backup; verify `user_version = 3` and the row counts.
  - `install.sh --computer-id …` on all three Macs.
  - Rebuild the Mac app into `~/Applications`.

## Non-goals (v1)

- Server-side extraction, server-rendered digests, or any server access to transcripts.
- Semantic or embedding search over memories; cross-project memories.
- Memories from Cursor (no transcript parser yet), and a Codex hook trigger (that would need `~/.codex/config.toml` changes).
- Editing the user's CLAUDE.md, AGENTS.md (outside our marker block) or auto-memory files.
- Tombstones for deleted memories (a re-extraction after an offset reset could re-add a deleted memory; archive instead of delete to keep it suppressed).
- Cost accounting in money; only token counts are shown.
