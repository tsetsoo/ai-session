#!/usr/bin/env bash
# Offline tests for scripts/todo: ai-todo-open, ai-todo-sessions, ai-todo-hook, tmux.conf, install.sh.
# Fully sandboxed: temp HOME, fake claude + codex, fake todo-server, private tmux socket.
# Never touches the real ~/.claude, ~/.tmux.conf, ~/.ai-remote or tmux server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="$(mktemp -d)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="${SANDBOX}/home"
# install.sh honours CODEX_HOME; never let it point at a real Codex config.
unset CODEX_HOME
mkdir -p "$HOME"
SOCK="aitodo-test-$$"
export AI_TODO_TMUX_SOCKET="$SOCK"
HUB_PID=""
EXTRA_PIDS=""

cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  for pid in $HUB_PID $EXTRA_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  done
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

# --- ai-todo-sessions + Codex in ai-todo-open ----------------------------------

SESSIONS="${SCRIPT_DIR}/ai-todo-sessions"
OLD=202001010000   # touch -t timestamp for conversations not used in years
PROJ="${HOME}/.claude/projects/-home-programming"
CODEX_DAY="${HOME}/.codex/sessions/2026/01/02"
mkdir -p "$PROJ" "$CODEX_DAY" "${HOME}/.claude/sessions" "${HOME}/.claude/file-history" "${HOME}/.claude/session-env"

C_NEW=11111111-1111-4111-8111-111111111111     # recent, listed first
C_OLD=22222222-2222-4222-8222-222222222222     # old, unlinked: pruned
C_LINKED=33333333-3333-4333-8333-333333333333  # old, linked to a todo: kept
C_RUN=44444444-4444-4444-8444-444444444444     # old, live per ~/.claude/sessions: kept
C_ARGV=55555555-5555-4555-8555-555555555555    # old, live per `claude --resume <id>` argv: kept
C_STALE=66666666-6666-4666-8666-666666666666   # old, sessions file of a dead pid: pruned
C_EMPTY=77777777-7777-4777-8777-777777777777   # old, no real prompt: unlisted, pruned
C_DEL=88888888-8888-4888-8888-888888888888     # deleted explicitly
X_OLD=019f0000-0000-7000-8000-000000000001     # codex, old: archived by prune
X_LINKED=019f0000-0000-7000-8000-000000000002  # codex, old, linked: kept
X_RUN=019f0000-0000-7000-8000-000000000003     # codex, old, running in tmux: kept
X_SUB=019f0000-0000-7000-8000-000000000004     # codex sub-agent thread: skipped

claude_conv() { # <id> <first prompt> [more prompts...]
  local id=$1 f="${PROJ}/$1.jsonl"; shift
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}\n' "${HOME}/programming" >"$f"
  for p in "$@"; do
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"%s"}}\n' "${HOME}/programming" "$p" >>"$f"
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}\n' "${HOME}/programming" >>"$f"
  done
}
codex_conv() { # <id> <source json> <prompt>
  local f="${CODEX_DAY}/rollout-2026-01-02T10-00-00-$1.jsonl"
  printf '{"timestamp":"t","type":"session_meta","payload":{"id":"%s","cwd":"%s","source":%s}}\n' "$1" "${HOME}/programming" "$2" >"$f"
  printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}\n' >>"$f"
  printf '{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"%s"}]}}\n' "$3" >>"$f"
}

