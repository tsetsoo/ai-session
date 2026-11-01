# Memory upgrade: fewer, better facts that every tool can find

Date: 2026-11-01. Status: draft for review.

## Why

The goal is to save tokens and time across tools. A fact one tool learned, such as the signing team id, how to deploy over SSH, or "tailscale ping first", should be one cheap lookup away for Claude, Codex, Cursor and anything added later, instead of being rediscovered by reading code or asking the user.

The hub already has a memory system (`ai-todo-memory` plus `/api/memories`). A health check on 2026-11-01 found it runs without errors but does little for this goal:

1. **Too much goes in.** About 125 memories a day, and over 1,000 since 2026-10-26, each extracted by a Sonnet call. "done" and "files_changed" duplicate git.
2. **Almost nothing reads them.** Delivery is a marker block in `AGENTS.md`, written only where that file is untracked. Right now that's one folder (`~/programming`). Every repo with a committed `AGENTS.md`, `ai-session` included, gets nothing.
3. **What is delivered is the wrong part.** The digest takes up to 40 items with open threads first, so in practice it's about 6 KB of mostly stale open threads, loaded into every session in that folder. That costs tokens instead of saving them.
4. **No search.** An agent can't ask the hub a question. (`ai-todo-mcp` manages MCP server configs; it isn't an MCP server itself.)
5. **Coverage gaps.** Codex contributes little (34 of the last 1,000), Cursor nothing. Claude's hand-curated memory files (`~/.claude/projects/*/memory/*.md`), the best facts there are, never reach the hub.
6. **No expiry.** Open threads stay until a later extraction happens to supersede them.

This is an upgrade of the existing system, not a new one. It's the first of several projects; a scheduler and an always-on agent (the "gardener") come later and will build on it.

## Goals

- Every new conversation (Claude and Codex first) starts with a **small memory index** for its project plus general facts, within a fixed budget of about 2 KB (~500 tokens), wherever the repo's `AGENTS.md` is committed.
- Any tool that can run a shell command can **search** memories with one command and get a compact answer.
- **Collect less:** extraction keeps only durable facts (gotchas, decisions) and open threads; no more "done" or "files_changed".
- **Claude's curated memory files are on the hub** and show up for every tool.
- **Memories earn their place:** ranking and pruning follow how often a memory is actually used, so unused facts (open threads included) drop out on their own.
- The user can tell whether it's working: `ai-todo-memory status` reports what was collected, delivered and searched.

## Non-goals

- Full conversation recall ("what did we say last Tuesday"). Transcripts stay on each computer as today.
- Semantic or vector search. Keyword search first. The search sits behind one hub endpoint so a better engine can replace it later without touching any tool.
- The LLM gardener that merges and rewrites memories. That belongs to the always-on agent project.
- Personal-life memories (calendar, people…). The store allows global memories, but nothing collects them yet.
- App changes beyond approving pending memories (section 7). The app already lists memories per project with edit, pin, archive and delete (`Views/Projects/MemoryViews.swift`), and that stays as is.

## Anti-goals (failure even if it technically works)

- The index grows back into a multi-KB wall that every session pays for.
- Session start waits on the network. A slow or down Pi must never delay starting Claude or Codex.
- Memories leak secrets, or end up in committed files of this public repo.
- Writing into files the user owns or commits (tracked `AGENTS.md`, `CLAUDE.md`).
- Breaking the existing extraction, status hooks or digest for a host that hasn't updated yet.

## Constraints

- Hosts: the user's Mac, the Spread Mac and the Codbex Mac all run the helpers (`~/.ai-remote/bin`, installed and updated by `scripts/todo/install.sh`). The hub runs on the Pi.
- Claude runs hooks from `~/.claude/settings.json`. Codex 0.163+ runs hooks from `~/.codex/hooks.json` once trusted. `install.sh` already merges both.
- Conversations started through the app use `--strict-mcp-config` (Claude) or turn off unselected MCP servers (Codex). Anything that depends on an MCP server being present would fail there. This is why search is a shell command and not an MCP server.
- Existing redaction (`ai_todo_redact.py`) applies to everything posted to the hub, including imported Claude memory files.

