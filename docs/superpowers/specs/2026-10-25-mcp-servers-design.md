# MCP servers per conversation — design

Date: 2026-10-25. Status: agreed in conversation with the user, awaiting their review of this
document.

## Intent

On the Spread MacBook Pro (`spreads-macbook-pro`, hub computer
`6becb214-a0f3-447c-9f18-d48aa2ce1805`) every Claude and Codex conversation the app starts
should come up with the Grafana, Slack and Confluence (Atlassian) MCP servers, without the user
doing anything. Today Codex gets them from its global `~/.codex/config.toml`, but Claude has
none of them unless started by hand through `just claude-tsetso` in `~/Spread/Repository`. The
app starts conversations through `ai-todo-open`, which knows nothing about MCP.

The user also wants to choose servers when starting a conversation, have a default per
project, and change a running conversation's servers later.

## Goals

1. Each computer offers a list of MCP servers; the app shows them as a checklist.
2. Starting a Claude or Codex conversation from the app shows that checklist, pre-ticked from
   the project's default, else the computer's default.
3. The conversation's **extra** MCP servers are exactly the ticked ones: claude.ai connectors,
   Claude's `~/.claude.json` / `.mcp.json` servers and Codex's `config.toml` `mcp_servers` are
   off unless ticked. **Plugins keep working, including any MCP servers they bring** (user:
   "we shouldn't make the agents dumb, rather we should select only extra functionalities").
4. The conversation remembers its servers. Every resume through the app uses them.
5. A "Servers…" item in the conversation's ⋯ menu changes them; the conversation restarts
   (tmux session ended, then resumed) with the new set.
6. A default per project (edited in the project editor) and per computer.
7. The Spread Mac's default is Grafana, Slack and Atlassian.

## Non-goals

