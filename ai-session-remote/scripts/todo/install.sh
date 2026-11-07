#!/usr/bin/env bash
# Install the todo-conversation helpers on a computer that hosts Claude sessions.
#
#   ~/.ai-remote/bin/ai-todo-open    started by the iPhone / Mac app over SSH
#   ~/.ai-remote/bin/ai-todo-review  a conversation's changes for the review view; types review feedback into its tmux pane
#   ~/.ai-remote/bin/ai-todo-hook    Claude Code and Codex hook reporting busy/waiting/idle
#   ~/.ai-remote/bin/ai-todo-sessions  list / delete / prune / stats of Claude and Codex; delete also removes Cursor chats
#   ~/.ai-remote/bin/ai-todo-limits    5h / weekly / monthly usage for the chat's tool on this computer
#   ~/.ai-remote/bin/ai-todo-codex-notify  Codex `notify` program reporting idle
#   ~/.ai-remote/bin/ai-todo-memory  memory extraction, session-start index, search, stats push (+ ai_todo_redact.py)
#   ~/.ai-remote/bin/ai-todo-transcript  one conversation's text, read when duplicating it into another tool
#   ~/.ai-remote/bin/ai-todo-mcp     lists the MCP servers below and builds claude / codex arguments
#   ~/.ai-remote/bin/helpers-version.json  commit, mode and time of this install (ai-todo-status doctor)
#   ~/.ai-remote/mcp/                one <name>.json per MCP server (mode 700); --mcp-link DIR
#                                    symlinks each DIR/*.json that isn't there yet
#   ~/.ai-remote/memory-state/       ai-todo-memory's offsets, caches and log (mode 700)
#   ~/.ai-remote/todo-hub.conf       todo-server URL, API token, computer id (mode 600)
#   ~/.ai-remote/tmux.conf           tmux settings, sourced from ~/.tmux.conf
#   ~/.claude/settings.json          hooks merged in; other settings untouched
#   ~/.codex/config.toml             `notify` added only if none is set (see below)
#                                    and [notice] hide_rate_limit_model_nudge = true (kept on uninstall)
#   ~/.codex/hooks.json              hooks merged in (Codex 0.163+), then trusted through
#                                    `codex app-server`, which writes hooks.state in config.toml
#   ~/Library/LaunchAgents/com.ai-remote.todo-memory.plist  `ai-todo-memory nightly` at 03:30 (macOS)
#   ~/Library/LaunchAgents/com.ai-remote.todo-runner.plist  `ai-todo-runner tick` every 60 s (macOS)
#   ~/.ai-remote/worktrees/          scheduled conversations' git worktrees (mode 700; kept on uninstall)
#   ~/.ai-remote/bin/ai-todo-workspace  lists those worktrees, re-syncs their copied local files
#                                    (+ ai_todo_workspace.py, also used by ai-todo-runner)
#
# Usage:
#   install.sh [--hub-url URL] [--token TOKEN] [--computer-id ID] [--chain-codex-notify]
#              [--no-nightly] [--mcp-link DIR] [--dry-run]
#   install.sh --status-only [--dry-run]  # keep Claude, nightly jobs and hub config as-is
#   install.sh --claude-status-only [--dry-run]  # keep Codex, nightly jobs and hub config as-is
#   install.sh --uninstall [--remove-digests] [--dry-run]
#
# Codex runs hooks only once they are trusted (a hash in config.toml). install.sh trusts its
# own hooks and no others; if that fails (Codex too old, not on PATH), Codex asks in the TUI.
# A running Codex app-server picks new hooks up only when it restarts. Codex's `notify` only
# fires when a turn ends, so the hooks are what report a Codex todo as working.
#
# Codex allows a single `notify` program. If one is already configured, install.sh leaves it
# alone and says so; --chain-codex-notify instead wraps it so both run (the original line is
# saved and put back by --uninstall).
#
# Safe to re-run. settings.json and config.toml are backed up before every change. --uninstall
# removes hook-state/ but keeps todo-hub.conf, memory-state/, mcp/ and the digests written into
# project folders; with --remove-digests it first runs `ai-todo-memory digest --remove-all`.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
AI_DIR="${HOME}/.ai-remote"
BIN_DIR="${AI_DIR}/bin"
HUB_CONF="${AI_DIR}/todo-hub.conf"
TMUX_SNIPPET="${AI_DIR}/tmux.conf"
# Every helper copied to BIN_DIR, for install and uninstall alike. Programs are 755, modules 644.
HELPERS=(ai-todo-open ai-todo-review ai-todo-hook ai-todo-sessions ai-todo-limits ai-todo-codex-notify ai-todo-memory ai-todo-transcript ai-todo-mcp ai-todo-status ai-todo-runner ai-todo-idea ai-todo-watch ai-todo-remind ai-todo-updates ai-todo-workspace)
MODULES=(ai_todo_redact.py ai_todo_resume.py ai_todo_status.py ai_todo_doctor.py ai_todo_launch.py ai_todo_restart.py ai_todo_upgrade.py ai_todo_updates.py ai_todo_workspace.py)
TMUX_CONF="${HOME}/.tmux.conf"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
SETTINGS="${CLAUDE_DIR}/settings.json"
SOURCE_LINE='source-file -q ~/.ai-remote/tmux.conf'
HOOK_MARKER='/.ai-remote/bin/ai-todo-hook'
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CODEX_CONFIG="${CODEX_DIR}/config.toml"
CODEX_HOOKS="${CODEX_DIR}/hooks.json"
# Test hook: the codex binary that trusts the hooks (default: codex on PATH).
CODEX_BIN="${AI_TODO_CODEX_BIN:-codex}"
CODEX_NOTIFY_SAVED="${AI_DIR}/codex-notify-original"
STATE_DIR="${AI_DIR}/memory-state"
MCP_DIR="${AI_DIR}/mcp"
LAUNCH_LABEL='com.ai-remote.todo-memory'
PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
STATUS_LABEL='com.ai-remote.todo-status'
STATUS_PLIST="${HOME}/Library/LaunchAgents/${STATUS_LABEL}.plist"
RUNNER_LABEL='com.ai-remote.todo-runner'
RUNNER_PLIST="${HOME}/Library/LaunchAgents/${RUNNER_LABEL}.plist"
WORKTREES_DIR="${AI_DIR}/worktrees"

