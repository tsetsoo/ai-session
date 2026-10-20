#!/usr/bin/env bash
# Install the todo-conversation helpers on a computer that hosts Claude sessions.
#
#   ~/.ai-remote/bin/ai-todo-open    started by the iPhone / Mac app over SSH
#   ~/.ai-remote/bin/ai-todo-hook    Claude Code hook reporting busy/waiting/idle
#   ~/.ai-remote/bin/ai-todo-sessions  list / delete / prune / stats of Claude and Codex; delete also removes Cursor chats
#   ~/.ai-remote/bin/ai-todo-limits    5h / weekly / monthly usage for the chat's tool on this computer
#   ~/.ai-remote/bin/ai-todo-codex-notify  Codex `notify` program reporting idle
#   ~/.ai-remote/bin/ai-todo-memory  memory extraction, stats push and digests (+ ai_todo_redact.py)
#   ~/.ai-remote/memory-state/       ai-todo-memory's offsets, caches and log (mode 700)
#   ~/.ai-remote/todo-hub.conf       todo-server URL, API token, computer id (mode 600)
#   ~/.ai-remote/tmux.conf           tmux settings, sourced from ~/.tmux.conf
#   ~/.claude/settings.json          hooks merged in; other settings untouched
#   ~/.codex/config.toml             `notify` added only if none is set (see below)
#   ~/Library/LaunchAgents/com.ai-remote.todo-memory.plist  `ai-todo-memory nightly` at 03:30 (macOS)
#
# Usage:
#   install.sh [--hub-url URL] [--token TOKEN] [--computer-id ID] [--chain-codex-notify]
#              [--no-nightly] [--dry-run]
#   install.sh --uninstall [--remove-digests] [--dry-run]
#
# Codex allows a single `notify` program. If one is already configured, install.sh leaves it
# alone and says so; --chain-codex-notify instead wraps it so both run (the original line is
# saved and put back by --uninstall).
#
# Safe to re-run. settings.json and config.toml are backed up before every change. --uninstall
# removes hook-state/ but keeps todo-hub.conf, memory-state/ and the digests written into
# project folders; with --remove-digests it first runs `ai-todo-memory digest --remove-all`.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
AI_DIR="${HOME}/.ai-remote"
BIN_DIR="${AI_DIR}/bin"
HUB_CONF="${AI_DIR}/todo-hub.conf"
TMUX_SNIPPET="${AI_DIR}/tmux.conf"
TMUX_CONF="${HOME}/.tmux.conf"
SETTINGS="${HOME}/.claude/settings.json"
SOURCE_LINE='source-file -q ~/.ai-remote/tmux.conf'
HOOK_MARKER='/.ai-remote/bin/ai-todo-hook'
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CODEX_CONFIG="${CODEX_DIR}/config.toml"
CODEX_NOTIFY_SAVED="${AI_DIR}/codex-notify-original"
STATE_DIR="${AI_DIR}/memory-state"
LAUNCH_LABEL='com.ai-remote.todo-memory'
PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"

hub_url=""
token=""
computer_id=""
dry_run=0
uninstall=0
chain_codex=0
no_nightly=0
remove_digests=0

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
    --remove-digests) remove_digests=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 64 ;;
  esac
done

for value in "$hub_url" "$token" "$computer_id"; do
  if [[ "$value" == *"'"* ]]; then
    echo "hub URL, token and computer id must not contain single quotes" >&2
    exit 64
  fi
done

say() { echo "$*"; }
run() {
  if [[ $dry_run -eq 1 ]]; then
    say "would run: $*"
  else
    "$@"
  fi
}

# Merge (or remove) our hooks in settings.json. Prints what changed.
# Exit 2 = settings.json is not valid JSON (left untouched).
merge_settings() {
  local mode="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found: add these hooks to ${SETTINGS} by hand:" >&2
    echo "  UserPromptSubmit -> ${BIN_DIR}/ai-todo-hook busy" >&2
    echo "  Notification     -> ${BIN_DIR}/ai-todo-hook waiting" >&2
    echo "  Stop             -> ${BIN_DIR}/ai-todo-hook idle" >&2
    echo "  PostToolUse      -> ${BIN_DIR}/ai-todo-hook tool" >&2
    return 1
  fi
  python3 - "$mode" "$SETTINGS" "$BIN_DIR" "$HOOK_MARKER" "$dry_run" <<'PY'
import json, os, shutil, sys, time

mode, path, bin_dir, marker, dry_run = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
ours = {"UserPromptSubmit": "busy", "Notification": "waiting", "Stop": "idle", "PostToolUse": "tool"}

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

def is_ours(h):
    return isinstance(h, dict) and marker in str(h.get("command", ""))

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
            {"hooks": [{"type": "command", "command": f"{bin_dir}/ai-todo-hook {status}"}]}
        )
    # Claude skips AGENTS.md when a CLAUDE.md is present unless this is set. Other keys stay.
    data["projectInstructions"] = "claude-md-and-agents-md"
elif data.get("projectInstructions") == "claude-md-and-agents-md":
    del data["projectInstructions"]
if not hooks:
    del data["hooks"]

if json.dumps(data, sort_keys=True) == before:
    print("settings.json: already up to date")
    sys.exit(0)
if dry_run:
    print(f"would update {path} ({mode} hooks)")
    sys.exit(0)

os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"settings.json: backed up to {backup}")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(f"settings.json: {mode}ed todo hooks")
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

do_install() {
  run mkdir -p "$BIN_DIR"
  run install -m 755 "${SRC_DIR}/ai-todo-open" "${BIN_DIR}/ai-todo-open"
  run install -m 755 "${SRC_DIR}/ai-todo-hook" "${BIN_DIR}/ai-todo-hook"
  run install -m 755 "${SRC_DIR}/ai-todo-sessions" "${BIN_DIR}/ai-todo-sessions"
  run install -m 755 "${SRC_DIR}/ai-todo-limits" "${BIN_DIR}/ai-todo-limits"
  run install -m 755 "${SRC_DIR}/ai-todo-codex-notify" "${BIN_DIR}/ai-todo-codex-notify"
  run install -m 755 "${SRC_DIR}/ai-todo-memory" "${BIN_DIR}/ai-todo-memory"
  run install -m 644 "${SRC_DIR}/ai_todo_redact.py" "${BIN_DIR}/ai_todo_redact.py"
  run install -m 644 "${SRC_DIR}/tmux.conf" "$TMUX_SNIPPET"
  say "scripts: installed to ${BIN_DIR}"
  run mkdir -p "$STATE_DIR"
  run chmod 700 "$STATE_DIR"

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
  install_launch_agent

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

  # Put Codex's own notify back before its program disappears.
  merge_codex_notify uninstall

  run rm -f "${BIN_DIR}/ai-todo-open" "${BIN_DIR}/ai-todo-hook" "${BIN_DIR}/ai-todo-sessions" \
    "${BIN_DIR}/ai-todo-limits" "${BIN_DIR}/ai-todo-codex-notify" "${BIN_DIR}/ai-todo-memory" \
    "${BIN_DIR}/ai_todo_redact.py" "$TMUX_SNIPPET"
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
  if [[ $remove_digests -eq 0 ]]; then
    say "kept project digests; install.sh --uninstall --remove-digests removes them"
  fi
}

# Refuse before touching anything if settings.json can't be merged safely.
if command -v python3 >/dev/null 2>&1; then
  merge_settings check
fi

if [[ $uninstall -eq 1 ]]; then
  do_uninstall
else
  do_install
fi
