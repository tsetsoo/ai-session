# MCP servers per conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Conversations the app starts get exactly the MCP servers ticked for them (defaults per project and per computer), changeable later by restarting the conversation.

**Architecture:** Each computer keeps one JSON file per server in `~/.ai-remote/mcp/`. A new host helper `ai-todo-mcp` lists them and turns a selection into launch arguments for Claude (`--strict-mcp-config --mcp-config …`) or Codex (`-c mcp_servers.…`). `ai-todo-open --mcp <names>` uses it when it actually starts the tool and reports the applied selection to the hub. The hub stores names only (conversation selection, project and computer defaults). The apps show a checklist when starting, a "Servers…" menu item, and default editors.

**Tech Stack:** POSIX sh + python3 ≥ 3.9 (host scripts; no `tomllib`), Rust/actix/rusqlite (hub), Swift/SwiftUI iOS 17 / macOS 14 (apps).

**Spec:** `docs/superpowers/specs/2026-10-25-mcp-servers-design.md`

## Global Constraints

- A server's **name** is its file name without `.json` in `~/.ai-remote/mcp/`; each file holds exactly one entry under `"mcpServers"`. Names match `^[A-Za-z0-9._-]{1,64}$`; at most 32 per selection.
- `null` vs `[]` differ everywhere: `null` = not managed (today's behaviour, no `--mcp`), `[]` = managed with no extra servers (`--mcp ''`).
- Strict for extra servers, **plugins untouched**: Claude gets `--strict-mcp-config` (verified on the Spread Mac 2026-10-25: drops connectors, keeps plugins and skills). Codex disables every `[mcp_servers.<key>]` in `~/.codex/config.toml` not selected; plugin/app servers (`code-review`, `codex_app`, `cua_repl`, `node_repl` if not in config.toml) are left alone.
- Resolved secret values never appear in any argv, tmux command, app or hub. Only `${VAR}` references and variable names travel.
- A ticked server whose file is missing or malformed: start without it, print `ai-todo-mcp: skipped <name>: <reason>` on stderr, exit 0.
- Selection applies only when the tool process starts. Attaching to a running tmux session applies and reports nothing.
- Cursor conversations: no checklist, no `--mcp`.
- Hub schema changes migrate existing databases (v6 → v7), with the existing one-backup-per-start rule.
- Build in a worktree; other sessions share `programming/ai-session`.

## Review Focus

1. **Tokens missing from the tmux server's environment** (tmux started before `~/.zshenv` had them, or by launchd): the tool must still get them. → Task 3 test `open_sources_mcp_env_file`.
2. **Computer with older scripts** (`ai-todo-open` rejects `--mcp` with 64): opening must still work, without servers. → Task 6 test `testOldScriptsRetryWithoutServers`.
3. **Re-opening a running conversation after changing the default**: no restart, no hub write. → Task 3 test `open_attach_ignores_mcp`.
4. **A team file renamed or its symlink broken** after it was ticked: the conversation starts, warning shown. → Task 2 test `launch_args_skip_missing_and_malformed`, Task 3 shows the stderr line.
5. **New Codex conversation (`-`)**: the selection is reported only once Codex has assigned the id. → Task 3 test `open_codex_new_reports_after_id`.

---

### Task 1: Hub — store selections and defaults

**Files:**
- Modify: `todo-app/crates/todo-server/src/db.rs` (SCHEMA_VERSION 7, `migrate_v6_to_v7`, `schema_version` detection, fresh-create SQL)
- Modify: `todo-app/crates/todo-shared/src/lib.rs` (fields + requests)
- Modify: `todo-app/crates/todo-server/src/conversations.rs`, `projects.rs`, `main.rs`, `describe.rs`
- Test: in-file `#[cfg(test)]` modules of `db.rs`, `conversations.rs`, `projects.rs`

**Interfaces:**
- Produces (JSON, snake_case):
  - `Conversation.mcp_servers: Option<Vec<String>>`, `Project.mcp_default: Option<Vec<String>>`, `Computer.mcp_default: Option<Vec<String>>` (stored as JSON text columns, NULL = None).
  - `UpdateProjectRequest.mcp_default: Option<Option<Vec<String>>>` and `UpdateComputerRequest.mcp_default` (same, `double_option`: absent = unchanged, `null` = clear).
  - `OpenConversationRequest.mcp_servers: Option<Vec<String>>` — stored only when the call **creates** the conversation row.
  - Duplicate copies the source's `mcp_servers`.
  - `PUT /api/conversations/{id}/mcp` body `{"mcp_servers": [..] | null}` → updated `Conversation`.
  - `POST /api/conversations/mcp` body `{"tool": "claude"|"codex", "session_id": "...", "mcp_servers": [..]}` → 204; 404 when no conversation has that tool+session id (the script's report, like `/api/conversations/status`).
  - Invalid names (pattern / > 32) → 400 `"invalid MCP server name"`. Duplicates are removed keeping first order.

- [ ] **Step 1: Write failing tests**
  - `migrates_v6_to_v7_adds_null_mcp_columns`: a v6 database (copy the v6 fixture pattern used by `migrates_v5_to_v6_allows_a_second_conversation`) migrates; existing rows read back `mcp_servers == None`, `mcp_default == None`; `user_version == 7`.
  - `open_stores_mcp_only_when_creating`: first open with `["grafana","slack"]` stores it; a second open with `["x"]` leaves `["grafana","slack"]`.
  - `duplicate_copies_mcp_servers`.
  - `set_conversation_mcp_null_and_empty_differ`: PUT `[]` reads back `Some([])`; PUT `null` reads back `None`.
  - `report_mcp_by_session`: POST with known tool+session updates; unknown → 404.
  - `rejects_bad_mcp_names`: `["../x"]`, a 65-char name, 33 names → 400.
  - `project_and_computer_mcp_default_update_and_clear`.
- [ ] **Step 2:** `cargo test` in `todo-app/` — the new tests fail (missing fields / routes).
- [ ] **Step 3:** Implement: v7 = `ALTER TABLE … ADD COLUMN` ×3 (additive; still back up first per `migrate`'s rule); `schema_version` returns 7 when `conversations` SQL contains `mcp_servers`; one shared `fn validate_mcp_names(Vec<String>) -> Result<Vec<String>, String>`; routes in `main.rs`; document the new fields and routes in `describe.rs`.
- [ ] **Step 4:** `cargo test` — all pass; `cargo build -p todo-server` clean.
- [ ] **Step 5: Commit** `feat(hub): store MCP server selections and defaults`

### Task 2: Host helper `ai-todo-mcp`

**Files:**
- Create: `ai-session-remote/scripts/todo/ai-todo-mcp` (sh shebang + embedded python, like `ai-todo-sessions`)
- Modify: `ai-session-remote/scripts/todo/install.sh` (add to `HELPERS`; create `~/.ai-remote/mcp` mode 700; new `--mcp-link DIR` symlinks every `DIR/*.json` not already present; uninstall leaves `~/.ai-remote/mcp` and says so)
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (new `# --- ai-todo-mcp` section)

**Interfaces:**
- Produces:
  - `ai-todo-mcp list --json` → `[{"name","kind":"stdio"|"http","summary","error"}]` sorted by name; `summary` is `command` + args joined (≤ 120 chars) or the URL; `error` is null or a short reason. Never prints `env` or `headers` values. Missing folder → `[]`.
  - `ai-todo-mcp launch-args <claude|codex> <comma-separated names>` → one line, shell-quoted words for `eval "set -- $(…)"`. Exit 0 even when names are skipped; skips go to stderr as `ai-todo-mcp: skipped <name>: <reason>`. Bad tool or name → 64.
    - claude: `--strict-mcp-config` then `--mcp-config <abs path>` per valid name (empty selection → `--strict-mcp-config` alone).
    - codex: for each `[mcp_servers.<key>]` header in `$CODEX_HOME/config.toml` (regex on `^\[mcp_servers\.("?)([^".\]]+)\1\]`; python 3.9 has no tomllib) whose key is not selected and isn't `node_repl`, `computer-use` or listed in `~/.ai-remote/mcp/keep` (one per line; blank lines and `#` comments ignored): `-c mcp_servers.<key>.enabled=false`. Each selected server also gets `-c mcp_servers.<key>.enabled=true`. For each selected file entry (key = the entry's key inside the file):
      - stdio: `command="/bin/sh"`, `args=["-c", <script>, "ai-todo-mcp", <command>, <args…>]` where `<script>` = `. "$HOME/.ai-remote/mcp/env" 2>/dev/null; export K="${X}"…; exec "$@"` — one `export` per `env` entry (literal values single-quoted, `${X}` references kept as references). Codex passes only a small default environment to MCP servers, so the wrapper sources the env file itself.
      - http: `url`; an `Authorization: Bearer ${X}` header → `bearer_token_env_var="X"`; any other header whose value is exactly `${X}` → `env_http_headers.<Header>="X"`; anything else → skipped with reason `header can't be passed without its value`.
    - Values are TOML-encoded (`json.dumps(…, ensure_ascii=False)` gives valid TOML basic strings/arrays) inside `-c key=value`.

- [ ] **Step 1: Write failing tests** (fixtures under `$HOME/.ai-remote/mcp/` in the sandbox: copies of the Spread Mac's `grafana.json`, `slack.json`, `atlassian.json`, `github.json` shapes with fake values; a `config.toml` with `[mcp_servers.grafana]`, `[mcp_servers.miro]`, `[mcp_servers."node_repl"]`):
  - `list_json_hides_secrets`: list shows 4 servers with kind/summary; output contains no `${`, no `Bearer`, no fake token text.
  - `launch_args_claude_strict`: `eval "set -- $(ai-todo-mcp launch-args claude grafana,slack)"`; `$@` = `--strict-mcp-config --mcp-config <dir>/grafana.json --mcp-config <dir>/slack.json`; empty selection → `--strict-mcp-config`.
  - `launch_args_codex_disables_unselected_config_servers`: selection `grafana` → contains `-c mcp_servers.miro.enabled=false`, not `node_repl.enabled=false` or `grafana.enabled=false`.
  - `launch_args_codex_stdio_wraps_env`: atlassian → `mcp_servers.mcp-atlassian.command="/bin/sh"`; its args script contains `export CONFLUENCE_USERNAME="${ATLASSIAN_EMAIL}"` and `CONFLUENCE_URL='https://…'`; running that wrapper with a fake command that prints `$CONFLUENCE_USERNAME` and an env file setting `ATLASSIAN_EMAIL=a@b` prints `a@b`.
  - `launch_args_codex_http_bearer`: github → `bearer_token_env_var="GITHUB_TOKEN"`.
  - `launch_args_skip_missing_and_malformed`: names `grafana,gone,broken` (broken = invalid JSON) → exit 0, args only for grafana, stderr has two `skipped` lines.
  - `launch_args_rejects_bad_names`: `../x` → 64.
  - `install_mcp_link`: `install.sh --mcp-link <dir>` creates `~/.ai-remote/mcp/<f>.json` symlinks; re-run doesn't duplicate or replace an existing regular file.
- [ ] **Step 2:** Run `scripts/todo/test-todo-scripts.sh` — new tests fail.
- [ ] **Step 3:** Implement `ai-todo-mcp` and the install changes.
- [ ] **Step 4:** Run the suite — all pass. (When this Mac is loaded, timing tests elsewhere in the suite can fail on unchanged main; run it on spreads-macbook-pro then — see memory `spread-mac-access`.)
- [ ] **Step 5: Commit** `feat(scripts): ai-todo-mcp lists MCP servers and builds launch arguments`

### Task 3: `ai-todo-open --mcp`

**Files:**
- Modify: `ai-session-remote/scripts/todo/ai-todo-open`
- Test: `ai-session-remote/scripts/todo/test-todo-scripts.sh` (ai-todo-open section)

**Interfaces:**
- Consumes: `ai-todo-mcp launch-args` (Task 2); `POST /api/conversations/mcp` (Task 1).
- Produces: `ai-todo-open [--mcp <names>] <tmux_name> <cwd> <session_id> [tool]`. `--mcp` must come first (older scripts reject it with 64, which Task 6 relies on). `--mcp ''` = managed, none.
  - Only when it **creates** the tmux session (new or resumed tool): prepend the launch args to the tool's arguments; if `~/.ai-remote/mcp/env` exists, start the tool as `/bin/sh -c '. "$HOME/.ai-remote/mcp/env"; exec "$@"' sh <tool…>`; then report `{"tool","session_id","mcp_servers":[names that were applied]}` to the hub in the background (3 s limit, never fails the open). For Codex `-`, report after the id appears.
  - Attach to a running session: ignore `--mcp`, no report.
  - Claude background job (`claude attach`): unchanged; ignore `--mcp`, no report.
  - Cursor: `--mcp` ignored.
  - Skipped-server warnings from `ai-todo-mcp` go to the terminal (stderr before tmux attaches) and into the report only as applied names.

- [ ] **Step 1: Write failing tests** (fake claude/codex record argv; fake hub logs posts; `AI_TODO_OPEN_DETACH=1`):
  - `open_claude_with_mcp`: new Claude conversation `--mcp grafana` → claude argv starts with `--strict-mcp-config --mcp-config …/grafana.json` and still has `--session-id <id>`; hub got `{"tool":"claude","session_id":…,"mcp_servers":["grafana"]}`.
  - `open_codex_resume_with_mcp`: argv is `-c … resume <id>` with the id still a separate argument (so `ai-todo-hook`'s ` <id> ` pane match keeps working).
  - `open_codex_new_reports_after_id`.
  - `open_attach_ignores_mcp`: second open of a running session with a different `--mcp` → `attach`, argv file unchanged, no hub post.
  - `open_sources_mcp_env_file`: env file exports `ATLASSIAN_EMAIL=x@y`; tmux server started with that variable unset; the fake tool prints `$ATLASSIAN_EMAIL` → `x@y`.
  - `open_without_mcp_unchanged`: no `--mcp` → argv exactly as today, no post.
  - `open_empty_mcp_is_strict`: `--mcp ''` → claude gets `--strict-mcp-config` and no `--mcp-config`; report has `[]`.
- [ ] **Step 2:** Run the suite — new tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the suite — all pass, including the existing `ai-todo-hook` / `ai-todo-sessions` running-detection tests (they must still find conversations started with the extra flags; add one Claude and one Codex case with `--mcp` to the existing "list detects running conversations" test).
- [ ] **Step 5: Commit** `feat(scripts): ai-todo-open starts conversations with their MCP servers`

### Task 4: Core client — models, requests, commands

**Files:**
- Modify: `ai-session-remote/Sources/AISessionCore/TodoHub/TodoHubModels.swift` (`Conversation.mcpServers: [String]?`), `ProjectModels.swift` (`Project.mcpDefault`, `UpdateProjectRequest.mcpDefault: MCPDefaultChange?`), `TodoHubModels.swift` (`Computer.mcpDefault: [String]?`, new `UpdateComputerRequest`)
- Modify: `Sources/AISessionCore/TodoHub/TodoHubClient.swift`
- Modify: `Sources/AISessionCore/Tmux/TmuxCommandBuilder.swift`, `Sources/AISessionCore/Board/ResumeCommand.swift`
- Create: `Sources/AISessionCore/TodoHub/MCPServers.swift`
- Test: `Tests/AISessionCoreTests/MCPServersTests.swift`, `ConversationLinkingTests.swift`

**Interfaces:**
- Produces:
  - `public struct MCPServer: Codable, Hashable, Sendable, Identifiable { name, kind, summary, error: String? }` + `static func decodeList(_ data: Data) throws -> [MCPServer]`.
  - `public enum MCPDefaultChange: Sendable { case set([String]), clear }` (encodes like `ProjectChange`).
  - `public enum MCPSelection { static func initial(project: Project?, computer: Computer) -> [String]? }` = `project?.mcpDefault ?? computer.mcpDefault`.
  - Client: `openConversation(todoId:tool:mcpServers: [String]?)`, `setConversationServers(id: String, _ names: [String]?) async throws -> Conversation`, `updateComputer(id:_ request: UpdateComputerRequest) async throws -> Computer`.
  - `TmuxCommandBuilder.openTodoConversation(…, mcpServers: [String]? = nil)` puts `--mcp <joined>` first when non-nil and tool ≠ cursor; `listMCPServers() -> String` (`ai-todo-mcp list --json`); `forkDetached(…, mcpServers: [String]?)` evaluates `ai-todo-mcp launch-args claude …` on the host into the arguments.
  - `ResumeCommand.string(for:)`: when `mcpServers != nil` and tool is claude/codex → `cd <cwd> && eval "<tool> $(~/.ai-remote/bin/ai-todo-mcp launch-args <tool> <names>) <resume args>"`.
- [ ] **Step 1: Write failing tests:** decoding `mcp_servers: null` vs `[]` vs missing (missing = nil, older hubs); `UpdateProjectRequest(mcpDefault: .clear)` encodes `"mcp_default":null`; `MCPSelection.initial` prefers the project; command strings for `openTodoConversation` with `nil`, `[]` (`--mcp ''`), `["grafana","slack"]`, and cursor (no flag); `ResumeCommand` with and without servers.
- [ ] **Step 2:** `swift test --filter "MCPServersTests|ConversationLinkingTests"` — fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `swift test` — all pass.
- [ ] **Step 5: Commit** `feat(core): MCP server models, client calls and launch commands`

### Task 5: Store — listing, opening with a selection, changing servers

**Files:**
- Modify: `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift`, `Services/RemoteConversations.swift`
- Test: `App/AISessionRemoteTests/MCPStoreTests.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces (all `@MainActor` on `TodoHubStore`):
  - `func mcpServers(on computer: Computer, config: HostConnectionConfig) async throws -> [MCPServer]` — cached per computer id for the session; 127 (helper missing) → `[]` and remembered as "no list".
  - `func hasMCPList(_ computer: Computer) -> Bool?` (nil = unknown yet).
  - `openConversation(for:tool:config:mcpServers:)` passes the selection to the hub.
  - `func setServers(_ names: [String]?, for conversation: Conversation) async throws`.
  - `func setDefaultServers(_ names: [String]?, for project: Project)` and `…(for computer: Computer)` (throw, like `updateProject`).
  - `duplicateConversation(source:tool:label:)`: the Claude-to-Claude native fork (`TmuxCommandBuilder.forkDetached`, around `TodoHubStore.swift:490`) passes `source.mcpServers`, so the fork starts with the same servers (the hub copies the selection onto the new row in Task 1).
- [ ] **Step 1: Write failing tests** with the existing fake-client pattern in `AppModelTests` (`TodoHubStore(cache:makeClient:)`): open passes `mcp_servers`; `setServers(nil)` sends `null`; listing result 127 yields `[]` and `hasMCPList == false`; a Claude fork's command contains `ai-todo-mcp launch-args claude grafana` when the source has `["grafana"]`.
- [ ] **Step 2:** Run the iOS test scheme on a non-booted simulator (`xcodebuild test -scheme AISessionRemote -destination 'id=<iPhone 17 Pro Max>'`) — fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run — pass.
- [ ] **Step 5: Commit** `feat(app): store reads MCP server lists and saves selections`

### Task 6: Conversation frame — checklist at start, "Servers…", old scripts

**Files:**
- Create: `ai-session-remote/App/AISessionRemote/Views/Frame/MCPServerChecklist.swift` (shared checklist view used by Tasks 6 and 7)
- Modify: `Views/Frame/ConversationFrame.swift` (start state, `attachCommand(for:)`, menu, restart), `Views/Frame/ConversationActions.swift` (`ConversationToolbarCommand.servers`, menu item), `Views/Frame/ConversationLoader.swift` (retry on 64), `Views/Shell/MacShell.swift` (column menu sends `.servers`)
- Test: `App/AISessionRemoteTests/ConversationLoaderTests.swift`

**Interfaces:**
- Consumes: Task 5.
- Produces: `MCPServerChecklist(servers: [MCPServer], selection: Binding<[String]?>, allowsUnmanaged: Bool)` — rows with checkmarks, an error row shown disabled with its reason, and a top "Tool's own servers" row (selection `nil`) when `allowsUnmanaged`.
- Behaviour:
  - Start state (the "Start Conversation" block) shows a "Servers" row for Claude/Codex when the computer has a list: summary of the ticked names, tapping opens the checklist; initial value `MCPSelection.initial`, `allowsUnmanaged = (project default == nil && computer default == nil)`. The selection goes to `openConversation`.
  - `attachCommand(for:)` passes `conversation.mcpServers ?? MCPSelection.initial(...)` — the second only matters when the tool actually starts (the script decides; the hub learns from its report).
  - "Servers…" in the ⋯ menu (disabled offline or for Cursor): checklist with the current selection; Save → `store.setServers`, then if the status is busy ask "Restart <Tool>?" ("Restarting stops it where it is. It resumes with the new servers."), end the tmux session as Close does, and reopen.
  - Loader: when the attach command carried `--mcp` and the session ends with 64 within the first seconds, re-run once without `--mcp` (older scripts) and remember for that computer.
  - Skipped-server stderr lines appear in the terminal as printed; nothing more.
- [ ] **Step 1: Write failing test** `testOldScriptsRetryWithoutServers` in `ConversationLoaderTests`: an `ended(exitStatus: 64)` right after a ready-with-servers phase produces a ready phase whose command has no `--mcp`; a second 64 becomes the usual problem.
- [ ] **Step 2:** Run — fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the iOS tests and build `AISessionRemoteMac` (`CODE_SIGNING_ALLOWED=NO`) — pass / BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `feat(app): pick MCP servers when starting a conversation and change them later`

### Task 7: Defaults — project editor and computers

**Files:**
- Modify: `App/AISessionRemote/Views/Projects/ProjectEditorSheet.swift` (section "Default servers": "Same as computer" + checklist for the project's computer; edit mode only)
- Modify: `App/AISessionRemote/Views/Todos/ComputersView.swift` (row context menu / swipe "Default Servers…" → sheet with the checklist, `allowsUnmanaged: true` meaning "No default")
- Test: `App/AISessionRemoteTests/MCPStoreTests.swift` (encoding of project "Same as computer" → `mcp_default: null`)

**Interfaces:** Consumes `MCPServerChecklist` (Task 6), store methods (Task 5).
- Unreachable computer or no list: show the stored names as plain text, no editing, with "Can't read the servers on <computer>."
- [ ] **Step 1:** Failing test: saving "Same as computer" sends `.clear`; saving two names sends `.set([...])`.
- [ ] **Step 2–4:** Run, implement, run iOS tests + Mac build.
- [ ] **Step 5: Commit** `feat(app): default MCP servers per project and per computer`

### Task 8: Spread Mac setup and end-to-end check

Not code-reviewed like the others; it is the acceptance check.

- [ ] **Step 1:** Land Tasks 1–7 on `main`, push (hub publishes `pi-latest`; wait for the Pi to update, then check `GET /api/todos` returns `mcp_servers` on conversations).
- [ ] **Step 2:** On spreads-macbook-pro: `scripts/todo/install.sh --mcp-link ~/Spread/Repository/.claude/mcp`; write `~/.ai-remote/mcp/env` containing `. "$HOME/.zshenv"`; `ai-todo-mcp list --json` lists the seven servers.
- [ ] **Step 3:** In the app, set the Spread Mac's default servers to `grafana`, `slack`, `atlassian`.
- [ ] **Step 4:** Start a new Claude todo conversation there; in it run `/mcp` → exactly grafana, slack, mcp-atlassian connected, no claude.ai connectors; plugins' skills still listed.
- [ ] **Step 5:** Same for Codex: `/mcp` shows the three plus plugin servers, and `github`, `miro` absent.
- [ ] **Step 6:** "Servers…" → untick Slack → conversation restarts; `/mcp` no longer lists slack; hub conversation shows `["grafana","atlassian"]`.
- [ ] **Step 7:** Rebuild and install the Mac app (`scripts/rebuild-mac-app.sh` from a clean worktree of main) and the iPhone app (see memory `deploy-over-ssh`).