hub_url=""
token=""
computer_id=""
dry_run=0
uninstall=0
chain_codex=0
no_nightly=0
status_only=0
claude_status_only=0
remove_digests=0
mcp_link=""

usage() {
  # Print the header comment block (every leading line that starts with '#', minus the shebang).
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-url) hub_url="${2:?--hub-url needs a value}"; shift 2 ;;
    --token) token="${2:?--token needs a value}"; shift 2 ;;
    --chain-codex-notify) chain_codex=1; shift ;;
    --computer-id) computer_id="${2:?--computer-id needs a value}"; shift 2 ;;
    --no-nightly) no_nightly=1; shift ;;
    --status-only) status_only=1; shift ;;
    --claude-status-only) claude_status_only=1; shift ;;
    --mcp-link) mcp_link="${2:?--mcp-link needs a folder}"; shift 2 ;;
    --remove-digests) remove_digests=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 64 ;;
  esac
done

if [[ $claude_status_only -eq 1 && ( $status_only -eq 1 || $uninstall -eq 1 ) ]]; then
  echo '--claude-status-only cannot be combined with --status-only or --uninstall' >&2
  exit 64
fi
if [[ $status_only -eq 1 && $uninstall -eq 1 ]]; then
  echo '--status-only is an install/update option; use --uninstall for a full removal' >&2
  exit 64
fi

for value in "$hub_url" "$token" "$computer_id"; do
  if [[ "$value" == *"'"* ]]; then
    echo "hub URL, token and computer id must not contain single quotes" >&2
    exit 64
  fi
done

if [[ -n "$mcp_link" ]]; then
  if [[ ! -d "$mcp_link" ]]; then
    echo "--mcp-link: ${mcp_link} is not a folder" >&2
    exit 64
  fi
  mcp_link="$(cd "$mcp_link" && pwd)"
fi

say() { echo "$*"; }
run() {
  if [[ $dry_run -eq 1 ]]; then
    say "would run: $*"
  else
    "$@"
  fi
}

# Merge (or remove) our hooks in settings.json, or with kind=codex in ~/.codex/hooks.json
# (same format). Prints what changed. Exit 2 = the file is not valid JSON (left untouched).
merge_settings() {
  local mode="$1" kind="${2:-claude}" path="$SETTINGS"
  [[ "$kind" == codex ]] && path="$CODEX_HOOKS"
  if ! command -v python3 >/dev/null 2>&1; then
    if [[ "$kind" == codex ]]; then
      if [[ "$mode" == uninstall ]]; then
        echo "python3 not found: remove the ${BIN_DIR}/ai-todo-hook --codex hooks from ${path} by hand" >&2
        return 0
      fi
      echo "python3 not found: add these hooks to ${path} by hand:" >&2
      echo "  UserPromptSubmit  -> ${BIN_DIR}/ai-todo-hook --codex busy" >&2
      echo "  PermissionRequest -> ${BIN_DIR}/ai-todo-hook --codex waiting" >&2
      echo "  Stop              -> ${BIN_DIR}/ai-todo-hook --codex idle" >&2
      echo "  PostToolUse       -> ${BIN_DIR}/ai-todo-hook --codex tool" >&2
      return 0
    fi
    echo "python3 not found: add these hooks to ${SETTINGS} by hand:" >&2
    echo "  UserPromptSubmit -> ${BIN_DIR}/ai-todo-hook busy" >&2
    echo "  Notification     -> ${BIN_DIR}/ai-todo-hook waiting" >&2
    echo "  Stop             -> ${BIN_DIR}/ai-todo-hook idle" >&2
    echo "  PostToolUse      -> ${BIN_DIR}/ai-todo-hook tool" >&2
    return 1
  fi
  python3 - "$mode" "$path" "$BIN_DIR" "$HOOK_MARKER" "$dry_run" "$kind" <<'PY'
import json, os, shutil, sys, time

mode, path, bin_dir, marker, dry_run = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
kind = sys.argv[6]
name = os.path.basename(path)
if kind == "codex":
    # Codex has no Notification event; PermissionRequest fires when it asks for approval.
    ours = {"UserPromptSubmit": "busy", "PreToolUse": "tool", "PermissionRequest": "waiting",
            "Stop": "idle", "Interrupt": "idle", "SessionEnd": "idle", "PostToolUse": "tool"}
    prefix = f"{bin_dir}/ai-todo-hook --codex"
else:
    ours = {"UserPromptSubmit": "busy", "Notification": "waiting", "Stop": "idle", "PostToolUse": "tool",
            "PreToolUse": "tool", "PermissionRequest": "waiting", "PostToolUseFailure": "tool",
            "SessionEnd": "idle", "StopFailure": "waiting", "Elicitation": "waiting", "ElicitationResult": "tool",
            "SubagentStart": "busy", "SubagentStop": "busy"}
    prefix = f"{bin_dir}/ai-todo-hook"

data = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    if text.strip():
        try:
            data = json.loads(text)
        except json.JSONDecodeError as e:
            print(f"{path} is not valid JSON ({e}); not changing it", file=sys.stderr)
            sys.exit(2)
if not isinstance(data, dict) or not isinstance(data.get("hooks", {}), dict):
    print(f"{path} has an unexpected shape; not changing it", file=sys.stderr)
    sys.exit(2)

if mode == "check":
    sys.exit(0)

before = json.dumps(data, sort_keys=True)
hooks = data.setdefault("hooks", {})

# The memory index hook (SessionStart) is ours too.
memory_marker = "/.ai-remote/bin/ai-todo-memory session-start"

def is_ours(h):
    command = str(h.get("command", "")) if isinstance(h, dict) else ""
    return marker in command or memory_marker in command

# Drop our entries everywhere first, so re-running never duplicates them.
for event in list(hooks):
    groups = hooks[event]
    if not isinstance(groups, list):
        continue
    kept = []
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            group["hooks"] = [h for h in group["hooks"] if not is_ours(h)]
            if not group["hooks"]:
                continue
        kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

if mode == "install":
    for event, status in ours.items():
        hooks.setdefault(event, []).append(
            {"hooks": [dict({"type": "command", "command": f"{prefix} {status}"},
                            **({"timeout": 3} if kind == "codex" and event in ("Interrupt", "SessionEnd") else {}))]}
        )
    # The session-start memory index: printed from a local cache, never waits on the network.
    start = f"{bin_dir}/ai-todo-memory session-start" + (" --codex" if kind == "codex" else "")
    hooks.setdefault("SessionStart", []).append({"hooks": [{"type": "command", "command": start, "timeout": 5}]})
    # Claude skips AGENTS.md when a CLAUDE.md is present unless this is set. Other keys stay.
    if kind == "claude":
        data["projectInstructions"] = "claude-md-and-agents-md"
elif kind == "claude" and data.get("projectInstructions") == "claude-md-and-agents-md":
    del data["projectInstructions"]
if not hooks:
    del data["hooks"]

if json.dumps(data, sort_keys=True) == before:
    print(f"{name}: already up to date")
    sys.exit(0)
if dry_run:
    print(f"would update {path} ({mode} hooks)")
    sys.exit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"{name}: backed up to {backup}")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(f"{name}: {mode}ed todo hooks")
