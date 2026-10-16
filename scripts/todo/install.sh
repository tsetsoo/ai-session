#!/usr/bin/env bash
# Install the todo-conversation helpers on a computer that hosts Claude sessions.
#
#   ~/.ai-remote/bin/ai-todo-open    started by the iPhone / Mac app over SSH
#   ~/.ai-remote/bin/ai-todo-hook    Claude Code hook reporting busy/waiting/idle
#   ~/.ai-remote/todo-hub.conf       todo-server URL + API token (mode 600)
#   ~/.ai-remote/tmux.conf           tmux settings, sourced from ~/.tmux.conf
#   ~/.claude/settings.json          hooks merged in; other settings untouched
#
# Usage:
#   install.sh [--hub-url URL] [--token TOKEN] [--dry-run]
#   install.sh --uninstall [--dry-run]
#
# Safe to re-run. settings.json is backed up before every change.
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

hub_url=""
token=""
dry_run=0
uninstall=0

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub-url) hub_url="${2:?--hub-url needs a value}"; shift 2 ;;
    --token) token="${2:?--token needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 64 ;;
  esac
done

for value in "$hub_url" "$token"; do
  if [[ "$value" == *"'"* ]]; then
    echo "hub URL and token must not contain single quotes" >&2
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
    return 1
  fi
  python3 - "$mode" "$SETTINGS" "$BIN_DIR" "$HOOK_MARKER" "$dry_run" <<'PY'
import json, os, shutil, sys, time

mode, path, bin_dir, marker, dry_run = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
ours = {"UserPromptSubmit": "busy", "Notification": "waiting", "Stop": "idle"}

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

write_hub_conf() {
  local url="" tok=""
  if [[ -f "$HUB_CONF" ]]; then
    # Keep existing values for anything not passed on the command line.
    url="$(TODO_HUB_URL=; . "$HUB_CONF" >/dev/null 2>&1; printf '%s' "${TODO_HUB_URL:-}")"
    tok="$(TODO_API_TOKEN=; . "$HUB_CONF" >/dev/null 2>&1; printf '%s' "${TODO_API_TOKEN:-}")"
    if [[ -z "$hub_url" && -z "$token" ]]; then
      say "todo-hub.conf: kept"
      return
    fi
  fi
  [[ -n "$hub_url" ]] && url="$hub_url"
  [[ -n "$token" ]] && tok="$token"
  if [[ $dry_run -eq 1 ]]; then
    say "would write ${HUB_CONF}"
    return
  fi
  (
    umask 077
    cat >"$HUB_CONF" <<EOF
# todo-server for ai-todo-hook (shell syntax). Example:
#   TODO_HUB_URL='http://100.118.255.23:8080'
TODO_HUB_URL='${url}'
TODO_API_TOKEN='${tok}'
EOF
  )
  chmod 600 "$HUB_CONF"
  say "todo-hub.conf: written"
}

do_install() {
  run mkdir -p "$BIN_DIR"
  run install -m 755 "${SRC_DIR}/ai-todo-open" "${BIN_DIR}/ai-todo-open"
  run install -m 755 "${SRC_DIR}/ai-todo-hook" "${BIN_DIR}/ai-todo-hook"
  run install -m 644 "${SRC_DIR}/tmux.conf" "$TMUX_SNIPPET"
  say "scripts: installed to ${BIN_DIR}"

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
  run rm -f "${BIN_DIR}/ai-todo-open" "${BIN_DIR}/ai-todo-hook" "$TMUX_SNIPPET"
  say "scripts: removed"

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
