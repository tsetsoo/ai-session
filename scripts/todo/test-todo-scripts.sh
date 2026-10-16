#!/usr/bin/env bash
# Offline tests for scripts/todo: ai-todo-open, ai-todo-hook, tmux.conf, install.sh.
# Fully sandboxed: temp HOME, fake claude, fake todo-server, private tmux socket.
# Never touches the real ~/.claude, ~/.tmux.conf, ~/.ai-remote or tmux server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="$(mktemp -d)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
mkdir -p "$HOME"
SOCK="aitodo-test-$$"
export AI_TODO_TMUX_SOCKET="$SOCK"
HUB_PID=""

cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  if [[ -n "$HUB_PID" ]]; then
    kill "$HUB_PID" >/dev/null 2>&1 || true
    wait "$HUB_PID" 2>/dev/null || true
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

passes=0
pass() { echo "PASS: $*"; passes=$((passes + 1)); }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake claude: records its cwd and arguments, then stays alive like a real session.
FAKE_CLAUDE="${SANDBOX}/bin/claude"
CLAUDE_LOG="${SANDBOX}/claude.log"
mkdir -p "${SANDBOX}/bin"
cat >"$FAKE_CLAUDE" <<EOF
#!/bin/sh
echo "\$(pwd -P) \$*" >>"$CLAUDE_LOG"
exec sleep 300
EOF
chmod +x "$FAKE_CLAUDE"
export AI_TODO_CLAUDE_BIN="$FAKE_CLAUDE"

OPEN="${SCRIPT_DIR}/ai-todo-open"
HOOK="${SCRIPT_DIR}/ai-todo-hook"
SID="9b2f6c3e-1d4a-4e7b-8c55-2f0e8a1b7d90"
NAME="ai/claude/todo-0f3a9c21"
mkdir -p "${HOME}/programming"

wait_for_log_lines() {
  for _ in $(seq 1 50); do
    [[ -f "$CLAUDE_LOG" && $(wc -l <"$CLAUDE_LOG") -ge $1 ]] && return 0
    sleep 0.1
  done
  fail "fake claude did not start (expected $1 log lines)"
}

# --- ai-todo-open -----------------------------------------------------------

for args in "ai/claude/other x $SID" "ai/claude/todo-Bad ~ $SID" "$NAME ~ not-a-uuid" "$NAME ~"; do
  # shellcheck disable=SC2086
  if AI_TODO_OPEN_DETACH=1 "$OPEN" $args >/dev/null 2>&1; then
    fail "ai-todo-open accepted bad arguments: $args"
  fi
done
pass "ai-todo-open rejects bad tmux names, session ids and argument counts"

out="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$SID")"
[[ "$out" == created ]] || fail "first open printed '$out', expected created"
tmux -L "$SOCK" has-session -t "=$NAME" || fail "tmux session $NAME was not created"
wait_for_log_lines 1
[[ "$(tail -n 1 "$CLAUDE_LOG")" == "${HOME}/programming --session-id ${SID}" ]] \
  || fail "unexpected claude start: $(tail -n 1 "$CLAUDE_LOG")"
pass "first open creates the tmux session in the expanded ~ cwd with --session-id"

out="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$SID")"
[[ "$out" == attach ]] || fail "second open printed '$out', expected attach"
sleep 0.3
[[ $(wc -l <"$CLAUDE_LOG") -eq 1 ]] || fail "second open started claude again"
pass "second open attaches to the running session without starting claude again"

tmux -L "$SOCK" kill-session -t "=$NAME"
mkdir -p "${HOME}/.claude/projects/-home-programming"
touch "${HOME}/.claude/projects/-home-programming/${SID}.jsonl"
out="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$SID")"
[[ "$out" == resumed ]] || fail "open after restart printed '$out', expected resumed"
wait_for_log_lines 2
[[ "$(tail -n 1 "$CLAUDE_LOG")" == "${HOME}/programming --resume ${SID}" ]] \
  || fail "unexpected claude resume: $(tail -n 1 "$CLAUDE_LOG")"
pass "open after the session died resumes the conversation with --resume"

if AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/claude/todo-missing" '~/nope' "$SID" >/dev/null 2>&1; then
  fail "open accepted a missing cwd"
else
  [[ $? -eq 93 ]] || fail "missing cwd should exit 93"
fi
pass "open exits 93 when the cwd does not exist"

# --- ai-todo-hook -------------------------------------------------------------

HUB_LOG="${SANDBOX}/hub.log"
HUB_PORT_FILE="${SANDBOX}/hub.port"
python3 - "$HUB_LOG" "$HUB_PORT_FILE" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

log_path, port_path = sys.argv[1], sys.argv[2]

class Hub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(log_path, "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "type": self.headers.get("Content-Type"),
                "body": json.loads(body),
            }) + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), Hub)