PY
}

# Our hooks in ~/.codex/hooks.json, trusted on install. Skipped when Codex isn't here, or when
# hooks.json can't be merged safely (Codex status then still comes from notify, idle only).
merge_codex_hooks() {
  local mode="$1"
  if [[ ! -d "$CODEX_DIR" ]] && ! command -v codex >/dev/null 2>&1; then
    [[ "$mode" == install ]] && say "codex: not installed, skipping hooks"
    return 0
  fi
  if ! merge_settings "$mode" codex; then
    # Uninstall goes on to delete ai-todo-hook, so hooks left here would fail on every turn.
    if [[ "$mode" == uninstall ]]; then
      echo "WARNING: our hooks are still in ${CODEX_HOOKS}; remove the ${BIN_DIR}/ai-todo-hook --codex entries by hand" >&2
    fi
    return 0
  fi
  if [[ "$mode" == install && $dry_run -eq 0 ]]; then
    trust_codex_hooks
  fi
}

# Ask `codex app-server` which hooks it sees and record ours as trusted, the way the TUI's
# hook review does (config/batchWrite of hooks.state."<key>".trusted_hash). Never fails.
trust_codex_hooks() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$CODEX_BIN" "$BIN_DIR" "$CODEX_HOOKS" <<'PY' || true
import json, os, signal, subprocess, sys, threading

codex, bin_dir, hooks_path = sys.argv[1:4]
# Exactly the commands merge_settings writes: never vouch for anything else in hooks.json.
expected = {f"{bin_dir}/ai-todo-hook --codex {s}" for s in ("busy", "waiting", "idle", "tool")}
expected.add(f"{bin_dir}/ai-todo-memory session-start --codex")
manual = "codex hooks: not trusted automatically; Codex asks you to review them when it next starts"
try:
    p = subprocess.Popen([codex, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, start_new_session=True)
except OSError:
    print(manual)
    sys.exit(0)
def stop():
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

timer = threading.Timer(30, stop)
timer.start()

def send(msg):
    p.stdin.write(json.dumps(msg) + "\n")
    p.stdin.flush()

def call(rid, method, params):
    send({"id": rid, "method": method, "params": params})
    for line in p.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        # A request from the server can reuse our id; only a response has no method.
        if isinstance(msg, dict) and msg.get("id") == rid and "method" not in msg:
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg.get("result") or {}
    raise RuntimeError(f"{method}: codex app-server exited")

try:
    call(1, "initialize", {"clientInfo": {"name": "ai-remote-install", "version": "1"}})
    send({"method": "initialized"})
    listed = call(2, "hooks/list", {"cwds": [os.path.expanduser("~")]})
    real = os.path.realpath(hooks_path)
    ours = [h for entry in listed.get("data", []) for h in entry.get("hooks", [])
            if h.get("command") in expected
            and os.path.realpath(str(h.get("sourcePath", ""))) == real]
    todo = {h["key"]: {"trusted_hash": h["currentHash"]} for h in ours if h.get("trustStatus") != "trusted"}
    if not ours:
        print(manual)
    elif not todo:
        print("codex hooks: already trusted")
    else:
        call(3, "config/batchWrite", {
            "edits": [{"keyPath": "hooks.state", "value": todo, "mergeStrategy": "upsert"}],
            "filePath": None, "expectedVersion": None, "reloadUserConfig": True,
        })
        print(f"codex hooks: trusted {len(todo)} (a running Codex picks them up when it restarts)")
except Exception as e:
    print(f"{manual} ({e})")
finally:
    timer.cancel()
    stop()
PY
}