## Design

### 1. Collect less

- In `ai-todo-memory`'s extraction prompt and schema, drop `done` and `files_changed`. Keep `decision`, `gotcha` and `open_thread`.
- Tighten the prompt toward facts a future conversation would otherwise have to rediscover (commands, locations, ids, causes of failures, constraints, conventions), not narrative about the session.
- The server keeps accepting the old kinds so older hosts don't fail. Existing `done` and `files_changed` memories are archived once (a one-off migration or script), not deleted.

### 2. Global memories

A memory with no `project_id` is global (for example, "Codbex Mac login is tsetso@… with the AI Session key").

- **Global stays on its computer (user's decision).** A global memory belongs to the computer it came from (`computer_id`) and only reaches that computer's index, search and cache. General facts from the personal Mac never show up on the Spread work Mac or the Codbex Mac.
- **Server changes:**
  - `POST /api/memories` and the bulk endpoint accept a memory with neither project nor todo when it has a `computer_id`.
  - List and search take `computer_id` so a host asks for "global memories of this computer".
- **Sources:** extraction keeps assigning the conversation's project. Global memories come from the Claude import (only when no project matches) and from `ai-todo-memory add` (section 7).

The app's memory list is per project, so global memories are invisible there. Showing them in the app is left out for now (see Non-goals), but `ai-todo-memory list --global` must show them.

### 3. Import Claude's curated memory files

- The nightly run reads `~/.claude/projects/<dir>/memory/*.md` (excluding `MEMORY.md`) on each computer. There are about 140 such files today, from about 1 KB to 20 KB each.
- **Project:** the hub project whose folder matches the decoded `<dir>` path, or the nearest one that contains it. This applies to every type, including `user` and `feedback`. Only a file with no matching project is global.
- **Kind mapping:** `feedback` and `user` become `decision`; `project` and `reference` become `gotcha`.
- **Text:** the whole file (description line plus body). The server's 400-character `MAX_TEXT_CHARS` limit is raised to 8,000 for `source = "claude-memory"` only, and longer files are cut. Search matches the full text and prints the description line plus a short excerpt.
- **Not in the index:** imported memories are search-only. Claude already loads these files through its own memory, so putting them in the index would make Claude sessions pay twice, and they would crowd out extracted facts. They are not pinned. The user can pin one in the app to force it into the index.
- These memories are `source = "claude-memory"` (added to the `source` CHECK constraint) and keyed by computer and file path. A changed file updates its memory; a deleted file archives it.
- The import is one-way. The hub never writes back into Claude's memory directory.

### 4. Delivery: a small index at session start

- New command `ai-todo-memory index [--cwd PATH]` prints the index for the project containing `cwd`, plus global memories, within a byte budget (default 2,048).
- **Which memories:** the cwd's project, then its ancestor projects (for example `~/programming` above `ai-session`), then global. Imported Claude memory files are excluded unless pinned (section 3).
- **Order:** by usefulness (section 6). Open threads are never in the index. Search uses the same project set by default. Each line is the memory's text on one line. Lines that don't fit are dropped whole.
- The last line is always the search hint: `More: ai-todo-memory search <words>`.
- **Never wait on the network:**
  - The index is built from a local cache, `~/.ai-remote/memory-state/cache.json`, holding non-archived gotchas and decisions plus pinned memories for this computer's projects and global ones.
  - The cache is refreshed after each extraction run, after the nightly run, and in the background (detached) when a session starts and the cache is older than an hour.
- **Claude:** a `SessionStart` hook prints the index as additional context (Claude's documented hook output for that event).
- **Codex:** if Codex hooks support injecting context at session start, use the same hook. If not, keep today's `AGENTS.md` block for untracked files only, now filled with the index instead of the digest. The builder verifies which applies on the installed Codex version.
- **Cursor:** out of scope for the hook. Cursor can still use search (below). A user-level rule pointing at `ai-todo-memory search` is a cheap optional extra.
- **The old digest is removed:**
  - Once the hook delivers for a tool, the marker blocks the digest wrote are removed (the existing `remove_codex` path), as are the digest files listed in `digests.json`.
  - `AI_TODO_MEMORY_DIGEST` keeps working as the off switch for delivery as a whole.

### 5. Search

- **Hub:** `GET /api/memories?q=<words>` matches words in `text`, ranked, combinable with the existing filters. Implemented with SQLite FTS5 (an external-content index kept in sync on insert, update and delete), with a `LIKE` fallback if FTS5 isn't available in the build.
- **Command:** `ai-todo-memory search <words> [--project auto|ID|all] [--limit N]`.
  - Defaults to the current folder's project plus global memories, limit 8.
  - Prints one line per hit: kind, text and date.
  - Uses the hub when reachable, else the local cache (which then searches only cached memories).
- Each search posts the returned ids as uses (section 6), and logs counts only (no query text) so `status` can report search activity.

### 6. Usefulness: ranking and pruning by use

User's direction: a memory that isn't used should be pruned, and usefulness should drive what agents see.

**What counts as a use:**
1. **Relied on in a conversation (strongest).**
   - The extractor already sends Sonnet the known memories with their ids. Its schema gains `"used": [ids]`: the known memories this excerpt actually relied on, meaning the conversation acted on the fact or it answered a question.
   - The known list is widened to include the memories that were in this session's index. The session-start hook records the ids it printed in `memory-state/sessions/<tool>-<id>.shown`.
2. **Returned by search.** `ai-todo-memory search` reports the ids it printed (ids only, never text).
3. **Touched by the user.** Pinning, editing or approving a memory in the app counts as a use.
4. **Re-extracted.** When the extractor comes up with a fact again and the bulk endpoint matches it as a duplicate, that counts as a use of the matched memory. Seeing the same fact again is a strong sign it matters.

Appearing in the index is **not** a use; otherwise index lines would keep themselves alive.

**Active days, not calendar days (user's decision):**
- An active day is a day with at least one conversation in that project. For a global memory, it is a day with at least one conversation on its computer.
- The hub records active days per project and computer from the per-conversation runs it already receives (extraction and stats).
- Days are local-time days, matching `session_days`.
- A conversation in a child project (`ai-session`) also counts as an active day for its ancestor projects (`~/programming`), since their memories appear in the child's index.
- **Only computers that report uses count.** The hub only counts active days from computers whose helpers report uses (a capability flag sent with each uses or stats post). A computer that updates late doesn't make memories age before it can report any use.
- **The clock starts at rollout.** There is no backfill from `session_days`, and every existing memory starts as if created on the rollout day. Otherwise the first pruning run would archive almost all of the roughly 1,000 existing memories, none of which have a recorded use.
- Projects the user only touches occasionally keep their facts until the user is back.

**Rules:**
- **Grace:** a new memory is never pruned within its first 7 active days.
- **Prune:** after grace, a memory is archived as unused once it has had no use for 14 active days in a row, counting from its last use or, if never used, from creation.
- **Exempt:** pinned and pending memories, and imported Claude memory files while their source file still exists. Claude reads those files directly, so the hub never sees their use, and the user already curates them.
- **Same rule for every kind,** so open threads follow it too. This replaces any fixed expiry.
- **Revival:**
  - Archiving records a reason (`unused` versus `duplicate` or `superseded`, the existing archiving).
  - Search also looks at memories archived as `unused`, ranked below live ones. A hit there restores the memory and counts as a use.
  - Memories archived as duplicates are never revived.
- **Inheritance:** when a memory supersedes another, it inherits the other's use count and last use. A duplicate isn't stored; it counts as a use of the existing memory (signal 4).

**Index ranking** (replaces the order in section 4):
- Pinned first.
- About a quarter of the budget goes to memories still in grace, newest first, so new facts get a chance to be used.
- The rest go by most recent use, then by use count. The nearest project wins ties.

**Server:** usage lives on the hub (summed across computers): `use_count`, `last_used_at`, a per-memory record of uses or enough to compute the 14-active-day window, and the active-day table. A `POST /api/memories/uses` endpoint takes a batch of `{id, signal}` from hosts. Pruning runs on the hub (nightly or on each batch, builder's choice), so it doesn't depend on any one computer being awake.

### 7. Agents save facts on purpose, after the user's OK

User's decision: agents can propose a fact, and it waits for the user's approval.

- **Command:** `ai-todo-memory add "<text>" [--kind gotcha|decision] [--global]`. The default is the current folder's project and kind `gotcha`. The text is redacted, then posted with `source = "agent"` and a new `pending` flag set.
- **Pending memories are invisible:** not in the cache, the index or search. They are still compared for duplicates on approval.
- **The index hint mentions the command:** `Save a fact: ai-todo-memory add "<text>" (the user approves it)`. Agents are told to use it only for facts a future conversation would otherwise rediscover.
- **App (small change):**
  - The project's memory list gets a "Waiting for OK" section at the top, with Approve (clears `pending`) and Reject (deletes).
  - Global pending memories show in the computer's detail view, since the app has no global list.
  - A badge on the Projects tab shows the pending count.
- **Server:** a `pending` column (default 0), a `pending` query filter, and PATCH accepts `pending: false`. Existing list calls without the filter exclude pending memories, so older hosts and app builds never see them as real.

### 8. Knowing it works

`ai-todo-memory status` adds:
- memories posted per day (last 7 days)
- cache age and size
- the index size for the current folder
- the number of searches in the last 7 days
- the last Claude import
- most-used memories, never-used memories, and what was archived as unused in the last 7 days
- whether the session-start hook is installed for Claude and Codex

## Decisions made so far

**The user decided:**
- Upgrade the existing hub memory instead of adopting MemPalace, agentmemory, Hermes or OpenClaw.
- Memory lives on the hub, with repo `AGENTS.md` kept for facts true for anyone working on the repo.
- The memory upgrade comes first, before the scheduler and the always-on agent.
- Global memories stay on the computer they came from.
- Agents can save facts on purpose, but each waits for the user's OK in the app.
- Usefulness drives ranking and pruning, counted in active days per project (7-day grace, archived after 14 active days unused, revived by search).

**My calls** (flag any you disagree with):
- Search is a shell command, not an MCP server.
- Index budget is 2 KB, with full memory text (no generated titles).
- Claude memory files are imported search-only (not pinned, not in the index), and assigned to their project whatever their type. The text limit is raised for them only.
- The index and search include ancestor projects.
- Automatic extraction still posts directly, with no approval. Only `ai-todo-memory add` waits for an OK, since approving about 125 extracted memories a day would be unworkable.
- Signals of use: relied on (from the extractor), search hits, user actions, and being re-extracted as a duplicate. Being shown in the index doesn't count. A quarter of the index is reserved for memories in grace.
- The usefulness clock starts at rollout (no backfill). Only computers that report uses count active days. Ancestor projects count their children's active days. Imported Claude files are exempt from pruning while their file exists.
- Extraction stays on Sonnet.
- App changes limited to approving pending memories.

## Left to the builder

- FTS5 schema and migration details, ranking and tokenisation.
- Storage for uses and active days, and when pruning runs on the hub.
- Cache file format and refresh locking (reuse the existing `lock`).
- How the Codex delivery question resolves (see section 4), and the `install.sh` changes for the new hook.
- Tests, following the existing ones: `scripts/todo/test-todo-scripts.sh` and fixtures for the scripts, `cargo test` for the server.