- Conversations started outside the app (`claude` / `codex` typed in a terminal). Untouched.
- Cursor conversations. No checklist, no change.
- Editing server definitions in the app. They are files on the computer.
- Named profiles (the justfile's base / devops / pm / tsetso…). The user chose individual
  servers.
- Managing secrets. Server files reference environment variables (`${ATLASSIAN_API_TOKEN}`
  etc.) that the computer's shell already provides (`~/.zshenv` on the Spread Mac).

## Anti-goals (would make this a failure even if it works)

- A conversation silently getting servers that weren't ticked, or missing ones that were.
- Starting or resuming a conversation becoming noticeably slower, or failing, because a
  computer has no server list (older scripts, other computers). No list = today's behaviour.
- Secrets passing through the app or the hub. Only server **names** leave the computer.

## Decisions the user made

- **Individual servers**, ticked on and off. No profiles.
- **A list per computer**: `~/.ai-remote/mcp/<name>.json`, one server per file, in Claude's
  `--mcp-config` format (`{"mcpServers": {"<key>": {...}}}`), the format of
  `~/Spread/Repository/.claude/mcp/*.json`. On the Spread Mac the files start out as symlinks
  to that folder's `grafana.json`, `slack.json`, `atlassian.json` (and the others it has), so
  they follow the team's definitions.
- **Strict for extra servers, plugins untouched**: only the ticked servers among configured
  and connector MCP servers, for both tools. Plugin-provided servers (Codex's `code-review`,
  `codex_app`, `cua_repl`; any Claude plugin's) are let through: turning plugins off to remove
  them would also remove their skills and hooks.
- **Only conversations started or resumed from the app.**
- **Changing servers later**: yes, by restarting the conversation.

## How it fits the current system

Today (see `ai-session-remote/scripts/todo/ai-todo-open`, `TmuxCommandBuilder.openTodoConversation`,
`todo-app/crates/todo-server`):

- The app asks the hub to open a todo's conversation (`POST /api/todos/{id}/conversation`),
  gets `tmux_name`, `cwd`, `session_id`, `tool`, and runs
  `ai-todo-open <tmux_name> <cwd> <session_id> [tool]` over SSH as the PTY command. That
  script attaches to a running tmux session or starts / resumes the tool in a new one.
- Projects (`projects` table, `UpdateProjectRequest`), computers (`computers` table,
  `UpdateComputerRequest`) and conversations (`conversations` table) live on the hub.
- Duplicating a conversation into another tool goes through
  `POST /api/todos/{id}/conversations` (`DuplicateConversationRequest`).

### Pieces

**1. Server list on the computer.** `~/.ai-remote/mcp/*.json`. The server's name is the file
name without `.json` (that is what the app shows and the hub stores). Each file holds exactly
one entry under `mcpServers`. `install.sh` creates the folder (mode 700). On the Spread Mac,
the setup step links the Repository files; elsewhere the folder starts empty.

**2. Listing.** A new `ai-todo-sessions mcp list --json` (or a small new helper; builder's
choice) prints `[{"name": "grafana", "kind": "stdio"|"http", "summary": "docker run … mcp/grafana"}]`,
read from the folder. No env values, headers or tokens in the output. A malformed file is
listed with an error flag rather than failing the whole list.

**3. Launching with servers.** `ai-todo-open` gains an optional server selection, e.g.
`--mcp grafana,slack,atlassian` (an empty value = strict with no servers; absent = today's
behaviour, no change). For a new start and for every resume it builds:

- **Claude:** `claude --strict-mcp-config --mcp-config <file>…` with the ticked files, plus
  the existing `--resume <id>` / `--session-id <id>`.
- **Codex:** `codex [-c …] resume <id>` (or a new start) where the overrides
  - add each ticked server, translated from the JSON entry into `mcp_servers.<key>.*` TOML
    values (`command`, `args`, `env`; `url` and headers for HTTP servers), and
  - disable every other MCP server defined in `~/.codex/config.toml` (and any profile it
    uses): each `mcp_servers.<key>` not ticked gets `enabled=false`. Plugin- and app-provided
    servers are left alone.

  Passing these as `-c` arguments keeps `~/.codex/config.toml` untouched.

`ai-todo-open` only attaches when the tmux session is already running, so the selection
applies when the tool process starts. That is why changing servers restarts the conversation.

**Secrets (Claude's call).** Resolved secret values never go on a command line (visible in
`ps` and tmux's pane command). Claude reads `${VAR}` in `--mcp-config` files itself. For Codex,
stdio servers get their variables through `env_vars` (pass-through by name) rather than
values; HTTP servers use `bearer_token_env_var` / `env_http_headers`. A server that can't be
expressed that way is left out for Codex with a warning, not passed with resolved values.

**Missing or broken files (Claude's call).** A ticked name with no file, or a malformed one, at
launch: the tool starts without it and the warning is shown (stderr line the app can show,
not an error exit). Failing to open a conversation over one server is worse than starting it
without that server.

**4. Hub.** New nullable fields, stored as JSON arrays of server names:

- `conversations.mcp_servers`: the conversation's selection. `null` = never chosen.
- `projects.mcp_default`: `null` = inherit the computer's.
- `computers.mcp_default`: `null` = no default (today's behaviour).

`null` and `[]` differ end to end (hub, app, `ai-todo-open`): `null` = not managed, the tool's
own servers as today (no `--mcp`); `[]` = managed, no extra servers (`--mcp ""`).

Exposed in the existing models and update requests. Opening and duplicating a conversation
accept an optional `mcp_servers` and store it. A small endpoint (or the conversation update)
changes a conversation's selection. The hub stores names only; it never validates them
against a computer (it can't see the files).

**5. Choosing the selection.** When the app opens a conversation:

- New conversation (start sheet / first open of a todo): show the checklist, pre-ticked from
  `project.mcp_default ?? computer.mcp_default`. Store the result on the conversation.
  The checklist has a "Tool's own servers" choice (= `null`, not managed), selected when
  neither the project nor the computer has a default (Claude's call). So on computers nobody
  set up nothing changes, and on the Spread Mac the default is ticked. A computer with no
  server list (no folder, or older scripts) shows no checklist at all.
- Existing conversation with `mcp_servers == null` (from before this feature, or imported):
  apply `project.mcp_default ?? computer.mcp_default` the next time the tool **actually
  starts** through the app, and store it then. Attaching to a tmux session that is already
  running applies nothing and stores nothing, or the app would show servers the process
  doesn't have (Claude's call). `ai-todo-open` must therefore tell its caller whether it
  started the tool or attached (it already distinguishes created / resumed / attach for
  tests), e.g. by writing the applied selection to the hub itself, or a status line the app
  reads before the terminal takes over. Builder's choice.
- Existing conversation with a selection: use it.
- Pass the selection to `ai-todo-open`. If the computer's scripts are too old for `--mcp`
  (exit 64), retry without it and keep the conversation usable.

**6. Changing later.** "Servers…" in the conversation ⋯ menu (Mac and iPhone, and the Mac
column toolbar's menu): the checklist with the current selection. Save stores it on the hub,
then, if the tool is running, ends the tmux session (as Close does, asking first while it is
working) and reopens the conversation, which resumes with the new servers.

**7. Defaults UI.** Project editor sheet: a "Default servers" checklist for the project's
computer, plus "Same as computer". Computer settings: a "Default servers" checklist. Both read
the computer's list over SSH; offline or unreachable shows the stored names without editing.

**8. Duplicate.** A duplicate into another tool keeps the source conversation's selection.
(User agreed to this as Claude's guess.) A Claude-to-Claude duplicate forks natively through
`TmuxCommandBuilder.forkDetached` (`claude --resume <id> --fork-session`) without
`ai-todo-open`; it needs the same flags.

**9. Things that read the launch command.** `ai-todo-sessions` (running-conversation
detection, around `running_index`), `ai-todo-hook` / `ai-todo-codex-notify` (finding the todo's
tmux pane by `--resume <id>` / `codex resume <id>` in its arguments) and
`ResumeCommand.string(for:)` (the "Copy Resume Command" text) must keep working with the new
flags in front of or around the id. Copy Resume Command should include the servers, so a
pasted command gives the same conversation.

## Constraints

- Host scripts are POSIX `sh` plus `python3` (existing pattern in `scripts/todo/`), tested
  offline by `scripts/todo/test-todo-scripts.sh` with fakes for `claude` / `codex`.
- Apps: SwiftUI, iOS 17 / macOS 14, shared code in `Sources/AISessionCore`, app in
  `App/AISessionRemote`. Hub: Rust (`todo-app/crates/todo-server`, `todo-shared`), SQLite
  migrations in `db.rs`.
- Pushing hub changes to `main` publishes `pi-latest`, which the Pi downloads; schema changes
  must migrate existing databases.
- Other Claude sessions work in the main checkout at the same time; build in a worktree.
- Tokens stay in the computer's environment. Note that `ai-todo-open` runs
  `tmux new-session … -- env PATH=… <tool>` directly, not through a login shell: the tool gets
  the **tmux server's** environment (whatever shell first started that tmux server), not a
  fresh read of `~/.zshenv`. The builder must make sure the variables the server files
  reference (`GRAFANA_SERVICE_ACCOUNT_TOKEN`, `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN`,
  `SLACK_BOT_TOKEN`, `SLACK_TEAM_ID`, `GITHUB_TOKEN` on the Spread Mac) reach the tool, e.g. by
  sourcing `~/.zshenv` for the launch, and test it with a tmux server started without them.

## Open questions for the builder to settle (and verify on the Spread Mac)

- Whether `claude --strict-mcp-config` drops claude.ai connectors (it must) while keeping
  plugin MCP servers (it should; if it also drops plugin servers, that's acceptable only if
  plugins' skills and hooks still work, otherwise find another way, e.g. disabling the
  connectors and configured servers individually without `--strict-mcp-config`).
- Which Codex servers come from `config.toml` (switch off) versus plugins / the app (leave).
- Claude background jobs resumed with `claude attach` can't take launch flags. Either resume
  those with `claude --resume` when servers are set, or leave them as they are and say so.
- Exact flag spelling and the listing command's home (`ai-todo-sessions` vs a new helper).

## Left to the builder

Layout of the checklist, wording, the endpoint shapes, test structure, and how the Spread Mac's
initial links and computer default get set up (an install flag, a one-off step, or done by
hand and documented).