# Add (or remove) our `notify` in ~/.codex/config.toml. Never overwrites someone else's
# notify unless --chain-codex-notify asks to wrap it.
merge_codex_notify() {
  local mode="$1"
  if [[ ! -d "$CODEX_DIR" ]] && ! command -v codex >/dev/null 2>&1; then
    [[ "$mode" == install ]] && say "codex: not installed, skipping notify"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found: add to ${CODEX_CONFIG} by hand:" >&2
    echo "  notify = [\"${BIN_DIR}/ai-todo-codex-notify\"]" >&2
    return 0
  fi
  python3 - "$mode" "$CODEX_CONFIG" "${BIN_DIR}/ai-todo-codex-notify" "$CODEX_NOTIFY_SAVED" "$chain_codex" "$dry_run" <<'PY'
import json, os, re, shutil, sys, time

mode, path, prog, saved, chain, dry_run = sys.argv[1:7]
chain, dry_run = chain == "1", dry_run == "1"
marker = "ai-todo-codex-notify"
comment = "# notify: added by ai-session-remote scripts/todo/install.sh\n"

lines = []
if os.path.exists(path):
    with open(path) as f:
        lines = f.read().splitlines(keepends=True)

# `notify` is a top-level key, so it can only appear before the first [table].
idx = None
for i, line in enumerate(lines):
    s = line.strip()
    if s.startswith("["):
        break
    if re.match(r"notify\s*=", s):
        idx = i
        break

def write(new_lines, what):
    if dry_run:
        print(f"would update {path} ({what})")
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(path, backup)
        print(f"config.toml: backed up to {backup}")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("".join(new_lines))
    os.replace(tmp, path)
    print(f"config.toml: {what}")

def instructions(existing):
    print(f"config.toml: notify already set ({existing.strip()}); left unchanged.")
    print("  Codex allows one notify program. To report Codex status as well, re-run with")
    print("  --chain-codex-notify (wraps the existing program so both run), or set by hand:")
    print(f"  notify = {json.dumps([prog, '--chain'])[:-1]}, <existing program and args>]")

if mode == "install":
    if idx is not None and marker in lines[idx]:
        print("config.toml: notify already set up")
        sys.exit(0)
    if idx is None:
        new = [comment, f"notify = {json.dumps([prog])}\n"]
        if lines:
            new.append("\n")
        write(new + lines, "notify added")
        sys.exit(0)
    existing = lines[idx]
    if not chain:
        instructions(existing)
        sys.exit(0)
    m = re.match(r"\s*notify\s*=\s*(\[.*\])\s*(#.*)?$", existing.rstrip("\n"))
    try:
        original = json.loads(m.group(1)) if m else None
    except ValueError:
        original = None
    if not (isinstance(original, list) and original and all(isinstance(a, str) for a in original)):
        print("config.toml: can't parse the existing notify line safely; left unchanged.")
        instructions(existing)
        sys.exit(0)
    if not dry_run:
        os.makedirs(os.path.dirname(saved), exist_ok=True)
        with open(saved, "w") as f:
            f.write(existing if existing.endswith("\n") else existing + "\n")
    lines[idx] = f"notify = {json.dumps([prog, '--chain'] + original)}\n"
    write(lines, "notify chained (original runs too)")
    sys.exit(0)

# uninstall
if idx is None or marker not in lines[idx]:
    print("config.toml: no notify of ours")
    sys.exit(0)
if os.path.exists(saved):
    with open(saved) as f:
        lines[idx] = f.read()
    what = "original notify restored"
else:
    del lines[idx]
    if idx > 0 and lines[idx - 1] == comment:
        del lines[idx - 1]
        if idx - 1 < len(lines) and lines[idx - 1] == "\n":
            del lines[idx - 1]
    what = "notify removed"
write(lines, what)
if not dry_run and os.path.exists(saved):
    os.remove(saved)
PY
}