claude_conv "$C_NEW" 'fix   the\nparser' "and add tests"   # \n is a JSON escape: titles collapse whitespace
for id in "$C_OLD" "$C_LINKED" "$C_RUN" "$C_ARGV" "$C_STALE" "$C_DEL"; do claude_conv "$id" "old work $id"; done
printf '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}\n' >"${PROJ}/${C_EMPTY}.jsonl"
mkdir -p "${PROJ}/${C_DEL}/subagents" "${HOME}/.claude/file-history/${C_DEL}" "${HOME}/.claude/session-env/${C_DEL}" "${HOME}/.claude/file-history/${C_OLD}"
touch "${PROJ}/${C_DEL}/subagents/a.jsonl"
codex_conv "$X_OLD" '"cli"' "codex old work"
codex_conv "$X_LINKED" '"cli"' "codex linked work"
codex_conv "$X_RUN" '"cli"' "codex running work"
codex_conv "$X_SUB" '{"subagent":{"parent":"x"}}' "sub-agent prompt"
for f in "$PROJ"/*.jsonl "$CODEX_DAY"/*.jsonl; do
  [[ "$f" == *"$C_NEW"* || "$f" == *"/${SID}.jsonl" ]] || touch -t "$OLD" "$f"
done

# Live processes: a sessions file for C_RUN (alive pid), a dead pid for C_STALE,
# `claude --resume C_ARGV` and `codex resume X_RUN` running inside tmux panes.
sleep 300 &
EXTRA_PIDS="$EXTRA_PIDS $!"
printf '{"pid":%s,"sessionId":"%s"}' "$!" "$C_RUN" >"${HOME}/.claude/sessions/$!.json"
printf '{"pid":999999,"sessionId":"%s"}' "$C_STALE" >"${HOME}/.claude/sessions/999999.json"
mkdir -p "${SANDBOX}/run"
printf '#!/bin/sh\nsleep 300\n' >"${SANDBOX}/run/claude"
printf '#!/bin/sh\nsleep 300\n' >"${SANDBOX}/run/codex"
chmod +x "${SANDBOX}/run/claude" "${SANDBOX}/run/codex"
tmux -L "$SOCK" new-session -d -s argv-claude -- "${SANDBOX}/run/claude" --resume "$C_ARGV"
tmux -L "$SOCK" new-session -d -s argv-codex -- "${SANDBOX}/run/codex" resume "$X_RUN"
sleep 0.5

# Fake codex: records archive/delete/resume calls; resume stays alive like a real session.
FAKE_CODEX="${SANDBOX}/bin/codex"
CODEX_LOG="${SANDBOX}/codex.log"
cat >"$FAKE_CODEX" <<EOF
#!/bin/sh
echo "\$(pwd -P) \$*" >>"$CODEX_LOG"
[ "\$1" = resume ] && exec sleep 300
exit 0
EOF
chmod +x "$FAKE_CODEX"
export AI_TODO_CODEX_BIN="$FAKE_CODEX"

"$SESSIONS" list --json >"${SANDBOX}/list.json"
python3 - "${SANDBOX}/list.json" <<PY || fail "list --json output wrong: $(cat "${SANDBOX}/list.json")"
import json, re, sys
rows = json.load(open(sys.argv[1]))
ids = [r["session_id"] for r in rows]
assert all(set(r) == {"tool","session_id","cwd","title","updated_at","prompts","running","tmux_session"} for r in rows), rows[0]
assert ids[0] == "$C_NEW", ids
assert "$C_EMPTY" not in ids and "$SID" not in ids, "conversations without a real prompt must be skipped"
assert "$X_SUB" not in ids, "codex sub-agent threads must be skipped"
assert {"$X_OLD", "$X_LINKED", "$X_RUN", "$C_OLD"} <= set(ids), ids
new = rows[0]
assert new["tool"] == "claude" and new["cwd"] == "~/programming", new
assert new["title"] == "fix the parser" and new["prompts"] == 2, new
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", new["updated_at"]), new
times = [r["updated_at"] for r in rows]
assert times == sorted(times, reverse=True), times
by = {r["session_id"]: r for r in rows}
assert by["$X_OLD"]["tool"] == "codex" and by["$X_OLD"]["title"] == "codex old work", by["$X_OLD"]
assert by["$C_RUN"]["running"] and by["$C_RUN"]["tmux_session"] is None, by["$C_RUN"]
assert by["$C_ARGV"]["running"] and by["$C_ARGV"]["tmux_session"] == "argv-claude", by["$C_ARGV"]
assert by["$X_RUN"]["running"] and by["$X_RUN"]["tmux_session"] == "argv-codex", by["$X_RUN"]
assert not by["$C_STALE"]["running"] and not by["$C_OLD"]["running"], "dead or absent processes are not running"
PY
[[ "$("$SESSIONS" list --json --tool codex --limit 2 | python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r), {x["tool"] for x in r})')" == "2 {'codex'}" ]] \
  || fail "list --tool/--limit not applied"
pass "list --json: fields, newest first, skips empty and sub-agent conversations, --tool/--limit"
pass "list detects running conversations (sessions file, claude/codex argv) and their tmux session"

if "$SESSIONS" delete claude "$C_RUN" >/dev/null 2>&1; then fail "delete removed a running conversation"; else [[ $? -eq 65 ]] || fail "delete of a running conversation should exit 65"; fi
[[ -f "${PROJ}/${C_RUN}.jsonl" ]] || fail "running conversation's transcript was removed"
if "$SESSIONS" delete codex "$X_RUN" >/dev/null 2>&1; then fail "delete archived a running codex conversation"; fi
pass "delete refuses running conversations"

"$SESSIONS" delete claude "$C_DEL" >/dev/null
[[ ! -e "${PROJ}/${C_DEL}.jsonl" && ! -e "${PROJ}/${C_DEL}" && ! -e "${HOME}/.claude/file-history/${C_DEL}" && ! -e "${HOME}/.claude/session-env/${C_DEL}" ]] \
  || fail "delete left Claude files behind"
[[ -f "${PROJ}/${C_OLD}.jsonl" && -d "${HOME}/.claude/file-history/${C_OLD}" && -f "${PROJ}/${C_NEW}.jsonl" ]] || fail "delete removed another conversation's files"
if "$SESSIONS" delete claude "$C_DEL" >/dev/null 2>&1; then fail "deleting a missing conversation succeeded"; else [[ $? -eq 66 ]] || fail "missing conversation should exit 66"; fi
if "$SESSIONS" delete claude "../../etc" >/dev/null 2>&1; then fail "delete accepted a path as an id"; fi
pass "delete removes only that Claude conversation's transcript, sub-agent dir, file-history and session-env"

"$SESSIONS" delete codex "$X_OLD" >/dev/null
"$SESSIONS" delete codex "$X_OLD" --permanent >/dev/null
[[ "$(cut -d' ' -f2- "$CODEX_LOG")" == "archive ${X_OLD}"$'\n'"delete ${X_OLD}" ]] || fail "codex delete calls wrong: $(cat "$CODEX_LOG")"
: >"$CODEX_LOG"
pass "codex delete archives by default and deletes with --permanent"

# Fake todo-server listing the linked conversations (one per key name).
LHUB_PORT_FILE="${SANDBOX}/lhub.port"
python3 - "$LHUB_PORT_FILE" "$C_LINKED" "$X_LINKED" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_path, c_linked, x_linked = sys.argv[1:4]
class Hub(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps([{"tool": "claude", "session_id": c_linked},
                           {"tool": "codex", "claude_session_id": x_linked}]).encode()
        self.send_response(200 if self.path == "/api/conversations" else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), Hub)
open(port_path, "w").write(str(server.server_port))
server.serve_forever()
PY
EXTRA_PIDS="$EXTRA_PIDS $!"
for _ in $(seq 1 50); do [[ -s "$LHUB_PORT_FILE" ]] && break; sleep 0.1; done
PRUNE_CONF="${SANDBOX}/prune-hub.conf"
printf "TODO_HUB_URL='http://127.0.0.1:%s'\nTODO_API_TOKEN=''\n" "$(cat "$LHUB_PORT_FILE")" >"$PRUNE_CONF"

AI_TODO_HUB_CONF="$PRUNE_CONF" "$SESSIONS" prune --older-than 30 >"${SANDBOX}/prune.txt"
for id in "$C_OLD" "$C_STALE" "$C_EMPTY" "$X_OLD"; do
  grep -q "would delete .* $id " "${SANDBOX}/prune.txt" || fail "dry run did not list $id: $(cat "${SANDBOX}/prune.txt")"
done
for id in "$C_NEW" "$C_LINKED" "$C_RUN" "$C_ARGV" "$X_LINKED" "$X_RUN" "$X_SUB" "$SID"; do
  ! grep -q "$id" "${SANDBOX}/prune.txt" || fail "dry run listed $id, which must be kept"
done
[[ -f "${PROJ}/${C_OLD}.jsonl" && ! -s "$CODEX_LOG" ]] || fail "dry run deleted something"
pass "prune without --yes only lists old, unlinked, non-running conversations"

AI_TODO_HUB_CONF="$PRUNE_CONF" "$SESSIONS" prune --older-than 30d --yes >/dev/null
[[ ! -e "${PROJ}/${C_OLD}.jsonl" && ! -e "${HOME}/.claude/file-history/${C_OLD}" && ! -e "${PROJ}/${C_STALE}.jsonl" && ! -e "${PROJ}/${C_EMPTY}.jsonl" ]] \
  || fail "prune --yes left old conversations"
for id in "$C_NEW" "$C_LINKED" "$C_RUN" "$C_ARGV"; do [[ -f "${PROJ}/${id}.jsonl" ]] || fail "prune --yes removed $id"; done
[[ "$(cut -d' ' -f2- "$CODEX_LOG")" == "archive ${X_OLD}" ]] || fail "prune --yes codex calls wrong: $(cat "$CODEX_LOG")"
: >"$CODEX_LOG"
pass "prune --yes deletes them (Claude files, Codex archive) and keeps linked, running and recent ones"

printf "TODO_HUB_URL='http://127.0.0.1:9'\n" >"${SANDBOX}/down.conf"
claude_conv "$C_OLD" "back again"
touch -t "$OLD" "${PROJ}/${C_OLD}.jsonl"
if AI_TODO_HUB_CONF="${SANDBOX}/down.conf" "$SESSIONS" prune --older-than 30 --yes >/dev/null 2>&1; then
  fail "prune ran with the hub unreachable"
else
  [[ $? -eq 65 ]] || fail "prune with the hub down should exit 65"
fi
[[ -f "${PROJ}/${C_OLD}.jsonl" ]] || fail "prune deleted with the hub unreachable"
pass "prune refuses (exit 65) when todo-server can't be reached"

XNAME="ai/codex/todo-0f3a9c21"
out="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$XNAME" '~/programming' "$X_LINKED" codex)"
[[ "$out" == resumed ]] || fail "codex open printed '$out', expected resumed"
for _ in $(seq 1 50); do [[ -s "$CODEX_LOG" ]] && break; sleep 0.1; done
[[ "$(cat "$CODEX_LOG")" == "${HOME}/programming resume ${X_LINKED}" ]] || fail "unexpected codex start: $(cat "$CODEX_LOG")"
[[ "$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$XNAME" '~/programming' "$X_LINKED" codex)" == attach ]] || fail "second codex open did not attach"
if AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-nothere" '~/programming' 019f0000-0000-7000-8000-0000000000ff codex >/dev/null 2>&1; then
  fail "codex open accepted an unknown conversation"
else
  [[ $? -eq 94 ]] || fail "unknown codex conversation should exit 94"
fi
if AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$X_LINKED" codex >/dev/null 2>&1; then fail "codex open accepted a claude tmux name"; fi
if AI_TODO_OPEN_DETACH=1 "$OPEN" "$XNAME" '~/programming' "$X_LINKED" cursor >/dev/null 2>&1; then fail "open accepted an unknown tool"; fi
pass "ai-todo-open codex: resumes in tmux, attaches when running, exits 94 for unknown ids, checks tool vs name"

# --- review fixes: open rollouts, fail closed, hub answers, duplicates, kill+wait, ids, PATH ---

# A Codex conversation whose rollout file a process holds open (no id in any argv).
: >"$CODEX_LOG"
X_OPEN=019f0000-0000-7000-8000-000000000005
codex_conv "$X_OPEN" '"cli"' "codex open in the desktop app"
X_OPEN_FILE="$(ls "$CODEX_DAY"/rollout-*-"$X_OPEN".jsonl)"
touch -t "$OLD" "$X_OPEN_FILE"
python3 -c 'import sys, time; f = open(sys.argv[1]); time.sleep(300)' "$X_OPEN_FILE" &
HOLDER=$!
EXTRA_PIDS="$EXTRA_PIDS $HOLDER"
sleep 0.5
"$SESSIONS" list --json --tool codex | python3 -c "import json,sys; r={x['session_id']:x for x in json.load(sys.stdin)}; assert r['$X_OPEN']['running'], r['$X_OPEN']" \
  || fail "a codex conversation with its rollout held open was not marked running"
if "$SESSIONS" delete codex "$X_OPEN" >/dev/null 2>&1; then fail "delete archived a codex conversation whose rollout is open"; else [[ $? -eq 65 ]] || fail "open rollout delete should exit 65"; fi
AI_TODO_HUB_CONF="$PRUNE_CONF" "$SESSIONS" prune --older-than 30 >"${SANDBOX}/prune2.txt"
! grep -q "$X_OPEN" "${SANDBOX}/prune2.txt" || fail "prune listed a codex conversation whose rollout is open"
[[ ! -s "$CODEX_LOG" ]] || fail "codex was called for an open rollout: $(cat "$CODEX_LOG")"
pass "codex conversations with their rollout file held open count as running (delete and prune refuse)"

kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true
if AI_TODO_PS=/nonexistent/ps "$SESSIONS" delete codex "$X_OPEN" >/dev/null 2>&1; then fail "delete ran without ps"; else [[ $? -eq 65 ]] || fail "delete without ps should exit 65"; fi
if AI_TODO_LSOF=/nonexistent/lsof "$SESSIONS" delete codex "$X_OPEN" >/dev/null 2>&1; then fail "delete ran without lsof"; else [[ $? -eq 65 ]] || fail "delete without lsof should exit 65"; fi
if AI_TODO_HUB_CONF="$PRUNE_CONF" AI_TODO_PS=/nonexistent/ps "$SESSIONS" prune --older-than 30 --yes >/dev/null 2>&1; then fail "prune ran without ps"; else [[ $? -eq 65 ]] || fail "prune without ps should exit 65"; fi
if AI_TODO_HUB_CONF="$PRUNE_CONF" AI_TODO_LSOF=/nonexistent/lsof "$SESSIONS" prune --older-than 30 --yes >/dev/null 2>&1; then fail "prune ran without lsof"; else [[ $? -eq 65 ]] || fail "prune without lsof should exit 65"; fi
[[ -f "$X_OPEN_FILE" && ! -s "$CODEX_LOG" ]] || fail "something was deleted while running conversations were unknown"
AI_TODO_PS=/nonexistent/ps "$SESSIONS" list --json >/dev/null 2>&1 || fail "list should still work (unmarked) without ps"
pass "delete and prune fail closed (exit 65) when ps or lsof can't be run; list still works"

# A hub that answers 200 with something other than a list of conversations.
HUB2_BODY="${SANDBOX}/hub2.body"
HUB2_PORT_FILE="${SANDBOX}/hub2.port"
python3 - "$HUB2_PORT_FILE" "$HUB2_BODY" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port_path, body_path = sys.argv[1:3]
class Hub(BaseHTTPRequestHandler):
    def do_GET(self):
        body = open(body_path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), Hub)
open(port_path, "w").write(str(server.server_port))
server.serve_forever()
PY
EXTRA_PIDS="$EXTRA_PIDS $!"
for _ in $(seq 1 50); do [[ -s "$HUB2_PORT_FILE" ]] && break; sleep 0.1; done
HUB2_CONF="${SANDBOX}/hub2.conf"
printf "TODO_HUB_URL='http://127.0.0.1:%s'\n" "$(cat "$HUB2_PORT_FILE")" >"$HUB2_CONF"
for body in '{"conversations": []}' '{"error": "login required"}' '[["not", "an", "object"]]'; do
  printf '%s' "$body" >"$HUB2_BODY"
  if AI_TODO_HUB_CONF="$HUB2_CONF" "$SESSIONS" prune --older-than 30 --yes >/dev/null 2>&1; then
    fail "prune ran when the hub answered $body"
  else
    [[ $? -eq 65 ]] || fail "prune with hub answer $body should exit 65"
  fi
done
[[ -f "$X_OPEN_FILE" && ! -s "$CODEX_LOG" && -f "${PROJ}/${C_OLD}.jsonl" ]] || fail "prune deleted after a bad hub answer"
printf '[{"tool":"codex","session_id":"%s","claude_session_id":null},{"tool":"claude","session_id":null,"claude_session_id":"%s"}]' "$X_OPEN" "$C_OLD" >"$HUB2_BODY"
AI_TODO_HUB_CONF="$HUB2_CONF" "$SESSIONS" prune --older-than 30 >"${SANDBOX}/prune3.txt" || fail "prune with a valid hub list failed"
! grep -q "$X_OPEN" "${SANDBOX}/prune3.txt" || fail "prune listed a codex conversation linked by session_id (claude_session_id null)"
! grep -q "$C_OLD" "${SANDBOX}/prune3.txt" || fail "prune listed a conversation linked by claude_session_id"
pass "prune refuses (exit 65) unless the hub answers a list; accepts session_id or claude_session_id, null-safe"

# The same Claude id in two project folders: one conversation, last used = newest copy.
C_DUP=99999999-9999-4999-8999-999999999999
PROJ_B="${HOME}/.claude/projects/-home-programming-worktree"
mkdir -p "$PROJ_B" "${HOME}/.claude/todos" "${HOME}/.claude/file-history/${C_DUP}"
claude_conv "$C_DUP" "dup old copy"
touch -t "$OLD" "${PROJ}/${C_DUP}.jsonl"
cp "${PROJ}/${C_DUP}.jsonl" "${PROJ_B}/${C_DUP}.jsonl"   # recent copy
printf '{"version":1,"entries":[{"sessionId":"%s","fullPath":"x"},{"sessionId":"%s","fullPath":"y"}],"originalPath":"%s"}' \
  "$C_DUP" "$C_NEW" "${HOME}/programming" >"${PROJ}/sessions-index.json"
touch "${HOME}/.claude/todos/${C_DUP}-agent-${C_DUP}.json" "${HOME}/.claude/todos/${C_NEW}-agent-${C_NEW}.json"
"$SESSIONS" list --json --tool claude | python3 -c "
import json, sys
rows = [r for r in json.load(sys.stdin) if r['session_id'] == '$C_DUP']
assert len(rows) == 1, rows
assert not rows[0]['updated_at'].startswith('2020'), rows[0]
" || fail "a Claude id in two project folders should list once, with the newest copy's time"
AI_TODO_HUB_CONF="$PRUNE_CONF" "$SESSIONS" prune --older-than 30 >"${SANDBOX}/prune4.txt"
! grep -q "$C_DUP" "${SANDBOX}/prune4.txt" || fail "prune listed a conversation whose newest copy is recent"
"$SESSIONS" delete claude "$C_DUP" >/dev/null || fail "deleting the duplicated conversation failed"
[[ ! -e "${PROJ}/${C_DUP}.jsonl" && ! -e "${PROJ_B}/${C_DUP}.jsonl" && ! -e "${HOME}/.claude/file-history/${C_DUP}" ]] \
  || fail "delete left a copy of the duplicated conversation"
[[ ! -e "${HOME}/.claude/todos/${C_DUP}-agent-${C_DUP}.json" && -e "${HOME}/.claude/todos/${C_NEW}-agent-${C_NEW}.json" ]] \
  || fail "delete removed the wrong todos files"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
ids = [e['sessionId'] for e in d['entries']]
assert ids == ['$C_NEW'], ids
assert d['version'] == 1 and d['originalPath'], d
" "${PROJ}/sessions-index.json" || fail "sessions-index.json not updated correctly: $(cat "${PROJ}/sessions-index.json")"
pass "a Claude id in several project folders is one conversation; delete removes every copy, its index entries and todos files"

# delete --kill-tmux: ends the todo's tmux session, waits for the process to exit, deletes.
C_KILL=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
KNAME="ai/claude/todo-aaaaaaaa"
claude_conv "$C_KILL" "kill me"
tmux -L "$SOCK" new-session -d -s "$KNAME" -- "${SANDBOX}/run/claude" --resume "$C_KILL"
sleep 0.5
out="$("$SESSIONS" delete claude "$C_KILL" --kill-tmux "$KNAME" --wait 5)" || fail "delete --kill-tmux failed: $out"
! tmux -L "$SOCK" has-session -t "=$KNAME" 2>/dev/null || fail "delete --kill-tmux left the tmux session"
[[ ! -e "${PROJ}/${C_KILL}.jsonl" ]] || fail "delete --kill-tmux left the transcript"
out="$("$SESSIONS" delete claude "$C_KILL" --kill-tmux "$KNAME")" || fail "repeat delete --kill-tmux should succeed"
[[ "$out" == *"already gone"* ]] || fail "repeat delete should say already gone: $out"
"$SESSIONS" delete codex 019f0000-0000-7000-8000-0000000000aa --missing-ok >/dev/null || fail "--missing-ok should exit 0 for a missing conversation"
if "$SESSIONS" delete claude "$C_KILL" --kill-tmux "ai/codex/todo-aaaaaaaa" >/dev/null 2>&1; then fail "--kill-tmux accepted another tool's tmux name"; else [[ $? -eq 64 ]] || fail "bad --kill-tmux should exit 64"; fi
start=$(date +%s)
if "$SESSIONS" delete claude "$C_RUN" --kill-tmux "ai/claude/todo-notmux" --wait 1 >/dev/null 2>&1; then
  fail "delete --kill-tmux removed a conversation still running outside tmux"
else
  [[ $? -eq 65 ]] || fail "still-running conversation should exit 65 after --wait"
fi
[[ $(( $(date +%s) - start )) -le 4 && -f "${PROJ}/${C_RUN}.jsonl" ]] || fail "--wait didn't time out promptly or deleted"
pass "delete --kill-tmux ends the tmux session, waits, deletes; missing = already gone; refuses if still running"

# prune only passes valid ids to delete.
printf '{"type":"user","cwd":"%s","message":{"content":"stray agent file"}}\n' "${HOME}/programming" >"${PROJ}/agent-foo.jsonl"
touch -t "$OLD" "${PROJ}/agent-foo.jsonl"
AI_TODO_HUB_CONF="$PRUNE_CONF" "$SESSIONS" prune --older-than 30 >"${SANDBOX}/prune5.txt" 2>"${SANDBOX}/prune5.err"
! grep -q "would delete .*agent-foo" "${SANDBOX}/prune5.txt" || fail "prune listed a file with an invalid id"
grep -q "unexpected id: 'agent-foo'" "${SANDBOX}/prune5.err" || fail "prune didn't report the skipped id: $(cat "${SANDBOX}/prune5.err")"
pass "prune skips (and reports) conversations whose id doesn't look like a session id"

# ai-todo-open passes its PATH into new tmux sessions: an already-running tmux server
# started with a bare environment can still run npm-installed codex (needs `node`).
NVM_BIN="${HOME}/.nvm/versions/node/v99.0.0/bin"
mkdir -p "$NVM_BIN"
NODE_LOG="${SANDBOX}/node.log"
printf '#!/bin/sh\necho "node $*" >>"%s"\nexec sleep 300\n' "$NODE_LOG" >"${NVM_BIN}/fakenode"
printf '#!/usr/bin/env fakenode\n' >"${NVM_BIN}/codex"
chmod +x "${NVM_BIN}/fakenode" "${NVM_BIN}/codex"
PSOCK="${SOCK}-path"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$(command -v tmux)" -L "$PSOCK" new-session -d -s keep -- sleep 300
out="$(env -u AI_TODO_CODEX_BIN PATH=/usr/bin:/bin AI_TODO_TMUX_SOCKET="$PSOCK" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" "ai/codex/todo-pathtest" '~/programming' "$X_LINKED" codex)" || fail "ai-todo-open via nvm codex failed: $out"
for _ in $(seq 1 50); do [[ -s "$NODE_LOG" ]] && break; sleep 0.1; done
tmux -L "$PSOCK" kill-server >/dev/null 2>&1 || true
grep -q "resume ${X_LINKED}" "$NODE_LOG" 2>/dev/null || fail "npm-installed codex couldn't find node inside an existing tmux server"
pass "ai-todo-open passes the resolved PATH into new tmux sessions (nvm codex works with a running tmux server)"

# --- ai-todo-hook -------------------------------------------------------------

HUB_LOG="${SANDBOX}/hub.log"
HUB_PORT_FILE="${SANDBOX}/hub.port"
python3 - "$HUB_LOG" "$HUB_PORT_FILE" <<'PY' &
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

log_path, port_path = sys.argv[1], sys.argv[2]
# When this file exists, the next post writes "now + 1" into the file it names: a keystroke
# in the conversation right after the hook posted (for the waiting re-check test).
touch_on_post = os.path.join(os.path.dirname(log_path), "touch-on-post")

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
        if os.path.exists(touch_on_post):
            with open(touch_on_post) as f:
                target = f.read().strip()
            os.remove(touch_on_post)
            with open(target, "w") as f:
                f.write(str(int(time.time()) + 1))
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
# No waiting re-check delay unless a test asks for one.
export AI_TODO_RECHECK_DELAY=0

printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your \\"permission\\""}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
python3 - "$HUB_LOG" "$SID" <<'PY' || fail "hook request was wrong: $(cat "$HUB_LOG")"
import json, sys
req = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert req["path"] == "/api/conversations/status", req
assert req["auth"] == "Bearer s3cret", req
assert req["type"] == "application/json", req
assert req["body"] == {"claude_session_id": sys.argv[2], "status": "waiting", "attended": False,
                       "message": 'Claude needs your "permission"'}, req
PY
pass "hook posts status + message with the bearer token"

printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle
[[ $(wc -l <"$HUB_LOG") -eq 2 ]] || fail "idle hook did not post"
python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; assert b=={"claude_session_id":sys.argv[2],"status":"idle","attended":False}, b' "$HUB_LOG" "$SID" \
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

# attended: a tmux client attached to the conversation had keyboard activity recently.
ACTIVITY="${SANDBOX}/client-activity"
last_attended() {
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]["attended"])' "$HUB_LOG"
}
waiting() { # [env...]: one waiting hook for the todo conversation
  printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your permission"}' "$SID" \
    | env AI_TODO_TMUX_SESSION="$NAME" AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" "$@" "$HOOK" waiting
}
date +%s >"$ACTIVITY"
before=$(wc -l <"$HUB_LOG")
waiting AI_TODO_RECHECK_DELAY=0
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) && "$(last_attended)" == True ]] \
  || fail "recent client activity was not reported as attended: $(tail -1 "$HUB_LOG")"
echo $(( $(date +%s) - 3600 )) >"$ACTIVITY"
waiting AI_TODO_RECHECK_DELAY=0
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) && "$(last_attended)" == False ]] \
  || fail "old activity counted as attended, or a re-check posted without new activity"
pass "hook reports attended from recent tmux client activity"

# Re-check: a keystroke after the prompt (the user answered it) re-posts waiting + attended.
before=$(wc -l <"$HUB_LOG")
printf '%s\n' "$ACTIVITY" >"${SANDBOX}/touch-on-post"
waiting AI_TODO_RECHECK_DELAY=2
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) ]] || fail "re-check did not post: $(tail -2 "$HUB_LOG")"
[[ "$(last_status)" == waiting && "$(last_attended)" == True ]] || fail "re-check body wrong: $(tail -1 "$HUB_LOG")"
python3 -c 'import json,sys; l=open(sys.argv[1]).read().splitlines(); assert json.loads(l[-2])["body"]["attended"] is False, l[-2]' "$HUB_LOG" \
  || fail "the first post should not be attended"
pass "hook re-checks a waiting prompt and reports the answer as attended"

wait_for_posts() { # <count>: until the fake hub has logged this many requests
  for _ in $(seq 1 50); do [[ $(wc -l <"$HUB_LOG") -ge $1 ]] && return 0; sleep 0.1; done
  fail "expected $1 hub requests, got $(wc -l <"$HUB_LOG")"
}

# Answered and the quick tool finished before the re-check: the status moved on, so the
# re-check must not post waiting again.
before=$(wc -l <"$HUB_LOG")
echo $(( $(date +%s) - 3600 )) >"$ACTIVITY"
printf '%s\n' "$ACTIVITY" >"${SANDBOX}/touch-on-post"
waiting AI_TODO_RECHECK_DELAY=2 &
recheck_pid=$!
wait_for_posts $((before + 1))
tool
wait "$recheck_pid"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) && "$(last_status)" == busy ]] \
  || fail "re-check posted after the status moved on: $(tail -2 "$HUB_LOG")"
pass "no re-check once the conversation moved on from waiting"

# Prompt 1's late re-check must not speak for prompt 2: a keystroke after prompt 2 appeared
# answers neither on prompt 1's behalf.
before=$(wc -l <"$HUB_LOG")
echo $(( $(date +%s) - 3600 )) >"$ACTIVITY"
waiting AI_TODO_RECHECK_DELAY=3 &
recheck_pid=$!
wait_for_posts $((before + 1))
tool
waiting AI_TODO_RECHECK_DELAY=0
echo $(( $(date +%s) + 1 )) >"$ACTIVITY"
wait "$recheck_pid"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 3)) && "$(last_status)" == waiting && "$(last_attended)" == False ]] \
  || fail "prompt 1's re-check posted for prompt 2: $(tail -3 "$HUB_LOG")"
pass "a re-check only speaks for its own prompt"

before=$(wc -l <"$HUB_LOG")
echo $(( $(date +%s) + 5 )) >"$ACTIVITY"
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" AI_TODO_RECHECK_DELAY=0 "$HOOK" idle
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) ]] || fail "idle must not re-check"
pass "no re-check for busy/idle"

# --- ai-todo-codex-notify ---------------------------------------------------------

NOTIFY="${SCRIPT_DIR}/ai-todo-codex-notify"
XTMUX="ai/codex/todo-0f3a9c21"
TURN=$(printf '{"type":"agent-turn-complete","thread-id":"%s","turn-id":"t1","cwd":"/x","client":"codex-tui","input-messages":["hi"],"last-assistant-message":"OK"}' "$X_LINKED")
before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" "$TURN" || fail "codex notify exited non-zero"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) ]] || fail "codex notify did not post"
python3 - "$HUB_LOG" "$X_LINKED" <<'PY' || fail "codex notify request was wrong: $(tail -1 "$HUB_LOG")"
import json, sys
req = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert req["path"] == "/api/conversations/status", req
assert req["auth"] == "Bearer s3cret", req
assert req["body"] == {"session_id": sys.argv[2], "tool": "codex", "status": "idle", "attended": False}, req
PY
APPROVAL=$(printf '{"type":"approval-requested","thread-id":"%s"}' "$X_LINKED")
date +%s >"$ACTIVITY"
AI_TODO_TMUX_SESSION="$XTMUX" AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" AI_TODO_RECHECK_DELAY=0 "$NOTIFY" "$APPROVAL"
[[ "$(last_status)" == waiting && "$(last_attended)" == True ]] || fail "approval-requested was not reported as attended waiting"
echo $(( $(date +%s) - 3600 )) >"$ACTIVITY"
printf '%s\n' "$ACTIVITY" >"${SANDBOX}/touch-on-post"
before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="$XTMUX" AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" AI_TODO_RECHECK_DELAY=2 "$NOTIFY" "$APPROVAL"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) && "$(last_attended)" == True ]] || fail "codex re-check did not report the answer: $(tail -2 "$HUB_LOG")"
echo $(( $(date +%s) - 3600 )) >"$ACTIVITY"
printf '%s\n' "$ACTIVITY" >"${SANDBOX}/touch-on-post"
before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="$XTMUX" AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" AI_TODO_RECHECK_DELAY=2 "$NOTIFY" "$APPROVAL" &
recheck_pid=$!
wait_for_posts $((before + 1))
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" "$TURN"
wait "$recheck_pid"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) && "$(last_status)" == idle ]] \
  || fail "codex re-check posted after the turn completed: $(tail -2 "$HUB_LOG")"
pass "codex notify posts idle on agent-turn-complete (waiting on approval-requested) with tool=codex and the token"

before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="ai/claude/todo-0f3a9c21" "$NOTIFY" "$TURN"
env -u TMUX "$NOTIFY" "$TURN"
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" '{"type":"something-else","thread-id":"x"}'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" 'not json'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" '{"type":"agent-turn-complete","thread-id":"../../etc"}'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY"
[[ $(wc -l <"$HUB_LOG") -eq $before ]] || fail "codex notify posted for a non-todo session or bad payload"
pass "codex notify ignores non-codex/non-tmux sessions, other events, bad JSON and bad ids"

CHAIN_LOG="${SANDBOX}/chain.log"
printf '#!/bin/sh\nprintf "%%s|" "$@" >>"%s"\n' "$CHAIN_LOG" >"${SANDBOX}/orig-notify"
chmod +x "${SANDBOX}/orig-notify"
before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" --chain "${SANDBOX}/orig-notify" turn-ended "$TURN"
[[ "$(cat "$CHAIN_LOG")" == "turn-ended|${TURN}|" ]] || fail "chained notify got wrong args: $(cat "$CHAIN_LOG")"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) ]] || fail "chained codex notify did not post"
rm -f "$CHAIN_LOG"
AI_TODO_TMUX_SESSION="other" "$NOTIFY" --chain "${SANDBOX}/orig-notify" turn-ended "$TURN"
[[ "$(cat "$CHAIN_LOG")" == "turn-ended|${TURN}|" ]] || fail "chained notify must run even for non-todo sessions"
pass "codex notify --chain runs the original program with its args + the JSON, and still reports"

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
[[ -x "${HOME}/.ai-remote/bin/ai-todo-open" && -x "${HOME}/.ai-remote/bin/ai-todo-hook" && -x "${HOME}/.ai-remote/bin/ai-todo-sessions" ]] || fail "scripts not installed"
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

OUR_NOTIFY="notify = [\"${HOME}/.ai-remote/bin/ai-todo-codex-notify\"]"
[[ -x "${HOME}/.ai-remote/bin/ai-todo-codex-notify" ]] || fail "ai-todo-codex-notify not installed"
[[ "$(grep -c '^notify' "${HOME}/.codex/config.toml")" -eq 1 ]] && grep -qxF "$OUR_NOTIFY" "${HOME}/.codex/config.toml" \
  || fail "codex notify not added exactly once: $(cat "${HOME}/.codex/config.toml")"
pass "install adds our notify to a codex config without one, once"

CX="${SANDBOX}/codex2"
mkdir -p "$CX"
cat >"${CX}/config.toml" <<'EOF'
model = "gpt-5"
notify = ["/Applications/Other.app/notify", "turn-ended"]

[projects."/x"]
trust_level = "trusted"
EOF
cp "${CX}/config.toml" "${SANDBOX}/codex2.orig"
out="$(CODEX_HOME="$CX" "$INSTALL")"
cmp -s "${CX}/config.toml" "${SANDBOX}/codex2.orig" || fail "install changed an existing foreign notify without --chain-codex-notify"
grep -q "left unchanged" <<<"$out" || fail "install did not explain the existing notify: $out"
CODEX_HOME="$CX" "$INSTALL" --chain-codex-notify >/dev/null
grep -qxF "notify = [\"${HOME}/.ai-remote/bin/ai-todo-codex-notify\", \"--chain\", \"/Applications/Other.app/notify\", \"turn-ended\"]" "${CX}/config.toml" \
  || fail "notify not chained: $(cat "${CX}/config.toml")"
python3 - "${CX}/config.toml" <<'PY' || fail "chained config lost other keys/order"
import sys
text = open(sys.argv[1]).read()
assert text.index("notify") < text.index("[projects"), text
assert 'model = "gpt-5"' in text and 'trust_level = "trusted"' in text, text
PY
[[ -f "${HOME}/.ai-remote/codex-notify-original" ]] || fail "original notify line not saved"
ls "${CX}/config.toml.bak-"* >/dev/null 2>&1 || fail "config.toml was not backed up"
grep -q "already set up" <<<"$(CODEX_HOME="$CX" "$INSTALL" --chain-codex-notify)" || fail "re-running chain is not idempotent"
CODEX_HOME="$CX" "$INSTALL" --uninstall >/dev/null
cmp -s "${CX}/config.toml" "${SANDBOX}/codex2.orig" || fail "uninstall did not restore the original notify: $(cat "${CX}/config.toml")"
[[ ! -e "${HOME}/.ai-remote/codex-notify-original" ]] || fail "saved original notify left behind"
pass "an existing codex notify is left alone, chained only with --chain-codex-notify, and restored by uninstall"
"$INSTALL" >/dev/null

cp "$SETTINGS" "${SANDBOX}/settings.good"
printf '{ broken' >"$SETTINGS"
if "$INSTALL" >/dev/null 2>&1; then fail "install accepted an invalid settings.json"; fi
[[ "$(cat "$SETTINGS")" == "{ broken" ]] || fail "install modified an invalid settings.json"
cp "${SANDBOX}/settings.good" "$SETTINGS"
pass "install refuses an invalid settings.json and leaves it alone"

mkdir -p "${HOME}/.ai-remote/hook-state" && printf 'busy\n' >"${HOME}/.ai-remote/hook-state/someid"
"$INSTALL" --uninstall >/dev/null
[[ ! -e "${HOME}/.ai-remote/hook-state" ]] || fail "uninstall left ~/.ai-remote/hook-state"
[[ ! -e "${HOME}/.ai-remote/bin/ai-todo-codex-notify" ]] || fail "uninstall left ai-todo-codex-notify"
! grep -q 'ai-todo-codex-notify' "${HOME}/.codex/config.toml" || fail "uninstall left our codex notify: $(cat "${HOME}/.codex/config.toml")"
python3 - "$SETTINGS" <<'PY' || fail "settings.json after uninstall is wrong: $(cat "$SETTINGS")"
import json, sys
s = json.load(open(sys.argv[1]))
hooks = s["hooks"]
assert "UserPromptSubmit" not in hooks and "Notification" not in hooks, hooks
assert [h["command"] for g in hooks["Stop"] for h in g["hooks"]] == ["afplay /System/Library/Sounds/Glass.aiff"], hooks
assert hooks["PreToolUse"][0]["matcher"] == "Bash"
assert s["model"] == "opus"
PY
[[ ! -e "${HOME}/.ai-remote/bin/ai-todo-open" && ! -e "${HOME}/.ai-remote/bin/ai-todo-sessions" && ! -e "${HOME}/.ai-remote/tmux.conf" ]] || fail "uninstall left scripts behind"
! grep -q 'ai-remote/tmux.conf' "${HOME}/.tmux.conf" || fail "uninstall left the tmux source line"
grep -q 'set -g status off' "${HOME}/.tmux.conf" || fail "uninstall removed other ~/.tmux.conf lines"
pass "uninstall removes only our hooks, scripts, tmux line, codex notify and hook state"

echo "All ${passes} todo script tests passed."