with open(port_path, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
HUB_PID=$!
for _ in $(seq 1 50); do [[ -s "$HUB_PORT_FILE" ]] && break; sleep 0.1; done
[[ -s "$HUB_PORT_FILE" ]] || fail "fake hub did not start"
HUB_URL="http://127.0.0.1:$(cat "$HUB_PORT_FILE")"

CONF="${SANDBOX}/todo-hub.conf"
printf "TODO_HUB_URL='%s/'\nTODO_API_TOKEN='s3cret'\n" "$HUB_URL" >"$CONF"
export AI_TODO_HUB_CONF="$CONF" AI_TODO_HOOK_SYNC=1

printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your \\"permission\\""}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
python3 - "$HUB_LOG" "$SID" <<'PY' || fail "hook request was wrong: $(cat "$HUB_LOG")"
import json, sys
req = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert req["path"] == "/api/conversations/status", req
assert req["auth"] == "Bearer s3cret", req
assert req["type"] == "application/json", req
assert req["body"] == {"claude_session_id": sys.argv[2], "status": "waiting",
                       "message": 'Claude needs your "permission"'}, req
PY
pass "hook posts status + message with the bearer token"

printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle
[[ $(wc -l <"$HUB_LOG") -eq 2 ]] || fail "idle hook did not post"
python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; assert b=={"claude_session_id":sys.argv[2],"status":"idle"}, b' "$HUB_LOG" "$SID" \
  || fail "idle hook body wrong"
pass "hook posts idle without a message"

printf '{"session_id":"%s"}' "$SID" | AI_TODO_TMUX_SESSION="ai/claude/sigma-revenue" "$HOOK" busy
printf '{"session_id":"%s"}' "$SID" | env -u TMUX "$HOOK" busy
printf 'not json' | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" busy
printf '{"session_id":"%s"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" bogus
[[ $(wc -l <"$HUB_LOG") -eq 2 ]] || fail "hook posted for a non-todo session, bad input or bad status"
pass "hook ignores non-todo sessions, sessions outside tmux, invalid JSON and unknown statuses"

last_status() {
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]["status"])' "$HUB_LOG"
}
printf '{"session_id":"%s","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
[[ $(wc -l <"$HUB_LOG") -eq 3 && "$(last_status)" == idle ]] || fail "idle notification was not reported as idle: $(tail -1 "$HUB_LOG")"
pass "the idle notification is reported as idle, not waiting"

tool() { printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" tool; }
tool
[[ $(wc -l <"$HUB_LOG") -eq 4 && "$(last_status)" == busy ]] || fail "first tool call after idle did not post busy"
tool
tool
[[ $(wc -l <"$HUB_LOG") -eq 4 ]] || fail "repeated tool calls posted busy again"
printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your permission"}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
tool
[[ $(wc -l <"$HUB_LOG") -eq 6 && "$(last_status)" == busy ]] || fail "tool call after a permission prompt did not post busy"
pass "tool calls post busy once after waiting/idle and stay quiet while busy"

printf "TODO_HUB_URL='http://127.0.0.1:9'\nTODO_API_TOKEN='s3cret'\n" >"$CONF"
start=$(date +%s)
printf '{"session_id":"%s"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" busy || fail "hook failed with the hub down"
[[ $(( $(date +%s) - start )) -le 4 ]] || fail "hook took too long with the hub down"
start=$(date +%s)
printf '{"session_id":"%s"}' "$SID" | AI_TODO_HOOK_SYNC= AI_TODO_TMUX_SESSION="$NAME" "$HOOK" busy || fail "background hook failed"
[[ $(( $(date +%s) - start )) -le 1 ]] || fail "background hook blocked"
pass "hook exits 0 quickly when the hub is down, and returns immediately in background mode"
unset AI_TODO_HUB_CONF AI_TODO_HOOK_SYNC
# The hook keeps per-session state under ~/.ai-remote; start the install tests clean.
rm -rf "${HOME}/.ai-remote"

# --- tmux.conf ----------------------------------------------------------------

tmux -L "${SOCK}-conf" -f /dev/null new-session -d -s conftest
if ! tmux -L "${SOCK}-conf" source-file "${SCRIPT_DIR}/tmux.conf" 2>"${SANDBOX}/tmuxconf.err"; then
  tmux -L "${SOCK}-conf" kill-server
  fail "tmux.conf did not load: $(cat "${SANDBOX}/tmuxconf.err")"
fi
[[ "$(tmux -L "${SOCK}-conf" show -sv escape-time)" == 0 ]] || fail "escape-time not applied"
[[ "$(tmux -L "${SOCK}-conf" show -gv mouse)" == on ]] || fail "mouse not applied"
tmux -L "${SOCK}-conf" kill-server
pass "tmux.conf loads cleanly on tmux $(tmux -V | cut -d' ' -f2)"

# --- install.sh -----------------------------------------------------------------

INSTALL="${SCRIPT_DIR}/install.sh"
SETTINGS="${HOME}/.claude/settings.json"
mkdir -p "${HOME}/.claude"
cat >"$SETTINGS" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre"}]}]
  }
}
EOF
printf 'set -g status off\n' >"${HOME}/.tmux.conf"
original_settings="$(cat "$SETTINGS")"