# Turn off Codex's "Approaching rate limits · Switch to <model>?" card: it is a question, and
# the resume after a limit never answers one, so it would wait behind the card for 12 hours.
# This is the same line Codex writes for "Keep current model (never show again)". Added only
# when the key isn't set at all (an explicit false stays); kept on uninstall, like that choice.
hide_codex_model_nudge() {
  if [[ ! -d "$CODEX_DIR" ]] && ! command -v codex >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found: add to ${CODEX_CONFIG} by hand:" >&2
    echo "  [notice]" >&2
    echo "  hide_rate_limit_model_nudge = true" >&2
    return 0
  fi
  python3 - "$CODEX_CONFIG" "$dry_run" <<'PY'
import os, re, shutil, sys, time

path, dry_run = sys.argv[1], sys.argv[2] == "1"
key = "hide_rate_limit_model_nudge"
text = ""
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
lines = text.splitlines(keepends=True)

if re.search(rf"^\s*(notice\s*\.\s*)?{key}\s*=", text, re.M):
    print("config.toml: rate limit model nudge already set; left unchanged")
    sys.exit(0)
if re.search(r"^\s*notice\s*(=|\.)", text, re.M):
    # notice as an inline table or dotted keys: a [notice] header would be a duplicate.
    print(f"config.toml: notice is set inline; add {key} = true to it by hand")
    sys.exit(0)

line = f"{key} = true\n"
header = next((i for i, l in enumerate(lines) if re.match(r"\s*\[\s*notice\s*\]\s*(#.*)?$", l)), None)
if header is not None:
    lines.insert(header + 1, line)
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines += ["[notice]\n", line]
new = "".join(lines)
try:
    import tomllib
    tomllib.loads(new)
except ImportError:
    pass
except Exception as e:
    print(f"config.toml: not changed, the edit would not parse ({e}); add {key} = true under [notice] by hand")
    sys.exit(0)
if dry_run:
    print(f"would update {path} (rate limit model nudge hidden)")
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"config.toml: backed up to {backup}")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(new)
os.replace(tmp, path)
print("config.toml: rate limit model nudge hidden (it blocks the resume after a limit)")
PY
}

# Set KEY='VALUE' in todo-hub.conf: replaces the KEY line, or appends one. Other lines stay.
set_conf_value() {
  local tmp="${HUB_CONF}.tmp.$$"
  KEY="$1" VALUE="$2" awk '
    BEGIN { k = ENVIRON["KEY"]; line = k "=\047" ENVIRON["VALUE"] "\047"; done = 0 }
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "=" { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$HUB_CONF" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$HUB_CONF"
}

write_hub_conf() {
  if [[ -f "$HUB_CONF" && -z "$hub_url" && -z "$token" && -z "$computer_id" ]]; then
    say "todo-hub.conf: kept"
    return
  fi
  if [[ $dry_run -eq 1 ]]; then
    say "would write ${HUB_CONF}"
    return
  fi
  if [[ ! -f "$HUB_CONF" ]]; then
    (
      umask 077
      cat >"$HUB_CONF" <<'EOF'
# todo-server for ai-todo-hook and ai-todo-memory (shell syntax). Example:
#   TODO_HUB_URL='http://100.118.255.23:8080'
TODO_HUB_URL=''
TODO_API_TOKEN=''
# This computer's id on todo-server (install.sh --computer-id); auto-detected when empty.
TODO_COMPUTER_ID=''
# ai-todo-memory switches and limits (defaults shown):
#   AI_TODO_MEMORY='on'          extract memories with claude -p
#   AI_TODO_STATS='on'           push usage stats, cwd/repo and a redacted title
#   AI_TODO_MEMORY_DIGEST='on'   write project digests (CLAUDE.local.md / AGENTS.md block)
#   AI_TODO_MEMORY_MODEL='sonnet'
#   AI_TODO_MEMORY_DEBOUNCE_MIN='30'
#   AI_TODO_MEMORY_BACKFILL_DAYS='7'
#   AI_TODO_MEMORY_MAX_CHUNKS_NIGHT='40'
#   AI_TODO_MEMORY_MIN_CONFIDENCE='0.5'
EOF
    )
  fi
  [[ -n "$hub_url" ]] && set_conf_value TODO_HUB_URL "$hub_url"
  [[ -n "$token" ]] && set_conf_value TODO_API_TOKEN "$token"
  [[ -n "$computer_id" ]] && set_conf_value TODO_COMPUTER_ID "$computer_id"
  chmod 600 "$HUB_CONF"
  say "todo-hub.conf: written"
}

# Symlink every DIR/*.json into ~/.ai-remote/mcp unless that name is already there.
link_mcp_servers() {
  local src name linked=0
  for src in "${mcp_link}"/*.json; do
    [[ -f "$src" ]] || continue
    name="$(basename "$src")"
    if [[ -e "${MCP_DIR}/${name}" || -L "${MCP_DIR}/${name}" ]]; then
      continue
    fi
    run ln -s "$src" "${MCP_DIR}/${name}"
    linked=$((linked + 1))
  done
  say "mcp: linked ${linked} server file(s) from ${mcp_link}"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# The nightly LaunchAgent (macOS): bootout any loaded copy, write the plist, bootstrap it.
install_launch_agent() {
  if [[ "$(uname -s)" != Darwin ]]; then
    say "nightly job: no launchd here; schedule '${BIN_DIR}/ai-todo-memory nightly' (e.g. cron 30 3 * * *) yourself"
    return
  fi
  if [[ $no_nightly -eq 1 ]]; then
    remove_launch_agent
    say "nightly job: skipped (--no-nightly)"
    return
  fi
  if [[ $dry_run -eq 1 ]]; then
    say "would write ${PLIST} and launchctl bootstrap gui/$(id -u) it"
    return
  fi
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${BIN_DIR}/ai-todo-memory")</string>
    <string>nightly</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${STATE_DIR}/launchd.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${STATE_DIR}/launchd.log")</string>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
    say "nightly job: ${PLIST} loaded (ai-todo-memory nightly at 03:30)"
  else
    say "nightly job: launchctl bootstrap failed; load it with: launchctl bootstrap gui/$(id -u) ${PLIST}"
  fi
}

remove_launch_agent() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  if [[ $dry_run -eq 1 ]]; then
    say "would launchctl bootout gui/$(id -u)/${LAUNCH_LABEL} and remove ${PLIST}"
    return
  fi
  launchctl bootout "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  if [[ -e "$PLIST" ]]; then
    rm -f "$PLIST"
    say "nightly job: removed ${PLIST}"
  fi
}

# Runtime truth and the outbox must survive the terminal closing and a host reboot.
# Kept separate from the optional nightly memory job: --no-nightly does not disable it.
install_status_agent() {
  if [[ "$(uname -s)" != Darwin ]]; then
    say "status monitor: run '${BIN_DIR}/ai-todo-status watch' as a user service on this host"
    return
  fi
  if [[ $dry_run -eq 1 ]]; then
    say "would install ${STATUS_PLIST} (continuous Claude/Codex status and delivery retries)"
    return
  fi
  mkdir -p "${AI_DIR}/status-state" "$(dirname "$STATUS_PLIST")"
  chmod 700 "${AI_DIR}/status-state"
  python3 - "$STATUS_PLIST" "$STATUS_LABEL" "$BIN_DIR" "$AI_DIR" "$CODEX_DIR" "$CLAUDE_DIR" <<'PY'
import plistlib, sys
path, label, bin_dir, ai_dir, codex_dir, claude_dir = sys.argv[1:]
with open(path, "wb") as handle:
    plistlib.dump({"Label": label, "ProgramArguments": [bin_dir + "/ai-todo-status", "watch"],
                   "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 5,
                   "EnvironmentVariables": {"CODEX_HOME": codex_dir, "CLAUDE_CONFIG_DIR": claude_dir},
                   "ProcessType": "Background", "StandardOutPath": ai_dir + "/status-state/service.log",
                   "StandardErrorPath": ai_dir + "/status-state/service.log"}, handle)
PY
  launchctl bootout "gui/$(id -u)/${STATUS_LABEL}" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$STATUS_PLIST"; then
    say "status monitor: loaded (runtime state + durable delivery retries)"
  else
    say "status monitor: launchctl bootstrap failed; run ai-todo-status doctor after loading ${STATUS_PLIST}"
  fi
}

# The scheduler runner: `ai-todo-runner tick` every 60 s (macOS LaunchAgent).
install_runner_agent() {
  if [[ $dry_run -eq 1 ]]; then
    say "would install ${RUNNER_PLIST} (scheduled conversations, every 60 s)"
    return
  fi
  mkdir -p "$WORKTREES_DIR" "${AI_DIR}/runner-state"
  chmod 700 "$WORKTREES_DIR" "${AI_DIR}/runner-state"
  if [[ "$(uname -s)" != Darwin ]]; then
    say "scheduler runner: no launchd here; run '${BIN_DIR}/ai-todo-runner tick' every minute (cron) yourself"
    return
  fi
  mkdir -p "$(dirname "$RUNNER_PLIST")"
  python3 - "$RUNNER_PLIST" "$RUNNER_LABEL" "$BIN_DIR" "$AI_DIR" <<'PY'
import plistlib, sys
path, label, bin_dir, ai_dir = sys.argv[1:]
with open(path, "wb") as handle:
    plistlib.dump({"Label": label, "ProgramArguments": [bin_dir + "/ai-todo-runner", "tick"],
                   "StartInterval": 60, "RunAtLoad": True, "ProcessType": "Background",
                   "StandardOutPath": ai_dir + "/runner-state/launchd.log",
                   "StandardErrorPath": ai_dir + "/runner-state/launchd.log"}, handle)
PY
  launchctl bootout "gui/$(id -u)/${RUNNER_LABEL}" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$RUNNER_PLIST"; then
    say "scheduler runner: loaded (ai-todo-runner tick every 60 s)"
  else
    say "scheduler runner: launchctl bootstrap failed for ${RUNNER_PLIST}"
  fi
}

remove_runner_agent() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  if [[ $dry_run -eq 1 ]]; then
    say "would remove ${RUNNER_PLIST}"
    return
  fi
  launchctl bootout "gui/$(id -u)/${RUNNER_LABEL}" >/dev/null 2>&1 || true
  [[ ! -e "$RUNNER_PLIST" ]] || rm -f "$RUNNER_PLIST"
}

remove_status_agent() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  if [[ $dry_run -eq 1 ]]; then
    say "would remove ${STATUS_PLIST}"
    return
  fi
  launchctl bootout "gui/$(id -u)/${STATUS_LABEL}" >/dev/null 2>&1 || true
  [[ ! -e "$STATUS_PLIST" ]] || rm -f "$STATUS_PLIST"
}

resolve_codex_for_hooks() {
  if [[ $dry_run -eq 0 && -z "${AI_TODO_CODEX_BIN:-}" ]]; then
    # A non-interactive SSH PATH often omits nvm. Probe candidates instead of trusting a
    # stale npm shim, and use the same selected binary to review/trust the installed hooks.
    if resolved_codex=$("${BIN_DIR}/ai-todo-status" codex-path 2>/dev/null); then
      CODEX_BIN="$resolved_codex"
      export PATH="$(dirname "$CODEX_BIN"):$PATH"
    fi
  fi
}

# What was installed, for `ai-todo-status doctor` (the app's Health page): the commit when
# SRC_DIR is a git checkout (dirty when scripts/todo has changes), which install mode, when,
# and the helper files the doctor digests to compare computers. A tarball has no commit.
write_helpers_stamp() {
  local mode="$1" commit="" dirty=""
  if git -C "$SRC_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    commit=$(git -C "$SRC_DIR" rev-parse HEAD)
    if [[ -n "$(git -C "$SRC_DIR" status --porcelain -- . 2>/dev/null)" ]]; then dirty=true; else dirty=false; fi
  fi
  if [[ $dry_run -eq 1 ]]; then
    say "would write ${BIN_DIR}/helpers-version.json (${commit:-no commit}, ${mode})"
    return 0
  fi
  python3 - "${BIN_DIR}/helpers-version.json" "$mode" "$commit" "$dirty" "${HELPERS[@]}" "${MODULES[@]}" <<'PY' \
    || say "helpers: could not write helpers-version.json"
import datetime, json, os, sys
path, mode, commit, dirty, *files = sys.argv[1:]
stamp = {"commit": commit or None, "dirty": {"true": True, "false": False}.get(dirty), "mode": mode,
         "installed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
         "files": sorted(files)}
temporary = path + ".tmp"
with open(temporary, "w") as handle:
    json.dump(stamp, handle, indent=1)
os.replace(temporary, path)
PY
}

do_install_status() {
  run mkdir -p "$BIN_DIR"
  local file
  for file in ai-todo-open ai-todo-hook ai-todo-codex-notify ai-todo-status; do
    run install -m 755 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"
  done
  for file in ai_todo_status.py ai_todo_doctor.py ai_todo_launch.py ai_todo_restart.py ai_todo_upgrade.py ai_todo_resume.py; do run install -m 644 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"; done
  resolve_codex_for_hooks
  merge_codex_notify install
  hide_codex_model_nudge
  merge_codex_hooks install
  install_status_agent
  write_helpers_stamp status-only
  say "Codex status updated; hub config, Claude settings and nightly jobs kept"
}

do_install_claude_status() {
  run mkdir -p "$BIN_DIR"
  local file
  for file in ai-todo-hook ai-todo-status; do
    run install -m 755 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"
  done
  for file in ai_todo_status.py ai_todo_doctor.py ai_todo_launch.py ai_todo_restart.py ai_todo_upgrade.py ai_todo_resume.py; do run install -m 644 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"; done
  merge_settings install
  install_status_agent
  write_helpers_stamp claude-status-only
  say "Claude status updated; Codex settings, hub config and nightly jobs kept"
}

# The Today assistant's folder: a tiny git repo, so each "Add with an agent" conversation runs
# in its own throwaway worktree with the usual auto-approve. Created once; never rewritten.
install_assistant_folder() {
  local dir="${AI_DIR}/assistant"
  # Done once it has a commit (a failed first try can leave an empty repo behind).
  [[ -d "${dir}/.git" ]] && git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1 && return 0
  if [[ $dry_run -eq 1 ]]; then
    say "would create ${dir} (the Today assistant's folder)"
    return 0
  fi
  mkdir -p "$dir"
  local text='You add reminders and people'"'"'s dates for the user with ~/.ai-remote/bin/ai-todo-remind (list, add, person). Do nothing else here.'
  printf '%s\n' "$text" >"${dir}/AGENTS.md"
  printf '%s\n' "$text" >"${dir}/CLAUDE.md"
  [[ -d "${dir}/.git" ]] || git -C "$dir" init -q -b main
  git -C "$dir" add AGENTS.md CLAUDE.md
  # Never signed: a Mac whose git signs every commit may have no gpg (or a locked key).
  git -C "$dir" -c user.name="AI Session" -c user.email="ai-session@localhost" -c commit.gpgsign=false \
    commit -q -m "Today assistant"
  say "assistant: created ${dir}"
}

do_install() {
  run mkdir -p "$BIN_DIR"
  local file
  for file in "${HELPERS[@]}"; do run install -m 755 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"; done
  # Watchers live beside their secrets (watchers/env, written by the user, never by us).
  run mkdir -p "${AI_DIR}/watchers"
  run chmod 700 "${AI_DIR}/watchers"
  # Plugins: ai-session-remote/watchers/<name>/{watcher,watcher.json} in the repo. A helper
  # tarball must carry them: tar -C ai-session-remote -czf - scripts/todo watchers.
  local watchers_src="${SRC_DIR}/../../watchers" dir name
  [[ -d "$watchers_src" ]] || watchers_src="${SRC_DIR}/watchers"
  if compgen -G "${watchers_src}/*/watcher.json" >/dev/null; then
    for dir in "$watchers_src"/*/; do
      [[ -f "${dir}watcher" && -f "${dir}watcher.json" ]] || continue
      name=$(basename "$dir")
      run install -m 755 "${dir}watcher" "${AI_DIR}/watchers/${name}"
      run install -m 644 "${dir}watcher.json" "${AI_DIR}/watchers/${name}.json"
    done
  else
    say "watchers: no watcher plugins found beside scripts/todo; installed watchers kept as they are (copy with: tar -C ai-session-remote -czf - scripts/todo watchers)"
  fi
  # Job plugins: ai-session-remote/jobs/<name>/{job.json,prompt.md}.
  local jobs_src="${SRC_DIR}/../../jobs"
  if compgen -G "${jobs_src}/*/job.json" >/dev/null; then
    # A plugin removed from the repo goes from here too (the folder holds only our files).
    for dir in "${AI_DIR}/jobs"/*/; do
      [[ -d "$dir" ]] || continue
      name=$(basename "$dir")
      if [[ ! -f "${jobs_src}/${name}/job.json" ]]; then run rm -rf "${AI_DIR}/jobs/${name}"; fi
    done
    for dir in "$jobs_src"/*/; do
      [[ -f "${dir}job.json" && -f "${dir}prompt.md" ]] || continue
      name=$(basename "$dir")
      run mkdir -p "${AI_DIR}/jobs/${name}"
      run install -m 644 "${dir}job.json" "${AI_DIR}/jobs/${name}/job.json"
      run install -m 644 "${dir}prompt.md" "${AI_DIR}/jobs/${name}/prompt.md"
    done
  else
    say "jobs: no job plugins found beside scripts/todo; installed ones kept (copy with: tar -czf - scripts/todo watchers jobs)"
  fi
  install_assistant_folder
  for file in "${MODULES[@]}"; do run install -m 644 "${SRC_DIR}/${file}" "${BIN_DIR}/${file}"; done
  resolve_codex_for_hooks
  run install -m 644 "${SRC_DIR}/tmux.conf" "$TMUX_SNIPPET"
  write_helpers_stamp full
  say "scripts: installed to ${BIN_DIR}"
  run mkdir -p "$STATE_DIR"
  run chmod 700 "$STATE_DIR"
  run mkdir -p "$MCP_DIR"
  run chmod 700 "$MCP_DIR"
  if [[ -n "$mcp_link" ]]; then link_mcp_servers; fi

  write_hub_conf

  if [[ -f "$TMUX_CONF" ]] && grep -Fqx "$SOURCE_LINE" "$TMUX_CONF"; then
    say "~/.tmux.conf: already sources ~/.ai-remote/tmux.conf"
  elif [[ $dry_run -eq 1 ]]; then
    say "would append to ${TMUX_CONF}: ${SOURCE_LINE}"
  else
    printf '%s\n' "$SOURCE_LINE" >>"$TMUX_CONF"
    say "~/.tmux.conf: now sources ~/.ai-remote/tmux.conf"
  fi

  merge_settings install
  merge_codex_notify install
  hide_codex_model_nudge
  merge_codex_hooks install
  install_launch_agent
  install_status_agent
  install_runner_agent
  # The session-start hook replaces the AGENTS.md digests: remove the ones written before.
  if [[ $dry_run -eq 0 && -f "${STATE_DIR}/digests.json" ]]; then
    "${BIN_DIR}/ai-todo-memory" digest --remove-all >/dev/null 2>&1 \
      && say "memory: old AGENTS.md digests removed (the session-start hook gives the index now)" \
      || say "memory: removing old digests failed; run ai-todo-memory digest --remove-all"
  fi

  if [[ $dry_run -eq 0 ]]; then
    if tmux info >/dev/null 2>&1; then
      say "tmux is running: apply settings now with: tmux source-file ~/.tmux.conf"
    fi
    if [[ -z "$(TODO_HUB_URL=; . "$HUB_CONF" >/dev/null 2>&1; printf '%s' "${TODO_HUB_URL:-}")" ]]; then
      say "next: set TODO_HUB_URL (and TODO_API_TOKEN) in ${HUB_CONF}, or re-run with --hub-url/--token"
    fi
  fi
}

do_uninstall() {
  if [[ $remove_digests -eq 1 ]]; then
    if [[ -x "${BIN_DIR}/ai-todo-memory" ]]; then
      run "${BIN_DIR}/ai-todo-memory" digest --remove-all || say "digests: ai-todo-memory digest --remove-all failed"
    else
      say "digests: ${BIN_DIR}/ai-todo-memory is not installed; nothing removed"
    fi
  fi
  remove_launch_agent
  remove_status_agent
  remove_runner_agent

  # Put Codex's own notify back before its program disappears.
  merge_codex_notify uninstall
  merge_codex_hooks uninstall

  local file installed=()
  for file in "${HELPERS[@]}" "${MODULES[@]}"; do installed+=("${BIN_DIR}/${file}"); done
  run rm -f "${installed[@]}" "${BIN_DIR}/helpers-version.json" "$TMUX_SNIPPET"
  say "scripts: removed"
  # Per-session state kept by the hooks.
  run rm -rf "${AI_DIR}/hook-state"
  say "state: removed ${AI_DIR}/hook-state"

  if [[ -f "$TMUX_CONF" ]] && grep -Fqx "$SOURCE_LINE" "$TMUX_CONF"; then
    if [[ $dry_run -eq 1 ]]; then
      say "would remove from ${TMUX_CONF}: ${SOURCE_LINE}"
    else
      local tmp="${TMUX_CONF}.tmp.$$"
      grep -Fvx "$SOURCE_LINE" "$TMUX_CONF" >"$tmp" || true
      mv "$tmp" "$TMUX_CONF"
      say "~/.tmux.conf: source line removed"
    fi
  fi

  merge_settings uninstall
  say "kept ${HUB_CONF} (delete it yourself if you no longer need the token)"
  if [[ -d "$STATE_DIR" ]]; then
    say "kept ${STATE_DIR} (memory offsets and log; delete it yourself if you no longer need it)"
  fi
  if [[ -d "$MCP_DIR" ]]; then
    say "kept ${MCP_DIR} (MCP server files; delete it yourself if you no longer need it)"
  fi
  if [[ $remove_digests -eq 0 ]]; then
    say "kept project digests; install.sh --uninstall --remove-digests removes them"
  fi
}

# Refuse before touching anything if settings.json can't be merged safely.
if [[ $status_only -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
  merge_settings check
fi

if [[ $claude_status_only -eq 1 ]]; then
  do_install_claude_status
elif [[ $status_only -eq 1 ]]; then
  do_install_status
elif [[ $uninstall -eq 1 ]]; then
  do_uninstall
else
  do_install
fi