"$INSTALL" --dry-run --hub-url http://hub:8080 --token tok >/dev/null
[[ "$(cat "$SETTINGS")" == "$original_settings" ]] || fail "--dry-run changed settings.json"
[[ ! -e "${HOME}/.ai-remote" ]] || fail "--dry-run created ~/.ai-remote"
[[ "$(cat "${HOME}/.tmux.conf")" == "set -g status off" ]] || fail "--dry-run changed ~/.tmux.conf"
pass "install --dry-run changes nothing"

"$INSTALL" --hub-url http://hub:8080 --token tok >/dev/null
"$INSTALL" >/dev/null
check_installed() {
  python3 - "$SETTINGS" "${HOME}/.ai-remote/bin" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
bin_dir = sys.argv[2]
assert s["model"] == "opus", s
hooks = s["hooks"]
def commands(event):
    return [h["command"] for g in hooks.get(event, []) for h in g["hooks"]]
assert commands("UserPromptSubmit") == [f"{bin_dir}/ai-todo-hook busy"], commands("UserPromptSubmit")
assert commands("Notification") == [f"{bin_dir}/ai-todo-hook waiting"], commands("Notification")
assert commands("Stop") == ["afplay /System/Library/Sounds/Glass.aiff", f"{bin_dir}/ai-todo-hook idle"], commands("Stop")
assert commands("PostToolUse") == [f"{bin_dir}/ai-todo-hook tool"], commands("PostToolUse")
assert commands("PreToolUse") == ["echo pre"], commands("PreToolUse")
assert hooks["PreToolUse"][0]["matcher"] == "Bash"
PY
}
check_installed || fail "settings.json after install is wrong: $(cat "$SETTINGS")"
[[ -x "${HOME}/.ai-remote/bin/ai-todo-open" && -x "${HOME}/.ai-remote/bin/ai-todo-hook" ]] || fail "scripts not installed"
[[ "$(grep -c 'source-file -q ~/.ai-remote/tmux.conf' "${HOME}/.tmux.conf")" -eq 1 ]] || fail "tmux source line not added exactly once"
grep -q 'set -g status off' "${HOME}/.tmux.conf" || fail "existing ~/.tmux.conf content lost"
[[ "$(stat -f '%Lp' "${HOME}/.ai-remote/todo-hub.conf" 2>/dev/null || stat -c '%a' "${HOME}/.ai-remote/todo-hub.conf")" == 600 ]] \
  || fail "todo-hub.conf is not mode 600"
grep -qx "TODO_HUB_URL='http://hub:8080'" "${HOME}/.ai-remote/todo-hub.conf" || fail "hub URL not written"
grep -qx "TODO_API_TOKEN='tok'" "${HOME}/.ai-remote/todo-hub.conf" || fail "token not kept on re-run"
ls "${HOME}/.claude/settings.json.bak-"* >/dev/null 2>&1 || fail "settings.json was not backed up"
pass "install merges hooks once, keeps existing settings and hooks, writes a 600 config, sources tmux.conf once"

"$INSTALL" --token newtok >/dev/null
grep -qx "TODO_HUB_URL='http://hub:8080'" "${HOME}/.ai-remote/todo-hub.conf" || fail "hub URL lost when only --token was given"
grep -qx "TODO_API_TOKEN='newtok'" "${HOME}/.ai-remote/todo-hub.conf" || fail "token not updated"
pass "re-running with --token updates only the token"

cp "$SETTINGS" "${SANDBOX}/settings.good"
printf '{ broken' >"$SETTINGS"
if "$INSTALL" >/dev/null 2>&1; then fail "install accepted an invalid settings.json"; fi
[[ "$(cat "$SETTINGS")" == "{ broken" ]] || fail "install modified an invalid settings.json"
cp "${SANDBOX}/settings.good" "$SETTINGS"
pass "install refuses an invalid settings.json and leaves it alone"

"$INSTALL" --uninstall >/dev/null
python3 - "$SETTINGS" <<'PY' || fail "settings.json after uninstall is wrong: $(cat "$SETTINGS")"
import json, sys
s = json.load(open(sys.argv[1]))
hooks = s["hooks"]
assert "UserPromptSubmit" not in hooks and "Notification" not in hooks, hooks
assert [h["command"] for g in hooks["Stop"] for h in g["hooks"]] == ["afplay /System/Library/Sounds/Glass.aiff"], hooks
assert hooks["PreToolUse"][0]["matcher"] == "Bash"
assert s["model"] == "opus"
PY
[[ ! -e "${HOME}/.ai-remote/bin/ai-todo-open" && ! -e "${HOME}/.ai-remote/tmux.conf" ]] || fail "uninstall left scripts behind"
! grep -q 'ai-remote/tmux.conf' "${HOME}/.tmux.conf" || fail "uninstall left the tmux source line"
grep -q 'set -g status off' "${HOME}/.tmux.conf" || fail "uninstall removed other ~/.tmux.conf lines"
pass "uninstall removes only our hooks, scripts and tmux line"

echo "All ${passes} todo script tests passed."
