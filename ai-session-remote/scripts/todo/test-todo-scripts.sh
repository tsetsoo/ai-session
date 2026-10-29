#!/usr/bin/env bash
# Offline tests for scripts/todo: ai-todo-open, ai-todo-sessions, ai-todo-hook, ai-todo-mcp, tmux.conf, install.sh.
# Fully sandboxed: temp HOME, fake claude + codex, fake todo-server, private tmux socket.
# Never touches the real ~/.claude, ~/.tmux.conf, ~/.ai-remote or tmux server.
set -euo pipefail

# Fail loudly unless every test ran. bash reads a script as it goes, so a syntax error halfway
# down, or an edit to this file mid-run, used to end the suite early with exit 0. Run from a
# private copy that parsed cleanly; cleanup() fails any exit that didn't reach the end.
if [[ -z "${AI_TODO_TEST_COPY:-}" ]]; then
  AI_TODO_TEST_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  AI_TODO_TEST_COPY="$(mktemp)"
  cp "$0" "$AI_TODO_TEST_COPY"
  if ! bash -n "$AI_TODO_TEST_COPY"; then
    rm -f "$AI_TODO_TEST_COPY"
    echo "FAIL: $0 does not parse" >&2
    exit 1
  fi
  export AI_TODO_TEST_SCRIPT_DIR AI_TODO_TEST_COPY
  exec bash "$AI_TODO_TEST_COPY" "$@"
fi
SCRIPT_DIR="$AI_TODO_TEST_SCRIPT_DIR"
SCRIPT_COPY="$AI_TODO_TEST_COPY"
unset AI_TODO_TEST_SCRIPT_DIR AI_TODO_TEST_COPY
SANDBOX="$(mktemp -d)"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# Never reach the real claude, codex or launchctl: drop PATH entries under the real home and
# put guards first. Tests pass their fakes explicitly (AI_TODO_*_BIN, fake launchctl).
GUARD_BIN="${SANDBOX}/guard-bin"
mkdir -p "$GUARD_BIN"
for guarded in claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/guard.log"\nexit 99\n' "$guarded" "$SANDBOX" >"${GUARD_BIN}/${guarded}"
  chmod +x "${GUARD_BIN}/${guarded}"
done
PATH="${GUARD_BIN}:$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^${HOME}" | paste -sd: -)"
export PATH
export HOME="${SANDBOX}/home"
export PYTHONDONTWRITEBYTECODE=1  # tests import ai_todo_redact.py from the source tree
# install.sh honours CODEX_HOME; never let it point at a real Codex config.
unset CODEX_HOME
mkdir -p "$HOME"
SOCK="aitodo-test-$$"
export AI_TODO_TMUX_SOCKET="$SOCK"
HUB_PID=""
EXTRA_PIDS=""

cleanup() {
  local status=$?
  tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
  tmux -L "${SOCK}-mcpenv" kill-server >/dev/null 2>&1 || true
  for pid in $HUB_PID $EXTRA_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$SANDBOX" "$SCRIPT_COPY"
  if [[ -z "$SUITE_COMPLETE" ]]; then
    echo "FAIL: suite stopped early after ${passes} passes" >&2
    ((status != 0)) || status=1
  fi
  exit "$status"
}
SUITE_COMPLETE=""
passes=0
trap cleanup EXIT

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

for args in "ai/claude/other x $SID" "ai/claude/todo-Bad ~ $SID" "$NAME ~ not-a-uuid" "$NAME ~" \
  "--mcp" "$NAME ~ $SID --mcp grafana" "$NAME --mcp grafana ~ $SID" "--mcp grafana --mcp slack $NAME ~ $SID"; do
  # shellcheck disable=SC2086
  if AI_TODO_OPEN_DETACH=1 "$OPEN" $args >/dev/null 2>&1; then
    fail "ai-todo-open accepted bad arguments: $args"
  fi
done
pass "ai-todo-open rejects bad tmux names, session ids and argument counts, and --mcp anywhere but first"

# tmux without CLIENT_UTF8 rewrites Cyrillic and symbols as underscores.
grep -q 'exec tmux -u ' "$OPEN" || fail "ai-todo-open must exec tmux -u (UTF-8 client)"
grep -q ' -u "$@"' "$OPEN" || fail "ai-todo-open must pass -u for a private tmux socket too"
grep -q 'LANG=$session_lang' "$OPEN" || fail "ai-todo-open must give new sessions a UTF-8 locale"
pass "ai-todo-open attaches with UTF-8 so Cyrillic and symbols are not replaced"

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

# The running-session fast path comes before the tool lookup: no claude binary needed.
out="$(AI_TODO_CLAUDE_BIN=/nonexistent PATH=/usr/bin:/bin:"$(dirname "$(command -v tmux)")" \
  AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$SID")"
[[ "$out" == attach ]] || fail "a running session should attach before the tool checks, printed '$out'"
pass "a running session attaches before the checks a new one needs"

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
C_MCP=99999999-9999-4999-8999-999999999999    # old, running via ai-todo-open --mcp: kept
X_MCP=019f0000-0000-7000-8000-000000000006     # codex, old, running via ai-todo-open --mcp: kept
claude_conv "$C_MCP" "mcp work"
codex_conv "$X_MCP" '"cli"' "codex mcp work"
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
# Started by ai-todo-open with --mcp: the MCP flags come before the id, and the env file
# wrapper (/bin/sh -c '... exec "$@"') must leave the tool itself as the pane's process.
mkdir -p "${HOME}/.ai-remote/mcp"
printf '{"mcpServers":{"grafana":{"command":"docker","args":["run","mcp/grafana"]}}}\n' >"${HOME}/.ai-remote/mcp/grafana.json"
printf 'GRAFANA_TOKEN=fake\n' >"${HOME}/.ai-remote/mcp/env"
AI_TODO_CLAUDE_BIN="${SANDBOX}/run/claude" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" --mcp grafana "ai/claude/todo-mcplist" '~/programming' "$C_MCP" >/dev/null || fail "claude --mcp open for list failed"
AI_TODO_CODEX_BIN="${SANDBOX}/run/codex" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" --mcp grafana "ai/codex/todo-mcplist" '~/programming' "$X_MCP" codex >/dev/null || fail "codex --mcp open for list failed"
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
assert by["$C_MCP"]["running"] and by["$C_MCP"]["tmux_session"] == "ai/claude/todo-mcplist", by["$C_MCP"]
assert by["$X_MCP"]["running"] and by["$X_MCP"]["tmux_session"] == "ai/codex/todo-mcplist", by["$X_MCP"]
PY
[[ "$("$SESSIONS" list --json --tool codex --limit 2 | python3 -c 'import json,sys; r=json.load(sys.stdin); print(len(r), {x["tool"] for x in r})')" == "2 {'codex'}" ]] \
  || fail "list --tool/--limit not applied"
pass "list --json: fields, newest first, skips empty and sub-agent conversations, --tool/--limit"
pass "list detects running conversations (sessions file, claude/codex argv, started with --mcp) and their tmux session"
tmux -L "$SOCK" kill-session -t "=ai/claude/todo-mcplist"
tmux -L "$SOCK" kill-session -t "=ai/codex/todo-mcplist"
rm -f "${HOME:?}/.ai-remote/mcp/grafana.json" "${HOME:?}/.ai-remote/mcp/env" "${PROJ:?}/${C_MCP:?}.jsonl" \
  "${CODEX_DAY:?}/rollout-2026-01-02T10-00-00-${X_MCP:?}.jsonl"

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

# rename: Claude reads the last custom-title line of the transcript, even one another
# process appended while it runs; Codex names threads through its app-server.
"$SESSIONS" rename claude "$C_NEW" $'  Fix the "parser"\n  again ✓  ' >/dev/null || fail "claude rename failed"
python3 - "${PROJ}/${C_NEW}.jsonl" "$C_NEW" <<'PY' || fail "claude rename line wrong: $(tail -1 "${PROJ}/${C_NEW}.jsonl")"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert json.loads(lines[-1]) == {"type": "custom-title", "customTitle": 'Fix the "parser" again ✓', "sessionId": sys.argv[2]}, lines[-1]
assert json.loads(lines[-2])["type"] == "assistant", "rename must append, not rewrite"
PY
before=$(cat "${PROJ}/${C_NEW}.jsonl")
for bad in "claude ../../etc name" "claude ${C_NEW}" "cursor ${C_NEW} name" "bogus ${C_NEW} name"; do
  # shellcheck disable=SC2086
  if "$SESSIONS" rename $bad >/dev/null 2>&1; then fail "rename accepted: $bad"; else [[ $? -eq 64 ]] || fail "rename $bad should exit 64"; fi
done
if "$SESSIONS" rename claude "$C_NEW" $' \n ' >/dev/null 2>&1; then fail "rename accepted a blank name"; else [[ $? -eq 64 ]] || fail "blank name should exit 64"; fi
if "$SESSIONS" rename claude "$C_DEL" "gone" >/dev/null 2>&1; then fail "rename of a missing conversation succeeded"; else [[ $? -eq 66 ]] || fail "missing conversation should exit 66"; fi
[[ "$(cat "${PROJ}/${C_NEW}.jsonl")" == "$before" ]] || fail "a refused rename changed the transcript"
# A transcript without a final newline (Claude mid-write) gets one before our line.
printf '{"type":"user","message":{"content":"x"}}' >>"${PROJ}/${C_OLD}.jsonl"
"$SESSIONS" rename claude "$C_OLD" "Half line" >/dev/null || fail "claude rename after a partial line failed"
tail -2 "${PROJ}/${C_OLD}.jsonl" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]' \
  || fail "rename after a partial line broke the JSONL: $(tail -2 "${PROJ}/${C_OLD}.jsonl")"
touch -t "$OLD" "${PROJ}/${C_OLD}.jsonl"  # still old for the prune tests below
pass "rename claude appends a custom-title line (whitespace collapsed, after a newline); bad args 64, missing 66"

FAKE_APP_SERVER="${SANDBOX}/bin/fake-codex-rename"
RENAME_LOG="${SANDBOX}/codex-rename.log"
cat >"$FAKE_APP_SERVER" <<EOF
#!/usr/bin/env python3
import json, sys
assert sys.argv[1:] == ["app-server"], sys.argv
for line in sys.stdin:
    msg = json.loads(line)
    rid = msg.get("id")
    if rid is None:
        continue
    if msg["method"] == "thread/name/set":
        # A server request reusing the client's id comes first; it is not the answer.
        print(json.dumps({"id": rid, "method": "item/tool/requestUserInput", "params": {}}), flush=True)
        with open("${RENAME_LOG}", "a") as f:
            f.write(json.dumps(msg["params"], ensure_ascii=False) + "\n")
        if msg["params"]["name"] == "refuse":
            print(json.dumps({"id": rid, "error": {"code": -32600, "message": "no rollout found"}}), flush=True)
            continue
    print(json.dumps({"id": rid, "result": {}}), flush=True)
EOF
chmod +x "$FAKE_APP_SERVER"
AI_TODO_CODEX_BIN="$FAKE_APP_SERVER" "$SESSIONS" rename codex "$X_LINKED" "Codex ✓ name" >/dev/null || fail "codex rename failed"
[[ "$(cat "$RENAME_LOG")" == "{\"threadId\": \"${X_LINKED}\", \"name\": \"Codex ✓ name\"}" ]] || fail "codex rename call wrong: $(cat "$RENAME_LOG")"
if AI_TODO_CODEX_BIN="$FAKE_APP_SERVER" "$SESSIONS" rename codex "$X_LINKED" "refuse" >/dev/null 2>"${SANDBOX}/rename.err"; then
  fail "codex rename ignored an app-server error"
fi
grep -q "no rollout found" "${SANDBOX}/rename.err" || fail "codex rename error not reported: $(cat "${SANDBOX}/rename.err")"
if AI_TODO_CODEX_BIN="$FAKE_APP_SERVER" "$SESSIONS" rename codex "019f0000-0000-7000-8000-00000000dead" "x" >/dev/null 2>&1; then
  fail "rename of a codex thread without a rollout succeeded"
else
  [[ $? -eq 66 ]] || fail "codex thread without a rollout should exit 66"
fi
pass "rename codex calls thread/name/set through codex app-server, reports its errors; no rollout 66"

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
        self.send_response(200 if self.path == "/api/conversations?show=all" else 404)
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
[[ "$(cat "$CODEX_LOG")" == "${HOME}/programming resume ${X_LINKED} --approve-for-me" ]] || fail "unexpected codex start: $(cat "$CODEX_LOG")"
[[ "$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$XNAME" '~/programming' "$X_LINKED" codex)" == attach ]] || fail "second codex open did not attach"
if AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-nothere" '~/programming' 019f0000-0000-7000-8000-0000000000ff codex >/dev/null 2>&1; then
  fail "codex open accepted an unknown conversation"
else
  [[ $? -eq 94 ]] || fail "unknown codex conversation should exit 94"
fi
if AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$X_LINKED" codex >/dev/null 2>&1; then fail "codex open accepted a claude tmux name"; fi
if AI_TODO_OPEN_DETACH=1 "$OPEN" "$XNAME" '~/programming' "$X_LINKED" cursor >/dev/null 2>&1; then fail "cursor open accepted a codex tmux name"; fi
pass "ai-todo-open codex: resumes in tmux, attaches when running, exits 94 for unknown ids, checks tool vs name"

# Another Codex holding the conversation's writer lock: say which one and exit 95 instead of
# leaving the TUI on "This conversation is open in another app". Codex flocks the lock file;
# the holder does the same, with the argv a real holder would have after its arguments.
WLOCK="${HOME}/.codex/thread-writer-locks/${X_RUN}.lock"
mkdir -p "$(dirname "$WLOCK")"
HOLDER="${SANDBOX}/bin/lock-holder"
cat >"$HOLDER" <<'EOF'
#!/usr/bin/env python3
import fcntl, sys, time
handle = open(sys.argv[1], "a")
if sys.argv[2] == "lock":
    fcntl.flock(handle, fcntl.LOCK_EX)
open(sys.argv[3], "w").close()
time.sleep(300)
EOF
chmod +x "$HOLDER"
HOLDER_PID=
start_holder() { # <lock|open> <argv...>: HOLDER_PID once it has the lock file
  local ready="${SANDBOX}/holder.ready" mode=$1
  shift
  rm -f "$ready"
  "$HOLDER" "$WLOCK" "$mode" "$ready" "$@" </dev/null >/dev/null 2>&1 &
  HOLDER_PID=$!
  EXTRA_PIDS="$EXTRA_PIDS $HOLDER_PID"
  for _ in $(seq 1 50); do [[ -e "$ready" ]] && return; sleep 0.1; done
  fail "lock holder never opened the lock"
}
stop_holder() { kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; }
open_held() { # <tmux name>: ai-todo-open's exit status, stderr in held.err
  local status=0
  AI_TODO_OPEN_DETACH=1 "$OPEN" "$1" '~/programming' "$X_RUN" codex >"${SANDBOX}/held.out" 2>"${SANDBOX}/held.err" || status=$?
  echo "$status"
}
saved_codex_log=$(cat "$CODEX_LOG")

start_holder lock app-server --listen unix:// --managed-daemon
[[ "$(open_held ai/codex/todo-held)" == 95 ]] || fail "a conversation the shared server holds should exit 95: $(cat "${SANDBOX}/held.err")"
grep -q "pid ${HOLDER_PID}: Codex's shared server" "${SANDBOX}/held.err" && grep -q 'codex app-server daemon restart' "${SANDBOX}/held.err" \
  || fail "shared server message wrong: $(cat "${SANDBOX}/held.err")"
tmux -L "$SOCK" has-session -t "=ai/codex/todo-held" 2>/dev/null && fail "a held conversation still started a tmux session"
stop_holder

start_holder lock some-other-codex
[[ "$(open_held ai/codex/todo-held)" == 95 ]] || fail "a conversation another Codex holds should exit 95: $(cat "${SANDBOX}/held.err")"
grep -q "pid ${HOLDER_PID}: /" "${SANDBOX}/held.err" && grep -q "stop that process" "${SANDBOX}/held.err" \
  || fail "other Codex message wrong: $(cat "${SANDBOX}/held.err")"
stop_holder

# Another todo's backend (they outlive their tmux session): named, with the session if it runs.
other_sock="${HOME}/.ai-remote/status-state/r/$(printf '%s' ai/codex/todo-other | shasum -a 256 | cut -c1-12).sock"
start_holder lock app-server --listen "unix://${other_sock}"
[[ "$(open_held ai/codex/todo-held)" == 95 ]] || fail "another todo's backend holding it should exit 95: $(cat "${SANDBOX}/held.err")"
grep -q "backend for a todo session that has closed" "${SANDBOX}/held.err" && grep -q "kill ${HOLDER_PID}" "${SANDBOX}/held.err" \
  || fail "closed todo backend message wrong: $(cat "${SANDBOX}/held.err")"
tmux -L "$SOCK" new-session -d -s ai/codex/todo-other -- sleep 300
[[ "$(open_held ai/codex/todo-held)" == 95 ]] || fail "a running todo's backend holding it should exit 95"
grep -q "backend for ai/codex/todo-other, which has it open" "${SANDBOX}/held.err" || fail "running todo backend message wrong: $(cat "${SANDBOX}/held.err")"
tmux -L "$SOCK" kill-session -t "=ai/codex/todo-other"
stop_holder

# Its own backend (same tmux name), or a process with the file open but not locked, doesn't count.
own_sock="${HOME}/.ai-remote/status-state/r/$(printf '%s' ai/codex/todo-held | shasum -a 256 | cut -c1-12).sock"
start_holder lock app-server --listen "unix://${own_sock}"
[[ "$(open_held ai/codex/todo-held)" == 0 && "$(cat "${SANDBOX}/held.out")" == resumed ]] || fail "its own backend's lock blocked the resume: $(cat "${SANDBOX}/held.err")"
tmux -L "$SOCK" kill-session -t "=ai/codex/todo-held"
stop_holder
start_holder open some-reader
[[ "$(open_held ai/codex/todo-held)" == 0 ]] || fail "a file opened without the lock blocked the resume: $(cat "${SANDBOX}/held.err")"
tmux -L "$SOCK" kill-session -t "=ai/codex/todo-held"
stop_holder
printf '%s\n' "$saved_codex_log" >"$CODEX_LOG"
pass "ai-todo-open codex: a conversation another Codex holds exits 95 naming it (shared server, other todo's backend, other); its own backend and unlocked opens don't count"

U_LINKED=4e21e083-3303-468c-a212-e5d1cd2c7515
UNAME="ai/cursor/todo-0f3a9c21"
mkdir -p "${HOME}/.cursor/chats/workspace/${U_LINKED}"
FAKE_AGENT="${SANDBOX}/bin/agent"
AGENT_LOG="${SANDBOX}/agent.log"
cat >"$FAKE_AGENT" <<EOF
#!/bin/sh
if [ "\$1" = status ]; then
  echo "Logged in as test"
  exit 0
fi
echo "\$(pwd -P) \$* store=\${AGENT_CLI_CREDENTIAL_STORE:-}" >>"$AGENT_LOG"
[ "\$1" = --resume ] && exec sleep 300
exit 0
EOF
chmod +x "$FAKE_AGENT"
export AI_TODO_AGENT_BIN="$FAKE_AGENT"
out="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$UNAME" '~/programming' "$U_LINKED" cursor)"
[[ "$out" == resumed ]] || fail "cursor open printed '$out', expected resumed"
for _ in $(seq 1 50); do [[ -s "$AGENT_LOG" ]] && break; sleep 0.1; done
[[ "$(cat "$AGENT_LOG")" == "${HOME}/programming --resume ${U_LINKED} store=file" ]] || fail "unexpected cursor start: $(cat "$AGENT_LOG")"
[[ "$(AI_TODO_OPEN_DETACH=1 "$OPEN" "$UNAME" '~/programming' "$U_LINKED" cursor)" == attach ]] || fail "second cursor open did not attach"
if AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/cursor/todo-nothere" '~/programming' aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee cursor >/dev/null 2>&1; then
  fail "cursor open accepted an unknown conversation"
else
  [[ $? -eq 94 ]] || fail "unknown cursor conversation should exit 94"
fi
if AI_TODO_OPEN_DETACH=1 "$OPEN" "$NAME" '~/programming' "$U_LINKED" cursor >/dev/null 2>&1; then fail "cursor open accepted a claude tmux name"; fi
if env -u AI_TODO_AGENT_BIN AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/cursor/todo-missingbin" '~/programming' "$U_LINKED" cursor >/dev/null 2>&1; then
  fail "cursor open ran without an agent binary"
else
  [[ $? -eq 90 ]] || fail "missing agent should exit 90"
fi
pass "ai-todo-open cursor: resumes with agent --resume, attaches when running, exits 94 for unknown ids, exits 90 without agent"

# A fresh Codex or Cursor conversation has no id until the tool creates one.
# Codex before 0.163 writes the rollout at startup.
META_CLI='{"type":"session_meta","payload":{"source":"cli"}}'
META_SUB='{"type":"session_meta","payload":{"source":{"subagent":{"other":"guardian"}}}}'
FRESH_CODEX="${SANDBOX}/bin/codex-fresh"
cat >"$FRESH_CODEX" <<EOF
#!/bin/sh
[ "\$*" = --approve-for-me ] || exit 99
mkdir -p "\$HOME/.codex/sessions/2026/10/20"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/20/rollout-2026-10-20T00-00-00-NEWCODX.jsonl"
exec sleep 300
EOF
chmod +x "$FRESH_CODEX"
out="$(AI_TODO_CODEX_BIN="$FRESH_CODEX" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-new1" '~/programming' - codex)"
[[ "$out" == "created NEWCODX" ]] || fail "fresh codex printed '$out'"

# Codex 0.163 writes the rollout only after the first message. At startup its TUI marks
# the thread under tui-thread-reference-capabilities.
MARKS="${HOME}/.codex/tui-thread-reference-capabilities"
LOCKS="${HOME}/.codex/thread-writer-locks"
mkdir -p "$MARKS" "$LOCKS"
MARK_CODEX="${SANDBOX}/bin/codex-mark"
cat >"$MARK_CODEX" <<EOF
#!/bin/sh
: > "$MARKS/01a16548-895c-7ff3-bbf0-a83014fc8ef9"
: > "$LOCKS/01a16548-895c-7ff3-bbf0-a83014fc8ef9.lock"
exec sleep 300
EOF
chmod +x "$MARK_CODEX"
out="$(AI_TODO_CODEX_BIN="$MARK_CODEX" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-new2" '~/programming' - codex)"
[[ "$out" == "created 01a16548-895c-7ff3-bbf0-a83014fc8ef9" ]] || fail "fresh codex with a TUI mark printed '$out'"

# Codex started with -c overrides (`--mcp`) runs its own app-server: no TUI mark, only the
# thread's writer lock, held open by the pane's codex process. Another Codex's lock that
# appears meanwhile (not held by this pane) is not the new conversation.
LOCK_CODEX="${SANDBOX}/bin/codex-lock"
cat >"$LOCK_CODEX" <<EOF
#!/bin/sh
: > "$LOCKS/01a17375-0000-7000-8000-00000000f00d.lock"
exec 3>>"$LOCKS/01a17375-2583-7b71-9f1d-26964c5c5219.lock"
exec sleep 300
EOF
chmod +x "$LOCK_CODEX"
out="$(AI_TODO_CODEX_BIN="$LOCK_CODEX" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-new-lock" '~/programming' - codex)"
[[ "$out" == "created 01a17375-2583-7b71-9f1d-26964c5c5219" ]] || fail "fresh codex holding only its writer lock printed '$out'"
tmux -L "$SOCK" kill-session -t "=ai/codex/todo-new-lock" 2>/dev/null || true
pass "a fresh Codex with only a writer lock (as with --mcp) is found through the lock its pane holds"

# A Codex that writes both for one thread is still one new conversation.
BOTH_CODEX="${SANDBOX}/bin/codex-both"
cat >"$BOTH_CODEX" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.codex/sessions/2026/10/22"
: > "$MARKS/01a16549-0000-7000-8000-000000000001"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/22/rollout-2026-10-22T00-00-00-01a16549-0000-7000-8000-000000000001.jsonl"
exec sleep 300
EOF
chmod +x "$BOTH_CODEX"
out="$(AI_TODO_CODEX_BIN="$BOTH_CODEX" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-new3" '~/programming' - codex)"
[[ "$out" == "created 01a16549-0000-7000-8000-000000000001" ]] || fail "fresh codex with mark and rollout printed '$out'"

# Other Codex activity during the wait is not the new conversation: an older TUI thread
# sending its first message, a sub-agent or guardian thread of another Codex (a lock and a
# rollout, no TUI mark), and names that are not thread ids.
OLD_MARK_ONLY=01a16540-0000-7000-8000-000000000002
: >"$MARKS/$OLD_MARK_ONLY"
BUSY_CODEX="${SANDBOX}/bin/codex-busy"
cat >"$BUSY_CODEX" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.codex/sessions/2026/10/22" "$MARKS/sub"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/22/rollout-2026-10-22T00-00-01-${OLD_MARK_ONLY}.jsonl"
: > "$LOCKS/01a16541-0000-7000-8000-000000000003.lock"
echo '$META_SUB' > "\$HOME/.codex/sessions/2026/10/22/rollout-2026-10-22T00-00-02-01a16541-0000-7000-8000-000000000003.jsonl"
: > "$MARKS/not-a-thread"
: > "$MARKS/sub/01a16542-0000-7000-8000-000000000006"
sleep 0.5
: > "$MARKS/01a1654a-0000-7000-8000-000000000004"
exec sleep 300
EOF
chmod +x "$BUSY_CODEX"
out="$(AI_TODO_CODEX_BIN="$BUSY_CODEX" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-new4" '~/programming' - codex)"
[[ "$out" == "created 01a1654a-0000-7000-8000-000000000004" ]] || fail "fresh codex beside other codex activity printed '$out'"

# A conversation that was started and never sent a message can't be resumed. Say why.
EMPTY_CODEX=01a1654b-0000-7000-8000-000000000005
: >"$MARKS/$EMPTY_CODEX"
if err="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-empty1" '~/programming' "$EMPTY_CODEX" codex 2>&1 >/dev/null)"; then
  fail "codex open resumed a conversation with no messages"
else
  [[ $? -eq 94 ]] || fail "codex conversation with no messages should exit 94"
  [[ "$err" == *"has no messages"* ]] || fail "codex conversation with no messages said '$err'"
fi

# An archived one is not called empty, even with its mark still there.
ARCHIVED_CODEX=01a1654c-0000-7000-8000-000000000007
: >"$MARKS/$ARCHIVED_CODEX"
mkdir -p "${HOME}/.codex/archived_sessions"
echo "$META_CLI" >"${HOME}/.codex/archived_sessions/rollout-2026-10-22T00-00-03-${ARCHIVED_CODEX}.jsonl"
if err="$(AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-archived1" '~/programming' "$ARCHIVED_CODEX" codex 2>&1 >/dev/null)"; then
  fail "codex open resumed an archived conversation"
else
  [[ $? -eq 94 ]] || fail "archived codex conversation should exit 94"
  [[ "$err" == *"is archived"* ]] || fail "archived codex conversation said '$err'"
fi

# Cursor: the id is the one passed to --new-session-id, whatever other chat appears.
FRESH_AGENT="${SANDBOX}/bin/agent-fresh"
AGENT_ID_FILE="${SANDBOX}/agent-fresh.id"
cat >"$FRESH_AGENT" <<EOF
#!/bin/sh
if [ "\$1" = status ]; then
  # The keychain store is logged out on this machine. Only the file store counts.
  if [ "\${AGENT_CLI_CREDENTIAL_STORE:-}" != file ]; then
    echo "Not logged in"
    exit 0
  fi
  echo "Logged in as test"
  exit 0
fi
case " \$* " in
  *" --new-session-id "*) ;;
  *) echo "expected --new-session-id, got: \$*" >&2; exit 1 ;;
esac
echo "\$2" > "$AGENT_ID_FILE"
mkdir -p "\$HOME/.cursor/chats/abc/OTHERCHAT"
sleep 0.5
mkdir -p "\$HOME/.cursor/chats/abc/\$2"
exec sleep 300
EOF
chmod +x "$FRESH_AGENT"
out="$(AI_TODO_AGENT_BIN="$FRESH_AGENT" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/cursor/todo-new1" '~/programming' - cursor)"
[[ -s "$AGENT_ID_FILE" && "$out" == "created $(cat "$AGENT_ID_FILE")" ]] || fail "fresh cursor printed '$out'"

LOGGED_OUT="${SANDBOX}/bin/agent-logged-out"
LOGGED_OUT_LOG="${SANDBOX}/agent-logged-out.log"
cat >"$LOGGED_OUT" <<EOF
#!/bin/sh
if [ "\$1" = status ]; then
  echo "Not logged in"
  exit 0
fi
echo "started \$*" >>"$LOGGED_OUT_LOG"
exec sleep 300
EOF
chmod +x "$LOGGED_OUT"
if AI_TODO_AGENT_BIN="$LOGGED_OUT" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/cursor/todo-loggedout" '~/programming' - cursor >"${SANDBOX}/loggedout.out" 2>"${SANDBOX}/loggedout.err"; then
  fail "logged-out cursor start should fail"
else
  [[ $? -eq 94 ]] || fail "logged-out cursor start should exit 94"
fi
grep -q "AGENT_CLI_CREDENTIAL_STORE=file agent login" "${SANDBOX}/loggedout.err" || fail "logged-out cursor start stderr: $(cat "${SANDBOX}/loggedout.err")"
tmux -L "$SOCK" has-session -t "=ai/cursor/todo-loggedout" 2>/dev/null && fail "logged-out cursor start left a tmux session"
[[ ! -s "$LOGGED_OUT_LOG" ]] || fail "logged-out cursor start launched agent"
if AI_TODO_AGENT_BIN="$LOGGED_OUT" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/cursor/todo-loggedout2" '~/programming' "$U_LINKED" cursor >"${SANDBOX}/loggedout-resume.out" 2>"${SANDBOX}/loggedout-resume.err"; then
  fail "logged-out cursor resume should fail"
else
  [[ $? -eq 94 ]] || fail "logged-out cursor resume should exit 94"
fi
grep -q "AGENT_CLI_CREDENTIAL_STORE=file agent login" "${SANDBOX}/loggedout-resume.err" || fail "logged-out cursor resume stderr: $(cat "${SANDBOX}/loggedout-resume.err")"
tmux -L "$SOCK" has-session -t "=ai/cursor/todo-loggedout2" 2>/dev/null && fail "logged-out cursor resume left a tmux session"
pass "ai-todo-open refuses a new Cursor conversation when agent is not logged in"

QUIET="${SANDBOX}/bin/quiet-tool"
printf '#!/bin/sh\nexec sleep 300\n' >"$QUIET"
chmod +x "$QUIET"
if AI_TODO_CODEX_BIN="$QUIET" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-quiet" '~/programming' - codex >/dev/null 2>&1; then
  fail "a fresh codex that writes no id should fail"
else
  [[ $? -eq 94 ]] || fail "missing fresh id should exit 94"
fi
tmux -L "$SOCK" has-session -t "=ai/codex/todo-quiet" 2>/dev/null && fail "failed fresh start left a tmux session"
TWO="${SANDBOX}/bin/codex-two"
cat >"$TWO" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.codex/sessions/2026/10/20"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/20/rollout-2026-10-20T00-00-00-ONE.jsonl"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/20/rollout-2026-10-20T00-00-01-TWO.jsonl"
exec sleep 300
EOF
chmod +x "$TWO"
if AI_TODO_CODEX_BIN="$TWO" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-two" '~/programming' - codex >/dev/null 2>&1; then
  fail "two new codex files should not be guessed"
else
  [[ $? -eq 94 ]] || fail "two new codex files should exit 94"
fi
pass "ai-todo-open starts a new Codex or Cursor conversation and reports the id the tool assigns"

# A failed fresh start can leave the tmux name behind. The next fresh open replaces it.
STUCK="${SANDBOX}/bin/codex-stuck"
cat >"$STUCK" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.codex/sessions/2026/10/20"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/20/rollout-2026-10-20T00-00-02-STUCKID.jsonl"
exec sleep 300
EOF
chmod +x "$STUCK"
tmux -L "$SOCK" new-session -d -s "ai/codex/todo-stuck" -c "$HOME" -- sleep 300
out="$(AI_TODO_CODEX_BIN="$STUCK" AI_TODO_OPEN_DETACH=1 "$OPEN" "ai/codex/todo-stuck" '~/programming' - codex)"
[[ "$out" == "created STUCKID" ]] || fail "a leftover fresh session printed '$out'"
pass "a leftover tmux session is replaced when Codex or Cursor starts fresh"

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

# Cursor chats live in ~/.cursor/chats/<hash>/<id>/ and transcripts in agent-transcripts/<id>/.
U_DEL=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
U_KEEP=cccccccc-cccc-4ccc-8ccc-cccccccccccc
U_RUN=dddddddd-dddd-4ddd-8ddd-dddddddddddd
U_KILL=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
U_OPEN=ffffffff-ffff-4fff-8fff-ffffffffffff
U_MISS=12121212-1212-4121-8121-121212121212
cursor_chat() { printf '%s\n' "$1" >"${HOME}/.cursor/chats/workspace/${1}/store.db"; }
mkdir -p "${HOME}/.cursor/chats/workspace/${U_DEL}" "${HOME}/.cursor/chats/workspace/${U_KEEP}" \
  "${HOME}/.cursor/chats/workspace/${U_RUN}" "${HOME}/.cursor/chats/other/${U_DEL}" \
  "${HOME}/.cursor/projects/proj/agent-transcripts/${U_DEL}" \
  "${HOME}/.cursor/projects/proj/agent-transcripts/${U_KEEP}"
cursor_chat "$U_DEL"
cursor_chat "$U_KEEP"
cursor_chat "$U_RUN"
echo keep >"${HOME}/.cursor/chats/other/${U_DEL}/store.db"
echo transcript >"${HOME}/.cursor/projects/proj/agent-transcripts/${U_DEL}/${U_DEL}.jsonl"
echo keep-transcript >"${HOME}/.cursor/projects/proj/agent-transcripts/${U_KEEP}/keep.jsonl"
printf '#!/bin/sh\nsleep 300\n' >"${SANDBOX}/run/agent"
chmod +x "${SANDBOX}/run/agent"
tmux -L "$SOCK" new-session -d -s argv-cursor -- "${SANDBOX}/run/agent" --resume "$U_RUN"
sleep 0.5
if "$SESSIONS" delete cursor "$U_RUN" >/dev/null 2>&1; then
  fail "delete removed a running cursor conversation"
else
  [[ $? -eq 65 ]] || fail "delete of a running cursor conversation should exit 65"
fi
[[ -f "${HOME}/.cursor/chats/workspace/${U_RUN}/store.db" ]] || fail "running cursor chat was removed"
U_FRESH=abababab-abab-4aba-8aba-abababababab
mkdir -p "${HOME}/.cursor/chats/workspace/${U_FRESH}"
echo fresh >"${HOME}/.cursor/chats/workspace/${U_FRESH}/store.db"
tmux -L "$SOCK" new-session -d -s argv-cursor-new -- "${SANDBOX}/run/agent" --new-session-id "$U_FRESH" --trust
sleep 0.5
if "$SESSIONS" delete cursor "$U_FRESH" >/dev/null 2>&1; then
  fail "delete removed a cursor chat started with --new-session-id"
else
  [[ $? -eq 65 ]] || fail "delete of a fresh cursor conversation should exit 65"
fi
[[ -f "${HOME}/.cursor/chats/workspace/${U_FRESH}/store.db" ]] || fail "fresh cursor chat was removed"
mkdir -p "${HOME}/.cursor/chats/workspace/${U_OPEN}"
echo open >"${HOME}/.cursor/chats/workspace/${U_OPEN}/store.db"
python3 -c 'import sys, time; f = open(sys.argv[1]); time.sleep(300)' "${HOME}/.cursor/chats/workspace/${U_OPEN}/store.db" &
EXTRA_PIDS="$EXTRA_PIDS $!"
sleep 0.5
if "$SESSIONS" delete cursor "$U_OPEN" >/dev/null 2>&1; then
  fail "delete removed a cursor chat whose store is open"
else
  [[ $? -eq 65 ]] || fail "open cursor store delete should exit 65"
fi
[[ -f "${HOME}/.cursor/chats/workspace/${U_OPEN}/store.db" ]] || fail "open cursor store was removed"
"$SESSIONS" delete cursor "$U_DEL" >/dev/null || fail "cursor delete failed"
[[ ! -e "${HOME}/.cursor/chats/workspace/${U_DEL}" && ! -e "${HOME}/.cursor/chats/other/${U_DEL}" ]] \
  || fail "cursor delete left a chat directory"
[[ ! -e "${HOME}/.cursor/projects/proj/agent-transcripts/${U_DEL}" ]] || fail "cursor delete left the transcript"
[[ -f "${HOME}/.cursor/chats/workspace/${U_KEEP}/store.db" && -f "${HOME}/.cursor/projects/proj/agent-transcripts/${U_KEEP}/keep.jsonl" ]] \
  || fail "cursor delete removed another conversation"
if "$SESSIONS" delete cursor "$U_MISS" >/dev/null 2>&1; then fail "deleting a missing cursor conversation succeeded"; else [[ $? -eq 66 ]] || fail "missing cursor conversation should exit 66"; fi
"$SESSIONS" delete cursor "$U_MISS" --missing-ok >/dev/null || fail "--missing-ok should exit 0 for a missing cursor conversation"
CKILL="ai/cursor/todo-eeeeeeee"
mkdir -p "${HOME}/.cursor/chats/workspace/${U_KILL}"
echo kill >"${HOME}/.cursor/chats/workspace/${U_KILL}/store.db"
tmux -L "$SOCK" new-session -d -s "$CKILL" -- "${SANDBOX}/run/agent" --resume "$U_KILL"
sleep 0.5
out="$("$SESSIONS" delete cursor "$U_KILL" --kill-tmux "$CKILL" --wait 5)" || fail "cursor delete --kill-tmux failed: $out"
! tmux -L "$SOCK" has-session -t "=$CKILL" 2>/dev/null || fail "cursor delete --kill-tmux left the tmux session"
[[ ! -e "${HOME}/.cursor/chats/workspace/${U_KILL}" ]] || fail "cursor delete --kill-tmux left the chat"
if "$SESSIONS" delete cursor "$U_KILL" --kill-tmux "ai/claude/todo-eeeeeeee" >/dev/null 2>&1; then
  fail "--kill-tmux accepted another tool's tmux name for cursor"
else
  [[ $? -eq 64 ]] || fail "bad cursor --kill-tmux should exit 64"
fi
pass "cursor delete removes every chat copy and its transcript; refuses while running; --kill-tmux ends the session first"

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
printf '#!/bin/sh\ncase "$1" in codex-path) echo "%s/codex";; terminal) shift 3; exec "$@";; esac\n' "$NVM_BIN" >"${SANDBOX}/fake-nvm-status"
chmod +x "${SANDBOX}/fake-nvm-status"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$(command -v tmux)" -L "$PSOCK" new-session -d -s keep -- sleep 300
out="$(env -u AI_TODO_CODEX_BIN PATH=/usr/bin:/bin AI_TODO_STATUS_BIN="${SANDBOX}/fake-nvm-status" AI_TODO_TMUX_SOCKET="$PSOCK" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" "ai/codex/todo-pathtest" '~/programming' "$X_LINKED" codex)" || fail "ai-todo-open via nvm codex failed: $out"
for _ in $(seq 1 50); do [[ -s "$NODE_LOG" ]] && break; sleep 0.1; done
tmux -L "$PSOCK" kill-server >/dev/null 2>&1 || true
grep -q "resume ${X_LINKED}" "$NODE_LOG" 2>/dev/null || fail "npm-installed codex couldn't find node inside an existing tmux server"
pass "ai-todo-open passes the resolved PATH into new tmux sessions (nvm codex works with a running tmux server)"

# Nested launches passed PATH on with the tool directories prepended again each time, and
# on macOS every command lookup that reached a /home entry was an automount. The session
# gets each directory once, the tool directories first, and nothing under /home on macOS.
PATH_LOG="${SANDBOX}/session-path.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$PATH" >"%s"\nexec sleep 300\n' "$PATH_LOG" >"${SANDBOX}/path-claude"
chmod +x "${SANDBOX}/path-claude"
TMUX_DIR="$(dirname "$(command -v tmux)")"
DUP_PATH="/usr/bin:/bin:${TMUX_DIR}:/usr/local/bin:${TMUX_DIR}:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin"
out="$(env PATH="$DUP_PATH" AI_TODO_CLAUDE_BIN="${SANDBOX}/path-claude" AI_TODO_TMUX_SOCKET="$PSOCK" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" "ai/claude/todo-pathdup" '~/programming' "77777777-1111-4222-8333-444444444444" claude)" \
  || fail "ai-todo-open with a repeated PATH failed: $out"
for _ in $(seq 1 50); do [[ -s "$PATH_LOG" ]] && break; sleep 0.1; done
tmux -L "$PSOCK" kill-server >/dev/null 2>&1 || true
python3 - "$PATH_LOG" "$(uname)" <<'PY' || fail "session PATH: $(cat "$PATH_LOG" 2>/dev/null)"
import sys
dirs = open(sys.argv[1]).read().strip().split(":")
assert len(dirs) == len(set(dirs)), dirs
assert dirs[0] == "/opt/homebrew/bin", dirs
assert "/usr/bin" in dirs and "/bin" in dirs, dirs
if sys.argv[2] == "Darwin":
    assert not any(d.startswith("/home/") for d in dirs), dirs
PY
pass "ai-todo-open gives the session each PATH directory once, and nothing under /home on macOS"

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
# When this file exists, the next post is answered 404 (and the file removed): a session id
# the hub doesn't know yet.
not_found_once = os.path.join(os.path.dirname(log_path), "not-found-once")

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
        if os.path.exists(not_found_once):
            os.remove(not_found_once)
            self.send_response(404)
            self.end_headers()
            return
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
assert isinstance(req["body"].pop("event_timestamp_ns"), int)
assert req["body"] == {"tool":"claude", "session_id": sys.argv[2], "status": "waiting", "attended": False,
                       "message": 'Claude needs your "permission"'}, req
PY
pass "hook posts status + message with the bearer token"

printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle
[[ $(wc -l <"$HUB_LOG") -eq 2 ]] || fail "idle hook did not post"
python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; assert isinstance(b.pop("event_timestamp_ns"),int); assert b=={"tool":"claude","session_id":sys.argv[2],"status":"idle","attended":False}, b' "$HUB_LOG" "$SID" \
  || fail "idle hook body wrong"
pass "hook posts idle without a message"

printf 'not json' | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" busy
printf '{"session_id":"%s"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" bogus
printf '{"session_id":"%s"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" seed
[[ $(wc -l <"$HUB_LOG") -eq 2 ]] || fail "hook posted for bad input or a bad status"
pass "hook ignores invalid JSON, unknown statuses and seed without an id"

# Turns of a background job (`claude attach`) run their hooks outside the todo's tmux
# session: report them by id anyway, unattended unless a todo pane shows the conversation.
OUTSIDE_SID="4bb0448b-c814-41b3-a216-32cc0d398499"
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$OUTSIDE_SID" | env -u TMUX -u AI_TODO_TMUX_SESSION "$HOOK" idle
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$OUTSIDE_SID" | AI_TODO_TMUX_SESSION="ai/claude/sigma-revenue" "$HOOK" idle
[[ $(wc -l <"$HUB_LOG") -eq 4 ]] || fail "hook did not post outside a todo session"
python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; assert isinstance(b.pop("event_timestamp_ns"),int); assert b=={"tool":"claude","session_id":sys.argv[2],"status":"idle","attended":False}, b' "$HUB_LOG" "$OUTSIDE_SID" \
  || fail "outside-tmux body wrong: $(tail -1 "$HUB_LOG")"
pass "hook reports conversations outside a todo tmux session by id, unattended"

last_status() {
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]["status"])' "$HUB_LOG"
}
printf '{"session_id":"%s","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
[[ $(wc -l <"$HUB_LOG") -eq 5 && "$(last_status)" == idle ]] || fail "idle notification was not reported as idle: $(tail -1 "$HUB_LOG")"
pass "the idle notification is reported as idle, not waiting"

tool() { printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$SID" | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" tool; }
tool
[[ $(wc -l <"$HUB_LOG") -eq 6 && "$(last_status)" == busy ]] || fail "first tool call after idle did not post busy"
tool
tool
[[ $(wc -l <"$HUB_LOG") -eq 6 ]] || fail "repeated tool calls posted busy again"
printf '{"session_id":"%s","hook_event_name":"Notification","message":"Claude needs your permission"}' "$SID" \
  | AI_TODO_TMUX_SESSION="$NAME" "$HOOK" waiting
tool
[[ $(wc -l <"$HUB_LOG") -eq 8 && "$(last_status)" == busy ]] || fail "tool call after a permission prompt did not post busy"
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

# A todo pane running `claude attach <id[:8]>` (or `--resume <id>`) is the session for
# "attended", even though the job's hook runs outside it.
ATTACH_NAME="ai/claude/todo-a77ac4ed"
tmux -L "$SOCK" new-session -d -s "$ATTACH_NAME" -- /bin/sh -c "exec -a 'claude attach ${OUTSIDE_SID:0:8}' sleep 60" \
  || fail "could not start the attach pane"
sleep 0.3
ps -o args= -p "$(tmux -L "$SOCK" list-panes -t "=$ATTACH_NAME" -F '#{pane_pid}')" | grep -q "attach ${OUTSIDE_SID:0:8}" \
  || fail "the attach pane does not show its argv: $(ps -o args= -p "$(tmux -L "$SOCK" list-panes -t "=$ATTACH_NAME" -F '#{pane_pid}')")"
date +%s >"$ACTIVITY"
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$OUTSIDE_SID" \
  | env -u TMUX -u AI_TODO_TMUX_SESSION AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" "$HOOK" idle
[[ "$(last_attended)" == True ]] || fail "attended was not found through the attach pane: $(tail -1 "$HUB_LOG")"
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" \
  | env -u TMUX -u AI_TODO_TMUX_SESSION AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" "$HOOK" idle
[[ "$(last_attended)" == False ]] || fail "another conversation counted as attended through the attach pane"
tmux -L "$SOCK" kill-session -t "=$ATTACH_NAME"
pass "hook finds the todo tmux session whose pane attaches the job, for attended"

# seed: the background job's state, attended (whoever seeds is opening it).
JOBS="${SANDBOX}/claude-jobs"
mkdir -p "${JOBS}/${OUTSIDE_SID:0:8}"
job_state() { # <state> <tempo> [transcript name]
  printf '{"state":"%s","tempo":"%s","linkScanPath":"/p/%s"}' "$1" "$2" "${3:-${OUTSIDE_SID}.jsonl}" >"${JOBS}/${OUTSIDE_SID:0:8}/state.json"
}
seed() { AI_TODO_CLAUDE_JOBS="$JOBS" "$HOOK" seed "$OUTSIDE_SID" </dev/null; }
before=$(wc -l <"$HUB_LOG")
job_state working active; seed
[[ "$(last_status)" == busy && "$(last_attended)" == True ]] || fail "working job not seeded busy: $(tail -1 "$HUB_LOG")"
job_state blocked active; seed
[[ "$(last_status)" == busy ]] || fail "an active job not seeded busy"
job_state blocked blocked; seed
[[ "$(last_status)" == idle ]] || fail "a blocked job not seeded idle"
job_state done idle; seed
[[ "$(last_status)" == idle && $(wc -l <"$HUB_LOG") -eq $((before + 4)) ]] || fail "done job not seeded idle"
job_state working active "someone-else.jsonl"; seed
AI_TODO_CLAUDE_JOBS="$JOBS" "$HOOK" seed "11111111-0000-4000-8000-000000000000" </dev/null
[[ $(wc -l <"$HUB_LOG") -eq $((before + 4)) ]] || fail "seed posted for another conversation's job or no job"
pass "seed posts a background job's state (busy while active or working, else idle), attended, only for its own job"

# ai-todo-open seeds a Claude todo's job state when it opens it, in the background.
SEED_LOG="${SANDBOX}/seed.log"
printf '#!/bin/sh\necho "$*" >>"%s"\n' "$SEED_LOG" >"${SANDBOX}/fake-seed-hook"
chmod +x "${SANDBOX}/fake-seed-hook"
seed_open() { # <sid>: open $NAME (already running, so it attaches) with that id
  AI_TODO_OPEN_DETACH=1 AI_TODO_CLAUDE_JOBS="$JOBS" AI_TODO_HOOK_BIN="${SANDBOX}/fake-seed-hook" "$OPEN" "$NAME" '~/programming' "$1" >/dev/null
}
tmux -L "$SOCK" has-session -t "=$NAME" || fail "$NAME should still be running here"
seed_open "$OUTSIDE_SID"
seed_open "$SID"
for _ in $(seq 1 20); do [[ -s "$SEED_LOG" ]] && break; sleep 0.1; done
sleep 0.2
[[ "$(cat "$SEED_LOG")" == "seed ${OUTSIDE_SID}" ]] || fail "ai-todo-open seeded wrong: $(cat "$SEED_LOG" 2>/dev/null)"
pass "ai-todo-open seeds the status of a Claude todo that is a background job, and only that"

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
assert isinstance(req["body"].pop("event_timestamp_ns"), int), req
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
env -u TMUX -u AI_TODO_TMUX_SESSION "$NOTIFY" "$TURN"
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) && "$(last_attended)" == False ]] \
  || fail "codex notify did not report a thread outside a todo session: $(tail -1 "$HUB_LOG")"
pass "codex notify reports threads outside a todo tmux session (desktop app, shared app-server) by id"

# The shared app-server's tmux environment is another todo's: the pane running
# `codex resume <thread-id>` decides attended, not $TMUX.
RESUME_NAME="ai/codex/todo-5e5e5e5e"
tmux -L "$SOCK" new-session -d -s "$RESUME_NAME" -- /bin/sh -c "exec -a 'codex resume ${X_LINKED}' sleep 60" \
  || fail "could not start the resume pane"
sleep 0.3
date +%s >"$ACTIVITY"
env -u TMUX -u AI_TODO_TMUX_SESSION AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" "$NOTIFY" "$TURN"
[[ "$(last_attended)" == True ]] || fail "codex attended was not found through the resume pane: $(tail -1 "$HUB_LOG")"
tmux -L "$SOCK" kill-session -t "=$RESUME_NAME"
pass "codex notify finds the todo tmux session whose pane resumes the thread, for attended"

before=$(wc -l <"$HUB_LOG")
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" '{"type":"something-else","thread-id":"x"}'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" 'not json'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" '{"type":"agent-turn-complete","thread-id":"../../etc"}'
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY"
[[ $(wc -l <"$HUB_LOG") -eq $before ]] || fail "codex notify posted for a non-todo session or bad payload"
pass "codex notify ignores other events, bad JSON and bad ids"

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

# Stop -> ai-todo-memory trigger (detached), via a fake ai-todo-memory that records its argv.
printf "TODO_HUB_URL='%s'\nTODO_API_TOKEN='s3cret'\n" "$HUB_URL" >"$CONF"
FAKE_MEMORY="${SANDBOX}/bin/fake-ai-todo-memory"
MEMORY_TRIGGERS="${SANDBOX}/memory-triggers.log"
printf '#!/bin/sh\necho "$*" >>"%s"\nsleep 5\n' "$MEMORY_TRIGGERS" >"$FAKE_MEMORY"
chmod +x "$FAKE_MEMORY"
posts=$(wc -l <"$HUB_LOG")
printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" | AI_TODO_MEMORY_RUN=1 AI_TODO_MEMORY_BIN="$FAKE_MEMORY" AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle
sleep 0.3
[[ $(wc -l <"$HUB_LOG") -eq $posts && ! -e "$MEMORY_TRIGGERS" ]] || fail "hook did something under AI_TODO_MEMORY_RUN"
pass "hook_noop_under_memory_run: no status post and no trigger inside ai-todo-memory's own claude run"

start=$(python3 -c 'import time; print(time.time())')
printf '{"session_id":"%s","transcript_path":"/x/p q/%s.jsonl","hook_event_name":"Stop"}' "$SID" "$SID" \
  | AI_TODO_MEMORY_BIN="$FAKE_MEMORY" AI_TODO_TMUX_SESSION="ai/claude/sigma-revenue" "$HOOK" idle
# The fake ai-todo-memory sleeps 5 s: returning well before that means it runs detached.
python3 -c 'import sys, time; sys.exit(0 if time.time() - float(sys.argv[1]) < 4 else 1)' "$start" || fail "the hook waited for ai-todo-memory"
for _ in $(seq 1 30); do [[ -s "$MEMORY_TRIGGERS" ]] && break; sleep 0.1; done
[[ "$(cat "$MEMORY_TRIGGERS")" == "trigger claude ${SID} --transcript /x/p q/${SID}.jsonl" ]] || fail "trigger argv wrong: $(cat "$MEMORY_TRIGGERS" 2>/dev/null)"
[[ $(wc -l <"$HUB_LOG") -eq $((posts + 1)) ]] || fail "a non-todo session did not post status"
for st in waiting busy tool; do
  printf '{"session_id":"%s","transcript_path":"/x/y.jsonl"}' "$SID" | AI_TODO_MEMORY_BIN="$FAKE_MEMORY" AI_TODO_TMUX_SESSION="$NAME" "$HOOK" "$st"
done
printf '{"session_id":"%s"}' "$SID" | AI_TODO_MEMORY_BIN="$FAKE_MEMORY" AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle
sleep 0.5
[[ "$(wc -l <"$MEMORY_TRIGGERS" | tr -d ' ')" == 2 && "$(tail -n 1 "$MEMORY_TRIGGERS")" == "trigger claude ${SID}" ]] \
  || fail "only idle should trigger (no --transcript when the hook gives none): $(cat "$MEMORY_TRIGGERS")"
pass "hook_idle_triggers_memory_detached: Stop starts 'ai-todo-memory trigger claude <sid> --transcript <path>' in the background for any session; waiting/busy/tool don't"

posts=$(wc -l <"$HUB_LOG")
printf '{"session_id":"%s"}' "$SID" | AI_TODO_MEMORY_BIN="${SANDBOX}/nonexistent/ai-todo-memory" AI_TODO_TMUX_SESSION="$NAME" "$HOOK" idle \
  || fail "hook failed without ai-todo-memory"
[[ $(wc -l <"$HUB_LOG") -eq $((posts + 1)) && "$(last_status)" == idle ]] || fail "hook without ai-todo-memory did not post idle"
pass "hook_without_memory_binary_still_posts_status (and a todo-hub.conf without TODO_COMPUTER_ID)"

# --- ai-todo-hook --codex (Codex 0.163+ hooks: same JSON as Claude's) -------------------

codex_hook() { # <status> <event> [extra json fields]: one Codex hook call for X_LINKED
  printf '{"session_id":"%s","turn_id":"t1","hook_event_name":"%s"%s}' "$X_LINKED" "$2" "${3:-}" \
    | AI_TODO_MEMORY_BIN="$FAKE_MEMORY" AI_TODO_TMUX_SESSION="$XTMUX" "$HOOK" --codex "$1"
}
last_body() { python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; b.pop("event_timestamp_ns", None); b.pop("turn_started_ns", None); print(json.dumps(b, sort_keys=True))' "$HUB_LOG"; }
: >"$MEMORY_TRIGGERS"
before=$(wc -l <"$HUB_LOG")
codex_hook busy UserPromptSubmit ',"prompt":"go"'
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) ]] || fail "codex busy hook did not post"
[[ "$(last_body)" == "{\"attended\": false, \"session_id\": \"${X_LINKED}\", \"status\": \"busy\", \"tool\": \"codex\"}" ]] \
  || fail "codex busy body wrong: $(last_body)"
codex_hook waiting PermissionRequest ',"tool_name":"Bash","tool_input":{"command":"rm -rf x"}'
python3 -c 'import json,sys; b=json.loads(open(sys.argv[1]).read().splitlines()[-1])["body"]; assert isinstance(b.pop("event_timestamp_ns"),int); assert isinstance(b.pop("turn_started_ns"),int); assert b=={"session_id":sys.argv[2],"tool":"codex","status":"waiting","attended":False,"message":"Codex needs your permission to use Bash"}, b' "$HUB_LOG" "$X_LINKED" \
  || fail "codex waiting body wrong: $(last_body)"
codex_hook idle Stop ',"last_assistant_message":"done","stop_hook_active":false'
[[ "$(last_status)" == idle ]] || fail "codex Stop did not post idle"
sleep 0.3
[[ ! -s "$MEMORY_TRIGGERS" ]] || fail "a codex Stop started ai-todo-memory: $(cat "$MEMORY_TRIGGERS")"
pass "hook --codex posts busy / waiting (naming the tool) / idle as session_id + tool=codex, without a memory run"

# notify's idle and the hook's tool share one state file: a PostToolUse after notify's idle
# posts busy again, and a second one doesn't.
AI_TODO_TMUX_SESSION="$XTMUX" "$NOTIFY" "$TURN"
before=$(wc -l <"$HUB_LOG")
codex_hook tool PostToolUse ',"tool_name":"Bash"'
codex_hook tool PostToolUse ',"tool_name":"Bash"'
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) && "$(last_status)" == busy ]] || fail "codex tool posts wrong: $(tail -2 "$HUB_LOG")"
pass "hook --codex tool posts busy once after notify's idle (shared hook-state/codex-<id>)"

# A rejected delivery must not make the next tool event skip busy. The hook itself waits
# for HTTP, even without the synchronous re-check test flag.
codex_hook idle Stop
: >"${SANDBOX}/not-found-once"
before=$(wc -l <"$HUB_LOG")
codex_hook tool PreToolUse
codex_hook tool PostToolUse
codex_hook tool PostToolUse
[[ $(wc -l <"$HUB_LOG") -eq $((before + 2)) ]] || fail "failed busy delivery was not retried exactly once"
codex_hook idle Interrupt
[[ "$(last_status)" == idle ]] || fail "Codex interruption did not clear working"
before=$(wc -l <"$HUB_LOG")
printf '{"session_id":"%s"}' "$X_LINKED" | env -u AI_TODO_HOOK_SYNC AI_TODO_TMUX_SESSION="$XTMUX" "$HOOK" --codex busy
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) && "$(last_status)" == busy ]] || fail "hook returned before delivery finished"
pass "status delivery finishes before hook exit, retries after HTTP errors, and clears interrupted turns"

before=$(wc -l <"$HUB_LOG")
printf '{"session_id":"%s"}' "$X_LINKED" | AI_TODO_TMUX_SESSION="ai/claude/todo-0f3a9c21" "$HOOK" --codex idle
[[ $(wc -l <"$HUB_LOG") -eq $((before + 1)) && "$(last_attended)" == False ]] || fail "codex hook in a claude todo session: $(tail -1 "$HUB_LOG")"
tmux -L "$SOCK" new-session -d -s "$RESUME_NAME" -- /bin/sh -c "exec -a 'codex resume ${X_LINKED}' sleep 60" \
  || fail "could not start the resume pane"
sleep 0.3
date +%s >"$ACTIVITY"
printf '{"session_id":"%s"}' "$X_LINKED" | env -u TMUX -u AI_TODO_TMUX_SESSION AI_TODO_CLIENT_ACTIVITY_FILE="$ACTIVITY" "$HOOK" --codex busy
[[ "$(last_status)" == busy && "$(last_attended)" == True ]] || fail "codex hook attended not found through the resume pane: $(tail -1 "$HUB_LOG")"
tmux -L "$SOCK" kill-session -t "=$RESUME_NAME"
before=$(wc -l <"$HUB_LOG")
printf '{"session_id":"%s"}' "$X_LINKED" | "$HOOK" --codex seed "$X_LINKED"
printf '{"session_id":"%s"}' "$X_LINKED" | "$HOOK" --codex bogus
[[ $(wc -l <"$HUB_LOG") -eq $before ]] || fail "hook --codex posted for seed or a bad status"
pass "hook --codex finds attended through the codex resume pane only, and ignores seed and bad statuses"
unset AI_TODO_HUB_CONF AI_TODO_HOOK_SYNC
# The hook keeps per-session state under ~/.ai-remote; start the install tests clean.
rm -rf "${HOME}/.ai-remote"

# --- ai_todo_redact.py ------------------------------------------------------------

FIXTURES="${SCRIPT_DIR}/fixtures"
[[ -f "${SCRIPT_DIR}/ai_todo_redact.py" ]] || fail "ai_todo_redact.py is missing"

# Runs python with the redaction module importable; the fixture's local secret is in the env.
redact_py() { MY_SERVICE_TOKEN=LocalTok3n_Value9 python3 - "$SCRIPT_DIR" "${FIXTURES}/secrets.txt" "$@"; }

redact_py <<'PY' || fail "redaction rules"
import os, sys
sys.path.insert(0, sys.argv[1])
import ai_todo_redact as r
secrets = r.secret_values_from_env(os.environ)
seen = set()
for line in open(sys.argv[2], encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    kind, text, raw = [p.strip() for p in line.rstrip("\n").split(" ::: ")]
    text = text.replace("@@", "").replace("\\n", "\n")
    if kind == "keep":
        continue
    out = r.redact(text, secrets)
    assert f"[REDACTED:{kind}]" in out, (kind, out)
    assert raw not in out, (kind, out)
    seen.add(kind)
want = {"private_key", "anthropic_key", "openai_key", "github_token", "gitlab_token", "slack_token",
        "aws_key", "google_key", "stripe_key", "jwt", "bearer", "url_credentials", "secret",
        "local_secret", "random", "cli_credentials", "cli_secret", "basic_auth", "auth_token"}
assert seen == want, want ^ seen
PY
pass "redaction replaces each rule's sample with [REDACTED:<type>] (PEM, prefixed tokens, JWT, bearer, URL credentials, key/value, local secrets, random strings)"

redact_py <<'PY' || fail "redaction exceptions"
import os, sys
sys.path.insert(0, sys.argv[1])
import ai_todo_redact as r
secrets = r.secret_values_from_env(os.environ)
for line in open(sys.argv[2], encoding="utf-8"):
    if line.startswith("keep ::: "):
        text = line.rstrip("\n").split(" ::: ")[1]
        assert r.redact(text, secrets) == text, (text, r.redact(text, secrets))
PY
pass "redaction_exceptions: 40-hex git SHAs, UUIDs, branch names, paths and prose mentioning tokens stay unchanged"

redact_py <<'PY' || fail "redaction mangled unicode"
import sys
sys.path.insert(0, sys.argv[1])
import ai_todo_redact as r
text = "Ключът е ghp_" + "Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0Pp9Oo8 🔑 — не го споделяй; password=парола123 ✅"
out = r.redact(text, [])
assert out == "Ключът е [REDACTED:github_token] 🔑 — не го споделяй; password=[REDACTED:secret] ✅", out
plain = "Деплойът чака билда 🚀 — 日本語 ok"
assert r.redact(plain, []) == plain
PY
pass "redaction_keeps_unicode: Cyrillic, CJK and emoji survive around redacted values"

redact_py <<'PY' || fail "key/value redaction"
import sys
sys.path.insert(0, sys.argv[1])
import ai_todo_redact as r
assert r.redact("password=hunter2", []) == "password=[REDACTED:secret]", r.redact("password=hunter2", [])
assert r.redact("TODO_API_TOKEN='abc'", []) == "TODO_API_TOKEN=[REDACTED:secret]", r.redact("TODO_API_TOKEN='abc'", [])
assert r.redact("api_key=sk-ant-" + "Xy7Kp2Lm9Qr4St6Uv8Wx", []) == "api_key=[REDACTED:anthropic_key]"
env = {"TODO_API_TOKEN": "hub-token-123", "MY_KEY": "short", "PATH": "/usr/bin:/bin", "X_SECRET": "abcdefgh12"}
assert sorted(r.secret_values_from_env(env)) == ["abcdefgh12", "hub-token-123"], r.secret_values_from_env(env)
assert r.redact("x hub-token-123 y", ["hub-token-123"]) == "x [REDACTED:local_secret] y"
PY
pass "key_value_keeps_key: password=hunter2 -> password=[REDACTED:secret]; env secrets are collected by name"

redact_py <<'PY' || fail "redaction shapes"
import sys
sys.path.insert(0, sys.argv[1])
import ai_todo_redact as r
cases = {
    "postgres://app:pa/ss@w0rd@db.example.com/prod": "postgres://[REDACTED:url_credentials]@db.example.com/prod",
    "redis://:s3cr3tPw@cache:6379": "redis://[REDACTED:url_credentials]@cache:6379",
    'x {"password": "a b c", "user": "me"}': 'x {"password": [REDACTED:secret], "user": "me"}',
    "curl -u admin:pw12345x https://h": "curl -u [REDACTED:cli_credentials] https://h",
    "Authorization: Basic YWRtaW46aHVudGVyMg==": "Authorization: Basic [REDACTED:basic_auth]",
    "authorization: token 3f786850e387550fdab836ed7e6dc881de23001b": "authorization: token [REDACTED:auth_token]",
    "x --password=hunter3pw --token tok123456 y": "x --password=[REDACTED:cli_secret] --token [REDACTED:cli_secret] y",
    "mysql -h db -uroot -pS3cretPw shop": "mysql -h db -uroot -p[REDACTED:cli_secret] shop",
    "mysql -uroot -p shop": "mysql -uroot -p shop",
    "sshpass -p 'Pa55word' ssh h": "sshpass -p [REDACTED:cli_secret] ssh h",
    "Bearer 3f786850e387550fdab836ed7e6dc881de23001b": "Bearer [REDACTED:bearer]",
}
for raw, want in cases.items():
    assert r.redact(raw, []) == want, (raw, r.redact(raw, []))
PY
pass "redaction shapes: URL credentials up to the last @ (empty user, / and @ in the password), quoted key/value values, curl -u, Authorization Basic/Token, --password/--token, mysql -p<v>, sshpass -p"

# --- ai-todo-sessions stats ---------------------------------------------------------

export GIT_CONFIG_NOSYSTEM=1
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
SHOME="${SANDBOX}/shome"
S_CLAUDE=c0ffee00-0000-4000-8000-000000000001
S_CODEX=019f0000-0000-7000-8000-0000000000c1
S_CWD="${SHOME}/work/app"
S_PROJ="${SHOME}/.claude/projects/-work-app"
S_CODEX_DAY="${SHOME}/.codex/sessions/2026/10/15"
mkdir -p "$S_PROJ" "$S_CODEX_DAY" "$S_CWD"
fixture() { # <fixture file> <destination> <session id> <cwd> [home]
  sed -e "s#@CWD@#$4#g" -e "s#@HOME@#${5:-$SHOME}#g" -e "s#@SID@#$3#g" "${FIXTURES}/$1" >"$2"
}
mini_claude() { # <path> <session id> <cwd> <prompt>: one complete turn
  printf '{"type":"user","uuid":"%s-u","cwd":"%s","timestamp":"2026-10-15T08:00:00.000Z","message":{"role":"user","content":"%s"}}\n' "$2" "$3" "$4" >"$1"
  printf '{"type":"assistant","uuid":"%s-a","cwd":"%s","timestamp":"2026-10-15T08:00:05.000Z","message":{"id":"m-%s","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}}\n' "$2" "$3" "$2" >>"$1"
}
fixture claude-stats.jsonl "${S_PROJ}/${S_CLAUDE}.jsonl" "$S_CLAUDE" "$S_CWD"
fixture codex-stats.jsonl "${S_CODEX_DAY}/rollout-2026-10-15T09-59-59-${S_CODEX}.jsonl" "$S_CODEX" "$S_CWD"
stats() { HOME="$SHOME" AI_TODO_TZ=Europe/Sofia AI_TODO_HUB_CONF="${SANDBOX}/none.conf" "$SESSIONS" stats --json "$@"; }

stats --session "claude:${S_CLAUDE}" >"${SANDBOX}/stats-claude.json" || fail "stats --json failed"
python3 - "${SANDBOX}/stats-claude.json" "$S_CLAUDE" <<'PY' || fail "claude stats wrong: $(cat "${SANDBOX}/stats-claude.json")"
import json, sys
rows = json.load(open(sys.argv[1]))
assert len(rows) == 1, rows
s = rows[0]
assert list(s) == ["tool", "session_id", "cwd", "title", "repo_root", "repo_url", "stats", "days"], list(s)
assert (s["tool"], s["session_id"], s["cwd"], s["title"]) == ("claude", sys.argv[2], "~/work/app", "Add the parser please"), s
assert s["repo_root"] is None and s["repo_url"] is None, s
assert s["stats"] == {
    "prompts": 3, "assistant_turns": 3, "input_tokens": 127, "output_tokens": 210,
    "cache_read_tokens": 17200, "cache_creation_tokens": 350, "active_seconds": 300,
    "first_activity": "2026-10-15T09:00:00Z", "last_activity": "2026-10-15T22:32:00Z",
    "files_touched": ["src/parser.py", "src/config.py", "~/other/notes.md"],
    "models": ["claude-opus-5-5", "claude-sonnet-5"]}, s["stats"]
assert s["days"] == [
    {"day": "2026-10-15", "prompts": 2, "assistant_turns": 2, "input_tokens": 122, "output_tokens": 140,
     "cache_read_tokens": 9100, "cache_creation_tokens": 300, "active_seconds": 180, "files_touched": 3},
    {"day": "2026-10-16", "prompts": 1, "assistant_turns": 1, "input_tokens": 5, "output_tokens": 70,
     "cache_read_tokens": 8100, "cache_creation_tokens": 50, "active_seconds": 120, "files_touched": 1}], s["days"]
PY
pass "stats_claude_numbers: prompts, end_turn turns, usage once per message.id, 10-min active gaps, local-day split, files, models; sidechains skipped"

stats --session "codex:${S_CODEX}" >"${SANDBOX}/stats-codex.json" || fail "codex stats failed"
python3 - "${SANDBOX}/stats-codex.json" "$S_CODEX" <<'PY' || fail "codex stats wrong: $(cat "${SANDBOX}/stats-codex.json")"
import json, sys
s = json.load(open(sys.argv[1]))[0]
assert (s["tool"], s["session_id"], s["cwd"], s["title"]) == ("codex", sys.argv[2], "~/work/app", "Refactor the module"), s
assert s["stats"] == {
    "prompts": 2, "assistant_turns": 2, "input_tokens": 1500, "output_tokens": 450,
    "cache_read_tokens": 2500, "cache_creation_tokens": None, "active_seconds": 50,
    "first_activity": "2026-10-15T10:00:00Z", "last_activity": "2026-10-15T23:00:20Z",
    "files_touched": ["src/new.py", "src/old.py", "src/gone.py"], "models": ["gpt-5.5-codex"]}, s["stats"]
assert s["days"] == [
    {"day": "2026-10-15", "prompts": 1, "assistant_turns": 1, "input_tokens": 1000, "output_tokens": 300,
     "cache_read_tokens": 1500, "cache_creation_tokens": None, "active_seconds": 30, "files_touched": 3},
    {"day": "2026-10-16", "prompts": 1, "assistant_turns": 1, "input_tokens": 500, "output_tokens": 150,
     "cache_read_tokens": 1000, "cache_creation_tokens": None, "active_seconds": 20, "files_touched": 0}], s["days"]
PY
pass "stats_codex_numbers: cumulative token_count turned into per-day deltas, task_complete turns, apply_patch files, no cache-creation figure"

[[ "$(stats | python3 -c 'import json,sys; print(sorted(r["tool"] for r in json.load(sys.stdin)))')" == "['claude', 'codex']" ]] \
  || fail "stats --since default did not pick up both recent transcripts"
touch -t "$OLD" "${S_PROJ}/${S_CLAUDE}.jsonl"
[[ "$(stats --since 2 | python3 -c 'import json,sys; print([r["tool"] for r in json.load(sys.stdin)])')" == "['codex']" ]] \
  || fail "stats --since included a transcript not changed in that window"
[[ "$(stats --since 100000 --tool claude | python3 -c 'import json,sys; print([r["tool"] for r in json.load(sys.stdin)])')" == "['claude']" ]] \
  || fail "stats --tool claude wrong"
if stats --session "claude:../x" >/dev/null 2>&1; then fail "stats accepted a bad --session"; else [[ $? -eq 64 ]] || fail "bad --session should exit 64"; fi
pass "stats scope: --since DAYS by transcript mtime (default 1), --tool, --session tool:id validated"

REPO="${SHOME}/work/repo"
mkdir -p "$REPO"
git_q -C "$REPO" init
git_q -C "$REPO" commit --allow-empty -m init
git_q -C "$REPO" remote add origin "https://deploy:Sup3rPass@example.com/team/repo.git"
git_q -C "$REPO" worktree add "${REPO}/.claude/worktrees/w"
R_WT=c0ffee00-0000-4000-8000-000000000002
R_GONE=c0ffee00-0000-4000-8000-000000000003
R_RMWT=c0ffee00-0000-4000-8000-000000000008
mini_claude "${S_PROJ}/${R_WT}.jsonl" "$R_WT" "${REPO}/.claude/worktrees/w" "work in the worktree"
mini_claude "${S_PROJ}/${R_GONE}.jsonl" "$R_GONE" "${SHOME}/work/gone" "work in a deleted folder"
mini_claude "${S_PROJ}/${R_RMWT}.jsonl" "$R_RMWT" "${REPO}/.claude/worktrees/removed" "work in a worktree removed since"
stats --session "claude:${R_WT}" --session "claude:${R_GONE}" --session "claude:${R_RMWT}" >"${SANDBOX}/stats-repo.json"
python3 - "${SANDBOX}/stats-repo.json" "$R_WT" "$R_GONE" "$R_RMWT" <<'PY' || fail "repo fields wrong: $(cat "${SANDBOX}/stats-repo.json")"
import json, sys
rows = {r["session_id"]: r for r in json.load(open(sys.argv[1]))}
wt, gone = rows[sys.argv[2]], rows[sys.argv[3]]
assert wt["cwd"] == "~/work/repo/.claude/worktrees/w", wt
assert wt["repo_root"] == "~/work/repo", wt
assert wt["repo_url"] == "https://example.com/team/repo.git", wt
assert gone["repo_root"] is None and gone["repo_url"] is None, gone
removed = rows[sys.argv[4]]
assert (removed["cwd"], removed["repo_root"], removed["repo_url"]) == (
    "~/work/repo/.claude/worktrees/removed", "~/work/repo", "https://example.com/team/repo.git"), removed
PY
pass "stats_repo_fields: a worktree resolves to the main repo (with ~), origin credentials stripped, a removed worktree resolves through its parent, a missing cwd outside any repo gives nulls"

# Sessions are often started in a parent folder and then work in a repo below it.
S_MOVED=c0ffee00-0000-4000-8000-000000000006
S_DIP=c0ffee00-0000-4000-8000-000000000007
mkdir -p "${SHOME}/work/app/sub"
python3 "${FIXTURES}/transcript.py" claude "${S_PROJ}/${S_MOVED}.jsonl" "${SHOME}/work" "$S_MOVED" --turn "start in the parent" "ok"
python3 "${FIXTURES}/transcript.py" claude "${S_PROJ}/${S_MOVED}.jsonl" "${SHOME}/work/app" "$S_MOVED" \
  --turn "work in the repo 1" "ok" --turn "work in the repo 2" "ok" --turn "work in the repo 3" "ok"
python3 "${FIXTURES}/transcript.py" claude "${S_PROJ}/${S_DIP}.jsonl" "${SHOME}/work/app" "$S_DIP" \
  --turn "a1" "ok" --turn "a2" "ok" --turn "a3" "ok" --turn "a4" "ok" --turn "a5" "ok"
python3 "${FIXTURES}/transcript.py" claude "${S_PROJ}/${S_DIP}.jsonl" "${SHOME}/work/app/sub" "$S_DIP" --turn "quick look below" "ok"
stats --session "claude:${S_MOVED}" --session "claude:${S_DIP}" >"${SANDBOX}/stats-moved.json" || fail "stats for moved sessions failed"
python3 - "${SANDBOX}/stats-moved.json" "$S_MOVED" "$S_DIP" <<'PY2' || fail "effective cwd wrong: $(cat "${SANDBOX}/stats-moved.json")"
import json, sys
rows = {r["session_id"]: r["cwd"] for r in json.load(open(sys.argv[1]))}
assert rows == {sys.argv[2]: "~/work/app", sys.argv[3]: "~/work/app"}, rows
PY2
pass "stats_effective_cwd: a session started in a parent folder counts for the repo it worked in; a brief dip into a subfolder doesn't move it"

R_SECRET=c0ffee00-0000-4000-8000-000000000004
printf "TODO_HUB_URL='http://127.0.0.1:9'\nTODO_API_TOKEN='conf-secret-token-1'\n" >"${SANDBOX}/stats-hub.conf"
mini_claude "${S_PROJ}/${R_SECRET}.jsonl" "$R_SECRET" "$S_CWD" "deploy with password=hunter2xyz via conf-secret-token-1 and ghp_""A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8 then write a very long explanation of everything that happened so far in this project"
HOME="$SHOME" AI_TODO_HUB_CONF="${SANDBOX}/stats-hub.conf" "$SESSIONS" stats --json --session "claude:${R_SECRET}" >"${SANDBOX}/stats-title.json"
python3 - "${SANDBOX}/stats-title.json" <<'PY' || fail "title not redacted: $(cat "${SANDBOX}/stats-title.json")"
import json, sys
t = json.load(open(sys.argv[1]))[0]["title"]
assert t.startswith("deploy with password=[REDACTED:secret] via [REDACTED:local_secret] and [REDACTED:github_token] then"), t
assert "hunter2xyz" not in t and "conf-secret-token-1" not in t and "ghp_" not in t, t
assert len(t) == 120, len(t)
PY
pass "stats_title_redacted: the title is the first prompt, redacted (incl. the hub token from todo-hub.conf), then cut to 120 chars"

# --- ai-todo-memory: extraction ---------------------------------------------------------
# Own HOME (restored after the memory sections), a stateful fake hub, the fake claude.

MEMORY="${SCRIPT_DIR}/ai-todo-memory"
TRANSCRIPT="${FIXTURES}/transcript.py"
SAVED_HOME=$HOME
export HOME="${SANDBOX}/mhome"
M_STATE="${HOME}/.ai-remote/memory-state"
M_APP="${HOME}/work/app"
M_PROJ_DIR="${HOME}/.claude/projects/-work-app"
M_HUB_STATE="${SANDBOX}/mhub-state.json"
M_HUB_LOG="${SANDBOX}/mhub.log"
M_CLAUDE_LOG="${SANDBOX}/mclaude"
M_CONF="${SANDBOX}/mhub.conf"
M_REPLY="${FIXTURES}/claude-reply.json"
M_USER="${USER:-$(id -un)}"
mkdir -p "$M_APP" "${HOME}/work/elsewhere" "$M_PROJ_DIR"

hub_reset() {
  cat >"$M_HUB_STATE" <<EOF
{"computers": [{"id": "comp-1", "name": "test-mac", "hostname": "test-mac", "username": "${M_USER}"}],
 "projects": [{"id": "proj-app", "name": "app", "computer": {"id": "comp-1", "name": "test-mac"},
               "folder": "~/work/app", "repo_url": null, "digest_enabled": true}],
 "memories": []}
EOF
}
hub_edit() { # <python code changing the state dict s>
  python3 -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); exec(sys.argv[2]); json.dump(s, open(p, "w"))' "$M_HUB_STATE" "$1"
}
hub_reset
: >"$M_HUB_LOG"
python3 "${FIXTURES}/fake-hub.py" "$M_HUB_STATE" "$M_HUB_LOG" "${SANDBOX}/mhub.port" &
EXTRA_PIDS="$EXTRA_PIDS $!"
for _ in $(seq 1 50); do [[ -s "${SANDBOX}/mhub.port" ]] && break; sleep 0.1; done
[[ -s "${SANDBOX}/mhub.port" ]] || fail "memory fake hub did not start"
M_HUB_URL="http://127.0.0.1:$(cat "${SANDBOX}/mhub.port")"
write_conf() { # [extra conf lines...]
  {
    printf "TODO_HUB_URL='%s'\nTODO_API_TOKEN='hub-token-secret-1'\nTODO_COMPUTER_ID='comp-1'\nAI_TODO_MEMORY_DIGEST='off'\n" "$M_HUB_URL"
    for line in "$@"; do printf '%s\n' "$line"; done
  } >"$M_CONF"
}
write_conf

mem() {
  AI_TODO_HUB_CONF="$M_CONF" AI_TODO_CLAUDE_BIN="${FIXTURES}/fake-claude" FAKE_CLAUDE_LOG="$M_CLAUDE_LOG" \
    FAKE_CLAUDE_REPLY="${FAKE_CLAUDE_REPLY:-$M_REPLY}" "$MEMORY" "$@"
}
calls() { cat "${M_CLAUDE_LOG}/count" 2>/dev/null || echo 0; }
stdin_of() { cat "${M_CLAUDE_LOG}/$1.stdin"; }
requests() { # <METHOD> <path>: how many requests the fake hub got
  python3 -c '
import json, sys
print(sum(1 for l in open(sys.argv[1]) if json.loads(l)["method"] == sys.argv[2] and json.loads(l)["path"] == sys.argv[3]))' \
    "$M_HUB_LOG" "$1" "$2"
}
last_body() { # <METHOD> <path>: body of the newest such request
  python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(json.dumps([r for r in rows if r["method"] == sys.argv[2] and r["path"] == sys.argv[3]][-1]["body"]))' \
    "$M_HUB_LOG" "$1" "$2"
}
offset_of() { # <tool> <session id>
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("offset", "none"))' \
    "${M_STATE}/sessions/$1-$2.json" 2>/dev/null || echo none
}
size_of() { wc -c <"$1" | tr -d ' '; }
cfile() { echo "${M_PROJ_DIR}/$1.jsonl"; }

M1=d0d0d0d0-0000-4000-8000-000000000001
python3 "$TRANSCRIPT" claude "$(cfile $M1)" "$M_APP" "$M1" \
  --turn "first prompt about the parser" "first answer" --turn "second prompt about the config" "second answer"
M1_TWO=$(size_of "$(cfile $M1)")
python3 "$TRANSCRIPT" claude "$(cfile $M1)" "$M_APP" "$M1" --open "third prompt still running"
mem run claude "$M1" >"${SANDBOX}/run1.out" || fail "run failed: $(cat "${SANDBOX}/run1.out")"
[[ $(calls) -eq 1 && $(requests POST /api/memories/bulk) -eq 1 ]] \
  || fail "expected 1 claude call and 1 bulk post, got $(calls) / $(requests POST /api/memories/bulk)"
last_body POST /api/memories/bulk | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert (b["computer_id"], b["tool"], b["session_id"], b["cwd"]) == ("comp-1", "claude", sys.argv[1], "~/work/app"), b
assert b["memories"] == [
    {"kind": "decision", "text": "Transcripts are parsed with the stdlib only, no third-party JSON library.",
     "files": ["src/parser.py"], "confidence": 0.9, "supersedes": []},
    {"kind": "gotcha", "text": "The fake hub answers 201 for bulk posts even when every memory is a duplicate.",
     "files": [], "confidence": 0.7, "supersedes": []}], b["memories"]
' "$M1" || fail "bulk body wrong: $(last_body POST /api/memories/bulk)"
stdin_of 1 | python3 -c '
import sys
s, sid = sys.stdin.read(), sys.argv[1]
assert s.startswith("PROJECT: app (~/work/app) on test-mac\nCONVERSATION: claude %s, cwd ~/work/app, excerpt 1/1, 2026-10-16T08:00:00.000Z – " % sid), s[:300]
assert "\n\nALREADY KNOWN:\n- (none)\n\nEXCERPT:\nUSER: first prompt about the parser\n" in s, s
for part in ("[Edit src/f", "ASSISTANT: first answer", "USER: second prompt about the config", "ASSISTANT: second answer"):
    assert part in s, part
for part in ("third prompt", "SECRET-THOUGHT", "TOOL-OUTPUT-OK"):
    assert part not in s, part
' "$M1" || fail "rendered excerpt wrong: $(stdin_of 1)"
[[ "$(offset_of claude "$M1")" == "$M1_TWO" ]] || fail "offset $(offset_of claude "$M1") should end after turn 2 ($M1_TWO)"
[[ $(requests POST /api/sessions/stats) -eq 2 ]] || fail "stats should be pushed before and after extraction"
pass "run_posts_memories_from_complete_turns: one bulk post (computer, tool, session, ~cwd), only complete turns rendered, offset after turn 2, stats pushed"
pass "low_confidence_dropped: a 0.3-confidence memory is not posted"

M2=d0d0d0d0-0000-4000-8000-000000000002
python3 "$TRANSCRIPT" claude "$(cfile $M2)" "$M_APP" "$M2" --turn "only complete prompt" "complete answer"
M2_ONE=$(size_of "$(cfile $M2)")
python3 "$TRANSCRIPT" claude "$(cfile $M2)" "$M_APP" "$M2" --partial "half written prompt"
mem run claude "$M2" >/dev/null || fail "run on a half-written transcript failed"
n=$(calls)
stdin_of "$n" | grep -q "only complete prompt" || fail "complete turn not sent"
! stdin_of "$n" | grep -q "half written" || fail "the turn with a half-written line was sent"
[[ "$(offset_of claude "$M2")" == "$M2_ONE" ]] || fail "offset went past the last complete turn"
python3 "$TRANSCRIPT" claude "$(cfile $M2)" "$M_APP" "$M2" --rest
mem run claude "$M2" >/dev/null || fail "run after the line was finished failed"
[[ $(calls) -eq $((n + 1)) ]] || fail "the finished turn was not sent"
stdin_of $((n + 1)) | grep -q "USER: half written prompt" && stdin_of $((n + 1)) | grep -q "ASSISTANT: half written answer" \
  || fail "the finished turn is incomplete: $(stdin_of $((n + 1)))"
! stdin_of $((n + 1)) | grep -q "only complete prompt" || fail "the old turn was sent again"
[[ "$(offset_of claude "$M2")" == "$(size_of "$(cfile $M2)")" ]] || fail "offset not at EOF after the finished turn"
pass "partial_trailing_line_is_not_consumed: a half-written last line stops the offset before its turn; finished later, only that turn is sent"

before_calls=$(calls)
before_posts=$(requests POST /api/memories/bulk)
mem run claude "$M1" >/dev/null || fail "second run failed"
[[ $(calls) -eq $before_calls && $(requests POST /api/memories/bulk) -eq $before_posts ]] || fail "second run sent something"
pass "second_run_sends_nothing_new: no claude call, no post"

python3 "$TRANSCRIPT" claude "$(cfile $M1)" "$M_APP" "$M1" --finish "third answer done"
mem run claude "$M1" >/dev/null || fail "run after appending failed"
[[ $(calls) -eq $((before_calls + 1)) ]] || fail "appended turn not sent"
s="$(stdin_of $((before_calls + 1)))"
[[ "$s" == *"USER: third prompt still running"* && "$s" == *"ASSISTANT: third answer done"* ]] || fail "appended turn missing: $s"
[[ "$s" != *"first prompt"* && "$s" != *"second prompt"* ]] || fail "old turns sent again: $s"
[[ "$(offset_of claude "$M1")" == "$(size_of "$(cfile $M1)")" ]] || fail "offset not at EOF"
pass "appending_a_turn_sends_only_it"

M_MOVED=d0d0d0d0-0000-4000-8000-0000000000a1
python3 "$TRANSCRIPT" claude "$(cfile $M_MOVED)" "${HOME}/work" "$M_MOVED" --turn "started in the parent folder" "ok"
python3 "$TRANSCRIPT" claude "$(cfile $M_MOVED)" "$M_APP" "$M_MOVED" \
  --turn "then worked in the app 1" "ok" --turn "then worked in the app 2" "ok"
before_calls=$(calls)
mem run claude "$M_MOVED" >/dev/null || fail "run on a session that moved into the project failed"
[[ $(calls) -eq $((before_calls + 1)) ]] || fail "a session that moved into the project was not extracted"
last_body POST /api/memories/bulk | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert (b["session_id"], b["cwd"]) == (sys.argv[1], "~/work/app"), b
' "$M_MOVED" || fail "moved session posted with the wrong cwd: $(last_body POST /api/memories/bulk)"
pass "run_uses_effective_cwd: a session launched in a parent folder that worked in the project is extracted for the project"

python3 - "${M_CLAUDE_LOG}" "$HOME" <<'PY' || fail "claude flags/env/cwd wrong: $(cat "${M_CLAUDE_LOG}/1.argv")"
import json, sys
log, home = sys.argv[1], sys.argv[2]
argv = json.load(open(log + "/1.argv"))
schema = {"type": "object", "additionalProperties": False, "required": ["memories"],
          "properties": {"memories": {"type": "array", "maxItems": 12, "items": {
              "type": "object", "additionalProperties": False, "required": ["kind", "text", "confidence"],
              "properties": {
                  "kind": {"type": "string", "enum": ["decision", "gotcha", "open_thread", "done", "files_changed"]},
                  "text": {"type": "string", "minLength": 10, "maxLength": 400},
                  "files": {"type": "array", "maxItems": 20, "items": {"type": "string", "maxLength": 300}},
                  "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                  "supersedes": {"type": "array", "maxItems": 10, "items": {"type": "string"}}}}}}}
assert argv[:5] == ["-p", "--no-session-persistence", "--output-format", "json", "--json-schema"], argv[:5]
assert json.loads(argv[5]) == schema, argv[5]
assert argv[6:15] == ["--tools", "", "--strict-mcp-config", "--setting-sources", "", "--model", "sonnet", "--system-prompt", argv[14]], argv[6:]
prompt = argv[14]
assert prompt.startswith("You extract durable project memory from an excerpt of an AI coding conversation.\n"), prompt
assert "- Section codes like Sp, I, Si and P are opaque labels: copy them as-is, never expand or interpret them.\n" in prompt
assert prompt.endswith("- If nothing durable happened, return an empty list."), prompt[-80:]
assert "- Skip what only matters to this session: temporary or scratch paths" in prompt, prompt
assert len(argv) == 15, argv
assert open(log + "/1.env").read() == "1\n"
assert open(log + "/1.cwd").read().strip() == home + "/.ai-remote/memory-state/run"
PY
[[ "$(stat -f '%Lp' "$M_STATE" 2>/dev/null || stat -c '%a' "$M_STATE")" == 700 ]] || fail "memory-state is not mode 700"
pass "claude_flags_and_env: -p --no-session-persistence --output-format json --json-schema <spec schema> --tools \"\" --strict-mcp-config --setting-sources \"\" --model sonnet --system-prompt; AI_TODO_MEMORY_RUN=1; cwd memory-state/run"

M3=d0d0d0d0-0000-4000-8000-000000000003
python3 - "$FIXTURES" "$(cfile $M3)" "$M_APP" "$M3" "${SANDBOX}/reply-secret.json" "${SANDBOX}/raw-secrets.txt" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import transcript
texts, raws = [], []
for line in open(sys.argv[1] + "/secrets.txt", encoding="utf-8"):
    if line.startswith("#") or not line.strip() or line.startswith("keep"):
        continue
    kind, text, raw = [p.strip() for p in line.rstrip("\n").split(" ::: ")]
    texts.append(text.replace("@@", "").replace("\\n", "\n"))
    raws.append(raw)
raws.append("hub-token-secret-1")
prompt = "keep these safe: " + " | ".join(texts[:12]) + " and the hub token hub-token-secret-1"
transcript.append("claude", sys.argv[2], sys.argv[3], sys.argv[4],
                  [("turn", prompt, "noted: " + " | ".join(texts[12:]))])
token = "ghp_" + "Q1w2E3r4T5y6U7i8O9p0A1s2D3f4G5h6J7k8"
raws.append(token[4:])
json.dump({"type": "result", "is_error": False, "structured_output": {"memories": [
    {"kind": "gotcha", "text": "Deploys authenticate with " + token + " from the vault.", "files": [], "confidence": 0.9}]}},
    open(sys.argv[5], "w"))
open(sys.argv[6], "w").write("\n".join(raws) + "\n")
PY
MY_SERVICE_TOKEN=LocalTok3n_Value9 FAKE_CLAUDE_REPLY="${SANDBOX}/reply-secret.json" mem run claude "$M3" >/dev/null || fail "secrets run failed"
python3 - "${M_CLAUDE_LOG}/$(calls).stdin" "$M_HUB_LOG" "${SANDBOX}/raw-secrets.txt" <<'PY' || fail "a secret leaked"
import json, sys
stdin = open(sys.argv[1]).read()
hub = "\n".join(json.dumps(json.loads(l)["body"]) for l in open(sys.argv[2]))
for raw in open(sys.argv[3]).read().split("\n"):
    if raw:
        assert raw not in stdin, ("claude stdin", raw)
        assert raw not in hub, ("hub request", raw)
assert "[REDACTED:" in stdin and "[REDACTED:github_token] from the vault" in hub
PY
pass "stdin_has_no_secrets: no sample secret (nor the hub token) reaches claude's stdin, the posted memories or the stats title"

M3C=d0d0d0d0-0000-4000-8000-0000000000c3
python3 - "$FIXTURES" "$(cfile $M3C)" "$M_APP" "$M3C" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import transcript
w = transcript.Writer("claude", sys.argv[2], sys.argv[3], sys.argv[4])
token = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
command = "echo " + "x" * 180 + " " + token + " | gh auth login --with-token"  # the 200-char cut lands in the token
w.add({"type": "user", "message": {"role": "user", "content": "log in with the long command"}})
w.add({"type": "assistant", "message": {"id": "m-cut", "role": "assistant", "model": "m", "stop_reason": "tool_use",
       "content": [{"type": "tool_use", "id": "tc", "name": "Bash", "input": {"command": command}}]}})
w.add({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tc", "content": "ok"}]}})
w.claude_finish("y" * 1990 + " LocalTok3n_Value9 was used")  # the 2000-char cut lands in the env secret
w.write()
PY
MY_SERVICE_TOKEN=LocalTok3n_Value9 mem run claude "$M3C" >/dev/null || fail "truncation run failed"
s="$(stdin_of "$(calls)")"
[[ "$s" == *"[Bash: echo xxx"* && "$s" == *"ASSISTANT: yyy"* ]] || fail "truncation fixture not rendered: ${s:0:400}"
[[ "$s" != *"A1b2C3d4"* && "$s" != *"LocalTok3"* ]] || fail "a secret cut by the truncation leaked a fragment"
pass "renderer redacts before it truncates: no fragment of a token cut at 200 chars or an env secret cut at 2000 chars"

M4=d0d0d0d0-0000-4000-8000-000000000004
TODAY="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hub_edit "
m = lambda i, **kw: dict(dict(id=i, project_id='proj-app', todo_id=None, computer_id='comp-1', tool='claude', session_id='x',
        kind='decision', text='memory ' + i, files=[], confidence=0.9, source='extracted', pinned=False, archived=False,
        created_at='2020-01-01T00:00:00Z'), **kw)
s['memories'] += [m('known-sess', session_id='$M4', archived=True), m('known-open', kind='open_thread', tool='codex'),
                  m('known-pin', pinned=True, tool=None, session_id=None), m('known-recent', created_at='$TODAY'),
                  m('known-old'), m('other-proj', project_id='proj-other', created_at='$TODAY')]"
python3 "$TRANSCRIPT" claude "$(cfile $M4)" "$M_APP" "$M4" --turn "close the open thread" "closed"
mem run claude "$M4" >/dev/null || fail "already-known run failed"
s="$(stdin_of "$(calls)")"
for id in known-sess known-open known-pin known-recent; do [[ "$s" == *"- [${id}] "* ]] || fail "ALREADY KNOWN lacks $id: $s"; done
[[ "$s" == *"- [known-open] open_thread: memory known-open"* ]] || fail "known line format wrong: $s"
for id in known-old other-proj; do [[ "$s" != *"[${id}]"* ]] || fail "ALREADY KNOWN lists $id"; done
pass "already_known_is_sent: this session's (archived too), the project's pinned, open threads and last 30 days; not old or other-project memories"

M5=d0d0d0d0-0000-4000-8000-000000000005
python3 "$TRANSCRIPT" claude "$(cfile $M5)" "$M_APP" "$M5" --turn "confidence prompt" "answer"
AI_TODO_MEMORY_MIN_CONFIDENCE=0.8 mem run claude "$M5" >/dev/null || fail "min-confidence run failed"
[[ "$(last_body POST /api/memories/bulk | python3 -c 'import json,sys; print([m["kind"] for m in json.load(sys.stdin)["memories"]])')" == "['decision']" ]] \
  || fail "AI_TODO_MEMORY_MIN_CONFIDENCE not applied"
pass "AI_TODO_MEMORY_MIN_CONFIDENCE raises the confidence cut"

M6=d0d0d0d0-0000-4000-8000-000000000006
python3 "$TRANSCRIPT" claude "$(cfile $M6)" "$M_APP" "$M6" --turn "failure prompt" "answer"
printf '{"type":"result","is_error":true,"result":"boom"}' >"${SANDBOX}/reply-error.json"
printf '{"type":"result","is_error":false,"result":"plain text only"}' >"${SANDBOX}/reply-plain.json"
posts=$(requests POST /api/memories/bulk)
for variant in exit is_error no_structured; do
  rc=0
  case $variant in
    exit) FAKE_CLAUDE_EXIT=1 mem run claude "$M6" >/dev/null 2>&1 || rc=$? ;;
    is_error) FAKE_CLAUDE_REPLY="${SANDBOX}/reply-error.json" mem run claude "$M6" >/dev/null 2>&1 || rc=$? ;;
    no_structured) FAKE_CLAUDE_REPLY="${SANDBOX}/reply-plain.json" mem run claude "$M6" >/dev/null 2>&1 || rc=$? ;;
  esac
  [[ $rc -ne 0 ]] || fail "run succeeded although claude failed ($variant)"
  [[ $(requests POST /api/memories/bulk) -eq $posts && "$(offset_of claude "$M6")" == none ]] || fail "claude failure ($variant) posted or moved the offset"
done
mem run claude "$M6" >/dev/null || fail "run after the failures failed"
[[ "$(offset_of claude "$M6")" == "$(size_of "$(cfile $M6)")" ]] || fail "offset not saved after recovery"
grep -q "step=extract" "${M_STATE}/memory.log" || fail "claude failures not logged"
! grep -q "failure prompt" "${M_STATE}/memory.log" || fail "memory.log holds transcript text"
pass "claude_failure_keeps_offset: exit 1, is_error or no structured_output -> no post, offset unchanged, non-zero exit, logged without transcript text"

long_turns() { # <session id> <count>
  python3 - "$FIXTURES" "$(cfile "$1")" "$M_APP" "$1" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import transcript
steps = [("turn", "long prompt %02d " % i + "lorem ipsum dolor sit amet " * 14, "answer %02d" % i) for i in range(1, int(sys.argv[5]) + 1)]
transcript.append("claude", sys.argv[2], sys.argv[3], sys.argv[4], steps)
PY
}
M7=d0d0d0d0-0000-4000-8000-000000000007
long_turns "$M7" 12
base=$(calls)
AI_TODO_MEMORY_CHUNK_CHARS=2000 mem trigger claude "$M7" >/dev/null 2>&1 || fail "trigger failed"
[[ $(calls) -eq $((base + 3)) ]] || fail "trigger made $(( $(calls) - base )) claude calls, expected the cap of 3"
for n in $(seq $((base + 1)) $((base + 3))); do
  [[ $(stdin_of "$n" | python3 -c 'import sys; print(len(sys.stdin.read()))') -le 2000 ]] || fail "chunk $n is longer than 2000 chars"
done
o=$(offset_of claude "$M7")
[[ "$o" != none && "$o" -gt 0 && "$o" -lt $(size_of "$(cfile $M7)") ]] || fail "offset after 3 chunks wrong: $o"
M8=d0d0d0d0-0000-4000-8000-000000000008
long_turns "$M8" 12
base=$(calls)
if AI_TODO_MEMORY_CHUNK_CHARS=2000 FAKE_CLAUDE_EXIT=1 FAKE_CLAUDE_EXIT_AT=$((base + 2)) mem run claude "$M8" >/dev/null 2>&1; then
  fail "run with a failing second chunk succeeded"
fi
o=$(offset_of claude "$M8")
[[ $(calls) -eq $((base + 2)) && "$o" != none && "$o" -gt 0 ]] || fail "first chunk's offset not saved before the failure ($o)"
first_chunk="$(stdin_of $((base + 1)))"
AI_TODO_MEMORY_CHUNK_CHARS=2000 mem run claude "$M8" >/dev/null || fail "resumed run failed"
[[ "$(offset_of claude "$M8")" == "$(size_of "$(cfile $M8)")" ]] || fail "resumed run did not reach the end"
[[ "$first_chunk" == *"long prompt 01"* && "$(stdin_of $((base + 3)))" != *"long prompt 01"* ]] || fail "resumed run re-sent the first chunk"
[[ "$(stdin_of $((base + 3)))" == *"excerpt 1/"* ]] || fail "resumed run chunk numbering wrong"
pass "chunking_caps: chunks <= AI_TODO_MEMORY_CHUNK_CHARS, a trigger stops after 3, the offset advances per successful chunk, a later run continues"

M9=d0d0d0d0-0000-4000-8000-000000000009
mkdir -p "${HOME}/.claude/projects/-work-elsewhere"
python3 "$TRANSCRIPT" claude "${HOME}/.claude/projects/-work-elsewhere/${M9}.jsonl" "${HOME}/work/elsewhere" "$M9" --turn "unrelated prompt" "answer"
base=$(calls)
stats_before=$(requests POST /api/sessions/stats)
mem run claude "$M9" >/dev/null || fail "run outside a project failed"
[[ $(calls) -eq $base ]] || fail "claude ran for a conversation outside any project"
[[ $(requests POST /api/sessions/stats) -eq $((stats_before + 1)) ]] || fail "stats not pushed for a conversation outside any project"
last_body POST /api/sessions/stats | python3 -c '
import json, sys
b = json.load(sys.stdin)
assert b["computer_id"] == "comp-1" and [s["session_id"] for s in b["sessions"]] == [sys.argv[1]], b
assert b["sessions"][0]["cwd"] == "~/work/elsewhere" and b["sessions"][0]["title"] == "unrelated prompt", b
' "$M9" || fail "stats body wrong: $(last_body POST /api/sessions/stats)"
AI_TODO_STATS=off mem run claude "$M9" >/dev/null || fail "run with stats off failed"
[[ $(requests POST /api/sessions/stats) -eq $((stats_before + 1)) ]] || fail "AI_TODO_STATS=off still pushed stats"
mem run claude "$M9" --force >/dev/null || fail "run --force failed"
[[ $(calls) -eq $((base + 1)) ]] || fail "--force did not extract outside a project"
pass "not_in_project_skips_extraction_but_pushes_stats; AI_TODO_STATS=off pushes nothing; --force extracts anyway"

M10=d0d0d0d0-0000-4000-8000-00000000000a
python3 "$TRANSCRIPT" claude "$(cfile $M10)" "$M_APP" "$M10" --turn "memory off prompt" "answer"
base=$(calls)
stats_before=$(requests POST /api/sessions/stats)
AI_TODO_MEMORY=off mem run claude "$M10" >/dev/null || fail "run with memory off (env) failed"
write_conf "AI_TODO_MEMORY='off'"
mem run claude "$M10" >/dev/null || fail "run with memory off (conf) failed"
write_conf
[[ $(calls) -eq $base ]] || fail "AI_TODO_MEMORY=off still called claude"
[[ $(requests POST /api/sessions/stats) -eq $((stats_before + 2)) ]] || fail "AI_TODO_MEMORY=off stopped the stats push"
pass "memory_off_switch: AI_TODO_MEMORY='off' (conf or env) -> no claude call; stats still pushed"

M11=d0d0d0d0-0000-4000-8000-00000000000b
python3 "$TRANSCRIPT" claude "$(cfile $M11)" "$M_APP" "$M11" --turn "dry run prompt" "answer"
base=$(calls)
posts=$(wc -l <"$M_HUB_LOG")
mem run claude "$M11" --dry-run >"${SANDBOX}/dry.json" || fail "dry run failed"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["session_id"] == sys.argv[2] and [m["kind"] for m in d["memories"]] == ["decision", "gotcha"], d
' "${SANDBOX}/dry.json" "$M11" || fail "dry run output wrong: $(cat "${SANDBOX}/dry.json")"
[[ $(calls) -eq $((base + 1)) ]] || fail "dry run did not call claude"
python3 -c '
import json, sys
new = [json.loads(l) for l in open(sys.argv[1]).readlines()[int(sys.argv[2]):]]
assert all(r["method"] == "GET" for r in new), new
' "$M_HUB_LOG" "$posts" || fail "dry run sent a POST"
[[ ! -e "${M_STATE}/sessions/claude-${M11}.json" ]] || fail "dry run wrote session state"
pass "dry_run_changes_nothing: prints the memories JSON; no POST, no state"

X1=019f0000-0000-7000-8000-0000000000d1
X1_FILE="${HOME}/.codex/sessions/2026/10/16/rollout-2026-10-16T08-00-00-${X1}.jsonl"
python3 "$TRANSCRIPT" codex "$X1_FILE" "$M_APP" "$X1" --turn "codex first prompt" "codex first answer" --turn "codex second prompt" "codex second answer"
X1_TWO=$(size_of "$X1_FILE")
python3 "$TRANSCRIPT" codex "$X1_FILE" "$M_APP" "$X1" --open "codex third prompt"
mem run codex "$X1" >/dev/null || fail "codex run failed"
s="$(stdin_of "$(calls)")"
[[ "$s" == *"CONVERSATION: codex ${X1}, cwd ~/work/app"* && "$s" == *"USER: codex first prompt"* && "$s" == *"ASSISTANT: codex second answer"* ]] || fail "codex excerpt wrong: $s"
[[ "$s" == *"[Bash: cargo test -p todo-server]"* && "$s" != *"codex third prompt"* && "$s" != *"environment_context"* ]] || fail "codex rendering wrong: $s"
[[ "$(offset_of codex "$X1")" == "$X1_TWO" ]] || fail "codex offset not at the last task_complete"
last_body POST /api/memories/bulk | python3 -c 'import json,sys; b=json.load(sys.stdin); assert b["tool"]=="codex" and b["session_id"]==sys.argv[1], b' "$X1" \
  || fail "codex bulk body wrong"
pass "codex_session_extracts_by_task_complete"

cp "$(cfile $M1)" "${SANDBOX}/m1.copy"
python3 "$TRANSCRIPT" claude "${SANDBOX}/m1.copy" "$M_APP" "$M1" --turn "fourth prompt after a rewrite" "fourth answer"
inode_before=$(ls -i "$(cfile $M1)" | awk '{print $1}')
mv "${SANDBOX}/m1.copy" "$(cfile $M1)"
[[ "$(ls -i "$(cfile $M1)" | awk '{print $1}')" != "$inode_before" ]] || fail "test setup: inode did not change"
base=$(calls)
mem run claude "$M1" >/dev/null || fail "run after the file was replaced failed"
s="$(stdin_of $((base + 1)))"
[[ "$s" == *"fourth prompt after a rewrite"* && "$s" != *"third prompt"* && "$s" != *"first prompt"* ]] || fail "resume after inode change wrong: $s"
pass "inode_change_resumes_after_last_entry_id"

M12=d0d0d0d0-0000-4000-8000-00000000000c
python3 "$TRANSCRIPT" claude "$(cfile $M12)" "$M_APP" "$M12" --turn "autodetect prompt" "answer"
printf "TODO_HUB_URL='%s'\nTODO_API_TOKEN='hub-token-secret-1'\nAI_TODO_MEMORY_DIGEST='off'\n" "$M_HUB_URL" >"$M_CONF"
hub_edit "s['computers'].append({'id': 'comp-2', 'name': 'other', 'hostname': 'other-mac', 'username': '$M_USER'})"
AI_TODO_HOSTNAME=test-mac mem run claude "$M12" >/dev/null 2>"${SANDBOX}/autodetect.err" || fail "autodetect run failed: $(cat "${SANDBOX}/autodetect.err")"
[[ "$(last_body POST /api/memories/bulk | python3 -c 'import json,sys; print(json.load(sys.stdin)["computer_id"])')" == comp-1 ]] || fail "autodetect picked the wrong computer"
grep -q "TODO_COMPUTER_ID" "${SANDBOX}/autodetect.err" || fail "autodetect did not hint at TODO_COMPUTER_ID"
hub_edit "s['computers'][1]['hostname'] = 'test-mac'"
if AI_TODO_HOSTNAME=test-mac mem run claude "$M12" >/dev/null 2>&1; then fail "two matching computers were accepted"; else [[ $? -eq 65 ]] || fail "ambiguous computer should exit 65"; fi
hub_edit "s['computers'].pop()"
write_conf
pass "computer_id_autodetect: one computer matching \$USER + host name is used (with a hint); two -> exit 65"

# --- ai-todo-memory: digest -----------------------------------------------------------------

unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
D_NOW=1792152000 # 2026-10-16T12:00:00Z
D_BEGIN="<!-- BEGIN ai-todo-memory: managed by todo-hub, rewritten automatically; edit memories in the app -->"
D_END="<!-- END ai-todo-memory -->"
D_MULTI="${HOME}/work/multi"
D_TRACKED="${HOME}/work/tracked"
D_OWN="${HOME}/work/own"
dmem() { AI_TODO_NOW=$D_NOW mem "$@"; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
excluded() { grep -cx "$2" "$1/.git/info/exclude" 2>/dev/null || true; }
git_q -C "$M_APP" init
git_q -C "$M_APP" commit --allow-empty -m init
git_q -C "$M_APP" worktree add "${M_APP}/.claude/worktrees/w"
for r in repo-a repo-b; do
  mkdir -p "${D_MULTI}/$r"
  git_q -C "${D_MULTI}/$r" init
  git_q -C "${D_MULTI}/$r" commit --allow-empty -m init
done
mkdir -p "$D_TRACKED" "$D_OWN"
git_q -C "$D_TRACKED" init
printf '# Tracked agents\nKeep this file in git.\n' >"${D_TRACKED}/AGENTS.md"
git_q -C "$D_TRACKED" add AGENTS.md
git_q -C "$D_TRACKED" commit -m agents
git_q -C "$D_OWN" init
git_q -C "$D_OWN" commit --allow-empty -m init
printf 'my own notes\n' >"${D_OWN}/CLAUDE.local.md"
printf '%s\nold digest\n' '<!-- Managed by ai-todo-memory (todo-hub). Rewritten automatically — edit, pin or archive memories in the todo app. -->' >"${M_APP}/CLAUDE.local.md"
D_USER_AGENTS="$(printf '# Agents\nUser text above.\n\n%s\nstale digest\n%s\n\nUser text below.\n' "$D_BEGIN" "$D_END")"
printf '%s\n' "$D_USER_AGENTS" >"${M_APP}/AGENTS.md"
for spec in "x2:${M_APP}/.claude/worktrees/w" "x3:${D_MULTI}/repo-a" "x4:${D_TRACKED}"; do
  xid="019f0000-0000-7000-8000-0000000000${spec%%:*}"
  python3 "$TRANSCRIPT" codex "${HOME}/.codex/sessions/2026/10/16/rollout-2026-10-16T09-00-00-${xid}.jsonl" "${spec#*:}" "$xid" --turn "p" "a"
done

hub_edit "
import datetime
comp = {'id': 'comp-1', 'name': 'test-mac'}
proj = lambda i, folder, **kw: dict(dict(id=i, name=i[5:], computer=comp, folder=folder, repo_url=None, digest_enabled=True), **kw)
s['projects'] = [proj('proj-app', '~/work/app'), proj('proj-multi', '~/work/multi'), proj('proj-tracked', '~/work/tracked'),
                 proj('proj-own', '~/work/own'), proj('proj-away', '~/work/app2', computer={'id': 'comp-2', 'name': 'other'})]
day = lambda n: (datetime.date(2026, 10, 15) - datetime.timedelta(days=n)).isoformat()
def m(i, kind, text, d, project='proj-app', **kw):
    return dict(dict(id=i, project_id=project, todo_id=None, computer_id='comp-1', tool='claude', session_id='s-' + i,
                     kind=kind, text=text, files=[], confidence=0.9, source='extracted', pinned=False, archived=False,
                     created_at=d + 'T09:00:00Z', updated_at=d + 'T09:00:00Z'), **kw)
ms = [m('ot-pin', 'open_thread', 'Decide whether Codex digests should go into tracked AGENTS.md files.', '2026-08-01', pinned=True),
      m('ot-01', 'open_thread', 'Weekly rollup ignores sessions without day rows.', day(0), files=['crates/todo-server/src/stats.rs']),
      m('ot-old', 'open_thread', 'An open thread from July that nobody pinned.', '2026-07-01'),
      m('dec-pin', 'decision', 'Use SQLite in WAL mode for todo-server.', '2026-09-01', pinned=True),
      m('dec-01', 'decision', 'Todos in Sp stay without a project until a conversation links them.', day(0)),
      m('got-01', 'gotcha', 'Миграцията прави резервно копие преди v3 — не я прескачай.', day(0)),
      m('done-pin', 'done', 'Shipped the v2 conversation linking.', '2026-09-16', pinned=True),
      m('done-old', 'done', 'Finished something three weeks ago.', day(20)),
      m('arch-1', 'decision', 'An archived decision that must not show.', day(0), archived=True),
      m('other-1', 'decision', 'A memory of another project.', day(0), project='proj-other')]
ms += [m('ot-%02d' % i, 'open_thread', 'Open thread %02d is still waiting for a decision.' % i, day(i)) for i in range(2, 10)]
ms += [m('dec-%02d' % i, 'decision', 'Decision %02d keeps the scripts stdlib-only.' % i, day(i)) for i in range(2, 10)]
ms += [m('got-%02d' % i, 'gotcha', 'Gotcha %02d: launchd jobs need an absolute path.' % i, day(i)) for i in range(2, 13)]
ms += [m('done-%02d' % i, 'done', 'Done item %02d landed on main.' % i, day(i - 1)) for i in range(1, 7)]
ms += [m('fc-%02d' % i, 'files_changed', 'Change %02d touched the installer.' % i, day(i - 1), files=['scripts/todo/install.sh', 'scripts/todo/f%d.sh' % i]) for i in range(1, 7)]
ms += [m('long-%02d' % i, 'gotcha', ('Long gotcha %02d ' % i) + 'lorem ipsum dolor sit amet ' * 13, day(i % 10), project='proj-multi') for i in range(30)]
ms += [m('trk-1', 'decision', 'The tracked project keeps its AGENTS.md in git.', day(0), project='proj-tracked'),
       m('own-1', 'decision', 'The own project has its own CLAUDE.local.md.', day(0), project='proj-own')]
s['memories'] = ms"
write_conf "AI_TODO_MEMORY_DIGEST='on'"

dmem digest >/dev/null || fail "digest failed"
[[ ! -e "${M_APP}/CLAUDE.local.md" ]] || fail "a marker-owned CLAUDE.local.md was kept"
pass "digest_removes_our_claude_local_md: the marker file is deleted and no new one is written"

[[ "$(cat "${M_APP}/AGENTS.md")" == "$D_USER_AGENTS" ]] || fail "the user's untracked, not ignored AGENTS.md was changed"
dmem status --json | python3 -c '
import json, sys
assert {"path": sys.argv[1], "reason": "untracked", "project_id": "proj-app"} in json.load(sys.stdin)["skipped"]
' "${M_APP}/AGENTS.md" || fail "status does not report the skipped untracked AGENTS.md"
pass "an untracked AGENTS.md that git does not ignore is skipped and reported like a tracked one"

printf 'AGENTS.md\n' >"${M_APP}/.gitignore"
dmem digest >/dev/null || fail "digest with an ignored AGENTS.md failed"
python3 - "${M_APP}/AGENTS.md" "${FIXTURES}/digest-expected.md" "$D_BEGIN" "$D_END" <<'PY' || fail "AGENTS.md block not replaced in place: $(cat "${M_APP}/AGENTS.md")"
import sys
text, digest, begin, end = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
assert text == "# Agents\nUser text above.\n\n" + begin + "\n" + digest + end + "\n\nUser text below.\n", text
PY
[[ ! -e "${M_APP}/.claude/worktrees/w/AGENTS.md" ]] || fail "a block was written into a linked worktree"
[[ -f "${D_OWN}/AGENTS.md" && "$(head -n 1 "${D_OWN}/AGENTS.md")" == "$D_BEGIN" ]] || fail "a project with only a Claude session did not get an AGENTS.md block"
[[ "$(cat "${D_OWN}/CLAUDE.local.md")" == "my own notes" ]] || fail "the user's own CLAUDE.local.md was changed"
[[ ! -e "${D_OWN}/.claude/rules/todo-hub-memories.md" ]] || fail "a Claude rules digest was written"
[[ ! -e "${D_MULTI}/repo-a/AGENTS.md" && ! -e "${D_MULTI}/repo-b/AGENTS.md" ]] || fail "AGENTS.md written outside the project folder"
[[ -f "${D_MULTI}/AGENTS.md" && "$(head -n 1 "${D_MULTI}/AGENTS.md")" == "$D_BEGIN" && "$(tail -n 1 "${D_MULTI}/AGENTS.md")" == "$D_END" ]] || fail "project AGENTS.md is not just our block"
[[ $(wc -c <"${D_MULTI}/AGENTS.md") -le 6144 && $(wc -c <"${D_MULTI}/AGENTS.md") -gt 5000 ]] || fail "AGENTS.md block not capped near 6 KB: $(wc -c <"${D_MULTI}/AGENTS.md")"
[[ ! -e "${D_MULTI}/CLAUDE.local.md" && ! -e "${M_APP}/CLAUDE.local.md" ]] || fail "CLAUDE.local.md was created"
[[ "$(git -C "$D_TRACKED" status --porcelain)" == "" && "$(cat "${D_TRACKED}/AGENTS.md")" == $'# Tracked agents\nKeep this file in git.' ]] || fail "tracked AGENTS.md was touched"
dmem status --json | python3 -c '
import json, sys
st = json.load(sys.stdin)
assert {"path": sys.argv[1], "reason": "tracked", "project_id": "proj-tracked"} in st["skipped"], st["skipped"]
' "${D_TRACKED}/AGENTS.md" || fail "status does not report the tracked AGENTS.md"
dmem status | grep -q "skipped: .*tracked/AGENTS.md (tracked)" || fail "status text does not report the tracked AGENTS.md"
dmem status | grep -q "^nightly secrets: *TODO_API_TOKEN only" || fail "status does not explain the nightly run's secret coverage"
pass "agents_md_for_every_project: the block is replaced with outside bytes intact; every digest-enabled project gets AGENTS.md (git-excluded when created, <= 6 KB), including one with only a Claude session; a tracked AGENTS.md is skipped and reported"

D_LATE="${HOME}/work/late"
X5=019f0000-0000-7000-8000-0000000000e5
mkdir -p "$D_LATE"
python3 "$TRANSCRIPT" codex "${HOME}/.codex/sessions/2026/10/16/rollout-2026-10-16T09-00-00-${X5}.jsonl" "$D_LATE" "$X5" --turn "p" "a"
hub_edit "s['projects'].append(dict(s['projects'][0], id='proj-late', name='late', folder='~/work/late'))
s['memories'].append(dict(s['memories'][0], id='late-1', project_id='proj-late', kind='decision', pinned=False,
                          created_at='2026-10-15T09:00:00Z', text='The late project became a git repository later.'))"
dmem digest >/dev/null || fail "digest in a plain folder failed"
[[ -f "${D_LATE}/AGENTS.md" && "$(head -n 1 "${D_LATE}/AGENTS.md")" == "$D_BEGIN" && ! -e "${D_LATE}/CLAUDE.local.md" ]] || fail "AGENTS.md not written into the plain folder"
git_q -C "$D_LATE" init
dmem digest >/dev/null || fail "digest after git init failed"
[[ "$(excluded "$D_LATE" /AGENTS.md)" == 1 ]] || fail "AGENTS.md we created was not git-excluded after a later git init"
[[ -z "$(git -C "$D_LATE" status --porcelain)" ]] || fail "our files show up in git status: $(git -C "$D_LATE" status --porcelain)"
pass "files we created are git-excluded on every write, so a folder that becomes a repo later never shows them"

[[ "$(cat "${D_OWN}/CLAUDE.local.md")" == "my own notes" ]] || fail "the user's own CLAUDE.local.md was changed"
[[ ! -e "${D_OWN}/.claude/rules/todo-hub-memories.md" ]] || fail "a rules digest was written for a file the user owns"
pass "digest_leaves_the_users_claude_local_md: a file we did not write stays, and the notes go to AGENTS.md"

D_FILES=("${M_APP}/AGENTS.md" "${D_MULTI}/AGENTS.md" "${D_OWN}/AGENTS.md" "${D_LATE}/AGENTS.md")
before=""; for f in "${D_FILES[@]}"; do before="$before $(mtime "$f")"; done
sleep 1
dmem digest >/dev/null || fail "second digest failed"
after=""; for f in "${D_FILES[@]}"; do after="$after $(mtime "$f")"; done
[[ "$before" == "$after" ]] || fail "an unchanged digest touched files: $before vs $after"
[[ "$(excluded "$M_APP" /AGENTS.md)" == 0 && "$(excluded "${D_OWN}" /AGENTS.md)" == 1 ]] || fail "exclude lines duplicated"
pass "digest_is_idempotent: a second run leaves every mtime and exclude line alone"

cp "${M_APP}/AGENTS.md" "${SANDBOX}/agents.good"
printf '%s\nextra\n' "$D_BEGIN" >>"${M_APP}/AGENTS.md"
cp "${M_APP}/AGENTS.md" "${SANDBOX}/agents.bad"
if dmem digest >/dev/null 2>&1; then fail "digest succeeded with duplicated markers"; fi
cmp -s "${M_APP}/AGENTS.md" "${SANDBOX}/agents.bad" || fail "AGENTS.md with duplicated markers was changed"
grep -q "unbalanced or duplicated markers" "${M_STATE}/memory.log" || fail "marker problem not logged"
cp "${SANDBOX}/agents.good" "${M_APP}/AGENTS.md"
pass "unbalanced markers: AGENTS.md left untouched, error logged"

rm -f "${D_OWN}/AGENTS.md"
dmem digest --dry-run >"${SANDBOX}/digest-dry.out" || fail "digest --dry-run failed"
[[ ! -e "${D_OWN}/AGENTS.md" && ! -e "${M_APP}/CLAUDE.local.md" ]] && grep -q "would write ${D_OWN}/AGENTS.md" "${SANDBOX}/digest-dry.out" || fail "digest --dry-run wrote or did not report"
pass "digest --dry-run prints what it would write and writes nothing"

D_SHARE="${HOME}/work/share"
mkdir -p "$D_SHARE"
hub_edit "s['projects'].append(dict(s['projects'][0], id='proj-share-a', name='share-a', folder='~/work/share'))
s['projects'].append(dict(s['projects'][0], id='proj-share-b', name='share-b', folder='~/work/share'))
s['memories'].append(dict(s['memories'][0], id='share-a', project_id='proj-share-a', kind='decision', pinned=True,
                          text='Alpha share note.', created_at='2026-10-15T09:00:00Z'))
s['memories'].append(dict(s['memories'][0], id='share-b', project_id='proj-share-b', kind='decision', pinned=True,
                          text='Beta share note.', created_at='2026-10-15T09:00:00Z'))"
dmem digest >/dev/null || fail "shared-folder digest failed"
[[ -f "${D_SHARE}/AGENTS.md" ]] || fail "shared folder has no AGENTS.md"
grep -q "Alpha share note" "${D_SHARE}/AGENTS.md" || fail "first project's note missing from the shared AGENTS.md"
grep -q "Beta share note" "${D_SHARE}/AGENTS.md" || fail "second project's note missing from the shared AGENTS.md"
[[ $(grep -c "BEGIN ai-todo-memory" "${D_SHARE}/AGENTS.md") -eq 1 ]] || fail "shared folder was written as more than one block"
pass "one AGENTS.md for two projects at the same folder"

dmem digest --project proj-share-a >/dev/null || fail "refreshing one project of a shared folder failed"
grep -q "Alpha share note" "${D_SHARE}/AGENTS.md" || fail "refreshing one project dropped its own note"
grep -q "Beta share note" "${D_SHARE}/AGENTS.md" || fail "refreshing one project dropped the other project's note"
[[ $(grep -c "BEGIN ai-todo-memory" "${D_SHARE}/AGENTS.md") -eq 1 ]] || fail "refreshing one project split the shared block"
pass "refreshing one project keeps both projects' notes in the shared AGENTS.md"

hub_edit "s['projects'][0]['folder'] = '~/work/app/'"
dmem digest >/dev/null || fail "digest with a trailing slash failed"
python3 - "${M_APP}/AGENTS.md" "${FIXTURES}/digest-expected.md" "$D_BEGIN" "$D_END" <<'PY' || fail "folder ~/work/app/ not written correctly"
import sys
text, digest, begin, end = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
assert text == "# Agents\nUser text above.\n\n" + begin + "\n" + digest + end + "\n\nUser text below.\n", text
PY
hub_edit "s['projects'][0]['folder'] = '~//work/app'"
dmem digest >/dev/null || fail "digest with // failed"
[[ ! -e "${HOME}/work/app/AGENTS.md.tmp" && $(ls -a "$M_APP" | grep -c 'CLAUDE') -eq 0 ]] || fail "// spelling wrote a second file"
hub_edit "s['projects'][0]['folder'] = '~/work/app'"
pass "digest_target_accepts_trailing_slash: ~/work/app/ and ~//work/app land in the same file"

cp "${M_APP}/AGENTS.md" "${SANDBOX}/agents.before-down"
before="$(mtime "${M_APP}/AGENTS.md")"
printf "TODO_HUB_URL='http://127.0.0.1:9'\nTODO_COMPUTER_ID='comp-1'\nAI_TODO_MEMORY_DIGEST='on'\n" >"$M_CONF"
if dmem digest >/dev/null 2>&1; then fail "digest succeeded with the hub down"; fi
write_conf "AI_TODO_MEMORY_DIGEST='on'"
cmp -s "${SANDBOX}/agents.before-down" "${M_APP}/AGENTS.md" \
  && [[ "$before" == "$(mtime "${M_APP}/AGENTS.md")" ]] || fail "hub down changed the digest"
[[ -f "${M_STATE}/projects.json" ]] || fail "projects.json lost when the hub was down"
pass "hub_down_keeps_digest: unreachable hub -> files untouched, projects.json kept, non-zero exit"

hub_edit "s['projects'][0]['digest_enabled'] = False; s['projects'][1]['digest_enabled'] = False"
dmem digest >/dev/null || fail "digest with projects switched off failed"
[[ ! -e "${M_APP}/CLAUDE.local.md" && ! -e "${D_MULTI}/AGENTS.md" ]] || fail "switched-off digests not removed"
[[ "$(cat "${M_APP}/AGENTS.md")" == $'# Agents\nUser text above.\n\n\nUser text below.' ]] || fail "user AGENTS.md wrong after removing the block: $(cat "${M_APP}/AGENTS.md")"
[[ "$(cat "${D_OWN}/CLAUDE.local.md")" == "my own notes" ]] || fail "the user's CLAUDE.local.md changed"
[[ "$(cat "${D_TRACKED}/AGENTS.md")" == $'# Tracked agents\nKeep this file in git.' ]] || fail "tracked AGENTS.md touched"
pass "digest_disabled_removes_only_ours: a created AGENTS.md goes, the user's AGENTS.md keeps its text, their CLAUDE.local.md stays"

hub_edit "s['projects'][0]['digest_enabled'] = True; s['projects'][1]['digest_enabled'] = True"
dmem digest >/dev/null || fail "digest after re-enabling failed"
[[ "$(head -n 1 "${D_MULTI}/AGENTS.md")" == "$D_BEGIN" ]] || fail "re-enabled digests not written"
mem digest --remove-all >/dev/null || fail "digest --remove-all failed"
[[ ! -e "${D_MULTI}/AGENTS.md" && ! -e "${D_LATE}/AGENTS.md" && ! -e "${M_APP}/CLAUDE.local.md" ]] \
  || fail "--remove-all left digests"
[[ "$(cat "${D_OWN}/CLAUDE.local.md")" == "my own notes" && "$(cat "${M_APP}/AGENTS.md")" == $'# Agents\nUser text above.\n\n\nUser text below.' ]] \
  || fail "--remove-all touched user files"
pass "digest --remove-all removes every digest we wrote and nothing else"

# --- ai-todo-memory: trigger and nightly ---------------------------------------------------

T1=d0d0d0d0-0000-4000-8000-0000000000e1
python3 "$TRANSCRIPT" claude "$(cfile $T1)" "$M_APP" "$T1" --turn "debounce prompt one" "answer"
T_NOW=$(date +%s)
base=$(calls)
AI_TODO_NOW=$T_NOW mem trigger claude "$T1" --transcript "$(cfile $T1)" || fail "first trigger failed"
python3 "$TRANSCRIPT" claude "$(cfile $T1)" "$M_APP" "$T1" --turn "debounce prompt two" "answer"
AI_TODO_NOW=$((T_NOW + 600)) mem trigger claude "$T1" || fail "second trigger failed"
[[ $(calls) -eq $((base + 1)) ]] || fail "a trigger inside the debounce window called claude"
AI_TODO_NOW=$((T_NOW + 31 * 60)) mem trigger claude "$T1" || fail "third trigger failed"
[[ $(calls) -eq $((base + 2)) ]] || fail "a trigger after the debounce window did not call claude"
stdin_of $((base + 2)) | grep -q "debounce prompt two" || fail "the later trigger did not send the new turn"
pass "trigger_debounce: one claude call per conversation per 30 min; the next trigger after the window picks up the rest"

T2=d0d0d0d0-0000-4000-8000-0000000000e2
python3 "$TRANSCRIPT" claude "$(cfile $T2)" "$M_APP" "$T2" --turn "locked prompt" "answer"
python3 -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "${M_STATE}/lock" "${SANDBOX}/locked" &
LOCKER=$!
EXTRA_PIDS="$EXTRA_PIDS $LOCKER"
for _ in $(seq 1 50); do [[ -e "${SANDBOX}/locked" ]] && break; sleep 0.1; done
base=$(calls)
start=$(date +%s)
mem trigger claude "$T2" || fail "trigger with the lock held should exit 0"
# The lock is held for 60 s: finishing well before that means the trigger did not wait for it.
[[ $(( $(date +%s) - start )) -le 20 && $(calls) -eq $base ]] || fail "trigger waited for the lock or ran claude ($(( $(date +%s) - start ))s, calls $(calls) vs $base)"
[[ ! -e "${M_STATE}/sessions/claude-${T2}.json" ]] || fail "a locked-out trigger recorded a run"
kill "$LOCKER" 2>/dev/null; wait "$LOCKER" 2>/dev/null || true
pass "trigger_skips_when_locked: exits 0 at once while another run holds the lock"

B1=d0d0d0d0-0000-4000-8000-0000000000b1
python3 "$TRANSCRIPT" claude "$(cfile $B1)" "$M_APP" "$B1" --turn "ancient prompt" "answer"
touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '10 days ago' +%Y%m%d%H%M)" "$(cfile $B1)"
base=$(calls)
mem trigger claude "$B1" || fail "trigger on an old conversation failed"
[[ $(calls) -eq $base && "$(offset_of claude "$B1")" == "$(size_of "$(cfile $B1)")" ]] || fail "an old conversation was extracted or not marked read"
pass "first_run_backfill_window: a transcript last changed 10 days ago is marked read (offset = EOF) without a claude call"

AI_TODO_MEMORY_MAX_CHUNKS_NIGHT=1000 mem nightly >/dev/null 2>&1 || fail "catch-up nightly failed"
ago() { date -v-"$1"H +%Y%m%d%H%M 2>/dev/null || date -d "$1 hours ago" +%Y%m%d%H%M; }
N1=d0d0d0d0-0000-4000-8000-0000000000f1
N2=d0d0d0d0-0000-4000-8000-0000000000f2
N3=d0d0d0d0-0000-4000-8000-0000000000f3
for n in 1 2 3; do
  id_var="N$n"
  python3 "$TRANSCRIPT" claude "$(cfile "${!id_var}")" "$M_APP" "${!id_var}" --turn "nightly prompt $n" "answer"
done
touch -t "$(ago 20)" "$(cfile $N1)"
touch -t "$(ago 10)" "$(cfile $N2)"
log_lines=$(wc -l <"$M_HUB_LOG")
base=$(calls)
rm -f "${M_APP}/CLAUDE.local.md"
AI_TODO_MEMORY_MAX_CHUNKS_NIGHT=2 mem nightly >/dev/null || fail "nightly failed"
[[ $(calls) -eq $((base + 2)) ]] || fail "nightly made $(( $(calls) - base )) claude calls, cap is 2"
stdin_of $((base + 1)) | grep -q "nightly prompt 1" && stdin_of $((base + 2)) | grep -q "nightly prompt 2" || fail "nightly did not go oldest first"
[[ "$(offset_of claude "$N3")" == none ]] || fail "the conversation over the cap was marked read"
python3 - "$M_HUB_LOG" "$log_lines" "$N1" "$N2" "$N3" <<'PY' || fail "nightly stats push wrong"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]).readlines()[int(sys.argv[2]):]]
posts = [(r["path"], r["body"]) for r in rows if r["method"] == "POST"]
assert posts[0][0] == "/api/sessions/stats", posts[0][0]
pushed = {s["session_id"] for s in posts[0][1]["sessions"]}
assert set(sys.argv[3:6]) <= pushed, pushed
assert [p for p, _ in posts].count("/api/sessions/stats") == 1, [p for p, _ in posts]
assert "/api/memories/bulk" in [p for p, _ in posts[1:]]
PY
[[ -f "${M_STATE}/nightly.json" ]] || fail "nightly.json not written"
pass "nightly_pushes_stats_then_extracts_oldest_first_within_cap"
grep -q "^<!-- BEGIN ai-todo-memory" "${M_APP}/AGENTS.md" || fail "nightly did not rewrite the digest"
grep -q "^- .*Transcripts are parsed with the stdlib only" "${M_APP}/AGENTS.md" || fail "digest lacks the extracted memories"
pass "nightly_rewrites_digests"

H1=d0d0d0d0-0000-4000-8000-0000000000a1
python3 "$TRANSCRIPT" claude "$(cfile $H1)" "$M_APP" "$H1" --turn "hub down prompt" "answer"
python3 "$TRANSCRIPT" claude "$(cfile $N3)" "$M_APP" "$N3" --turn "nightly prompt 3b" "answer"
printf "TODO_HUB_URL='http://127.0.0.1:9'\nTODO_COMPUTER_ID='comp-1'\nAI_TODO_MEMORY_DIGEST='on'\n" >"$M_CONF"
cp "${M_APP}/AGENTS.md" "${SANDBOX}/agents.nightly"
offsets_before="$(offset_of claude "$H1") $(offset_of claude "$N3") $(offset_of claude "$M1")"
base=$(calls)
if mem nightly >/dev/null 2>&1; then fail "nightly succeeded with the hub down"; fi
if mem run claude "$H1" >/dev/null 2>&1; then fail "run succeeded with the hub down"; fi
mem trigger claude "$H1" >/dev/null 2>&1 || true
[[ "$offsets_before" == "$(offset_of claude "$H1") $(offset_of claude "$N3") $(offset_of claude "$M1")" ]] || fail "offsets changed with the hub down"
[[ $(calls) -eq $base ]] || fail "claude was called although the already-known list could not be fetched"
cmp -s "${SANDBOX}/agents.nightly" "${M_APP}/AGENTS.md" || fail "the digest changed with the hub down"
write_conf "AI_TODO_MEMORY_DIGEST='on'"
pass "hub_down_keeps_offsets: nightly, run and trigger with the hub unreachable advance nothing and keep the digest"

# --- end of the ai-todo-memory sections -------------------------------------------------
export HOME="$SAVED_HOME"

# --- tmux.conf ----------------------------------------------------------------

tmux -L "${SOCK}-conf" -f /dev/null new-session -d -s conftest
if ! tmux -L "${SOCK}-conf" source-file "${SCRIPT_DIR}/tmux.conf" 2>"${SANDBOX}/tmuxconf.err"; then
  tmux -L "${SOCK}-conf" kill-server
  fail "tmux.conf did not load: $(cat "${SANDBOX}/tmuxconf.err")"
fi
[[ "$(tmux -L "${SOCK}-conf" show -sv escape-time)" == 0 ]] || fail "escape-time not applied"
[[ "$(tmux -L "${SOCK}-conf" show -gv mouse)" == on ]] || fail "mouse not applied"
tmux -L "${SOCK}-conf" show -g terminal-features | grep -q clipboard || fail "clipboard terminal feature not applied"
tmux -L "${SOCK}-conf" kill-server
pass "tmux.conf loads cleanly on tmux $(tmux -V | cut -d' ' -f2)"

# --- install.sh -----------------------------------------------------------------

INSTALL="${SCRIPT_DIR}/install.sh"
SETTINGS="${HOME}/.claude/settings.json"
# A fake launchctl that records its calls replaces the guard for the installer tests.
LAUNCHCTL_LOG="${SANDBOX}/launchctl.log"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 0\n' "$LAUNCHCTL_LOG" >"${GUARD_BIN}/launchctl"
[[ "$(command -v launchctl)" == "${GUARD_BIN}/launchctl" ]] || fail "the fake launchctl is not first on PATH"
PLIST="${HOME}/Library/LaunchAgents/com.ai-remote.todo-memory.plist"
GUI="gui/$(id -u)"
# A fake `codex app-server` for trusting hooks: lists every command hook in hooks.json
# (untrusted unless already in trusted.json) and records config/batchWrite edits there.
FAKE_CODEX="${SANDBOX}/bin/fake-codex-app-server"
CODEX_TRUST_LOG="${SANDBOX}/codex-trust.log"
cat >"$FAKE_CODEX" <<EOF
#!/usr/bin/env python3
import hashlib, json, os, sys
assert sys.argv[1:] == ["app-server"], sys.argv
home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
hooks_path = os.path.join(home, "hooks.json")
trusted_path = os.path.join(home, "trusted.json")
trusted = json.load(open(trusted_path)) if os.path.exists(trusted_path) else {}
for line in sys.stdin:
    msg = json.loads(line)
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        continue
    if method == "initialize":
        result = {"userAgent": "fake"}
    elif method == "hooks/list":
        # A server request reusing the client's id comes first; it is not the answer.
        print(json.dumps({"id": rid, "method": "item/tool/requestUserInput", "params": {}}), flush=True)
        hooks = []
        data = json.load(open(hooks_path)).get("hooks", {}) if os.path.exists(hooks_path) else {}
        for event, groups in data.items():
            for gi, group in enumerate(groups):
                for hi, h in enumerate(group.get("hooks", [])):
                    key = f"{hooks_path}:{event}:{gi}:{hi}"
                    current = "sha256:" + hashlib.sha256(h["command"].encode()).hexdigest()
                    hooks.append({"key": key, "command": h["command"], "sourcePath": hooks_path,
                                  "currentHash": current,
                                  "trustStatus": "trusted" if trusted.get(key) == current else "untrusted"})
        # A lookalike that turned up in hooks.json after install.sh merged it: never ours.
        hooks.append({"key": f"{hooks_path}:Stop:9:0", "command": "echo /.ai-remote/bin/ai-todo-hook",
                      "sourcePath": hooks_path, "currentHash": "sha256:0", "trustStatus": "untrusted"})
        result = {"data": [{"cwd": msg["params"]["cwds"][0], "hooks": hooks}]}
    elif method == "config/batchWrite":
        with open("${CODEX_TRUST_LOG}", "a") as f:
            f.write(json.dumps(msg["params"]) + "\n")
        for edit in msg["params"]["edits"]:
            for key, value in edit["value"].items():
                trusted[key] = value["trusted_hash"]
        json.dump(trusted, open(trusted_path, "w"))
        result = {"status": "ok"}
    else:
        print(json.dumps({"id": rid, "error": {"message": "unknown"}}), flush=True)
        continue
    print(json.dumps({"id": rid, "result": result}), flush=True)
EOF
chmod +x "$FAKE_CODEX"
export AI_TODO_CODEX_BIN="$FAKE_CODEX"
on_mac() { [[ "$(uname -s)" == Darwin ]]; }
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
[[ ! -e "$LAUNCHCTL_LOG" && ! -e "$PLIST" ]] || fail "--dry-run wrote the plist or ran launchctl"
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
assert commands("PreToolUse") == ["echo pre", f"{bin_dir}/ai-todo-hook tool"], commands("PreToolUse")
for event, status in {"PermissionRequest":"waiting", "PostToolUseFailure":"tool", "SessionEnd":"idle",
                      "StopFailure":"waiting", "Elicitation":"waiting", "ElicitationResult":"tool"}.items():
    assert commands(event) == [f"{bin_dir}/ai-todo-hook {status}"], (event, commands(event))
assert hooks["PreToolUse"][0]["matcher"] == "Bash"
assert s["projectInstructions"] == "claude-md-and-agents-md", s.get("projectInstructions")
assert s["model"] == "opus"
PY
}
check_installed || fail "settings.json after install is wrong: $(cat "$SETTINGS")"
# Every helper in scripts/todo, not a hand-kept list: a new one must not be left out again.
for helper in "${SCRIPT_DIR}"/ai-todo-* "${SCRIPT_DIR}"/ai_todo_*.py; do
  [[ -f "${HOME}/.ai-remote/bin/$(basename "$helper")" ]] || fail "$(basename "$helper") not installed"
  if [[ -x "$helper" ]]; then
    [[ -x "${HOME}/.ai-remote/bin/$(basename "$helper")" ]] || fail "$(basename "$helper") installed without execute"
  fi
done
[[ "$(grep -c 'source-file -q ~/.ai-remote/tmux.conf' "${HOME}/.tmux.conf")" -eq 1 ]] || fail "tmux source line not added exactly once"
grep -q 'set -g status off' "${HOME}/.tmux.conf" || fail "existing ~/.tmux.conf content lost"
[[ "$(stat -f '%Lp' "${HOME}/.ai-remote/todo-hub.conf" 2>/dev/null || stat -c '%a' "${HOME}/.ai-remote/todo-hub.conf")" == 600 ]] \
  || fail "todo-hub.conf is not mode 600"
grep -qx "TODO_HUB_URL='http://hub:8080'" "${HOME}/.ai-remote/todo-hub.conf" || fail "hub URL not written"
grep -qx "TODO_API_TOKEN='tok'" "${HOME}/.ai-remote/todo-hub.conf" || fail "token not kept on re-run"
ls "${HOME}/.claude/settings.json.bak-"* >/dev/null 2>&1 || fail "settings.json was not backed up"
pass "install merges hooks once, keeps existing settings and hooks, writes a 600 config, sources tmux.conf once"

[[ -x "${HOME}/.ai-remote/bin/ai-todo-memory" && -f "${HOME}/.ai-remote/bin/ai_todo_redact.py" ]] || fail "ai-todo-memory / ai_todo_redact.py not installed"
[[ "$(stat -f '%Lp' "${HOME}/.ai-remote/memory-state" 2>/dev/null || stat -c '%a' "${HOME}/.ai-remote/memory-state")" == 700 ]] \
  || fail "memory-state is not mode 700"
"${HOME}/.ai-remote/bin/ai-todo-sessions" stats --json >"${SANDBOX}/installed-stats.out" 2>"${SANDBOX}/installed-stats.err" \
  && [[ ! -s "${SANDBOX}/installed-stats.err" ]] \
  && python3 -c 'import json, sys; assert isinstance(json.load(open(sys.argv[1])), list)' "${SANDBOX}/installed-stats.out" \
  || fail "installed ai-todo-sessions stats failed or can't find ai_todo_redact.py: $(cat "${SANDBOX}/installed-stats.err" "${SANDBOX}/installed-stats.out")"
if on_mac; then
  python3 - "$PLIST" "${HOME}/.ai-remote" <<'PY' || fail "plist wrong: $(cat "$PLIST")"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
ai = sys.argv[2]
assert p["Label"] == "com.ai-remote.todo-memory", p
assert p["ProgramArguments"] == [ai + "/bin/ai-todo-memory", "nightly"], p
assert p["StartCalendarInterval"] == {"Hour": 3, "Minute": 30}, p
assert p["StandardOutPath"] == p["StandardErrorPath"] == ai + "/memory-state/launchd.log", p
PY
  expected="bootout ${GUI}/com.ai-remote.todo-memory"$'\n'"bootstrap ${GUI} ${PLIST}"$'\n'"bootout ${GUI}/com.ai-remote.todo-status"$'\n'"bootstrap ${GUI} ${HOME}/Library/LaunchAgents/com.ai-remote.todo-status.plist"
  [[ "$(cat "$LAUNCHCTL_LOG")" == "${expected}"$'\n'"${expected}" ]] || fail "launchctl calls wrong: $(cat "$LAUNCHCTL_LOG")"
fi
pass "install_memory_and_launchd: ai-todo-memory + ai_todo_redact.py installed, memory-state 700, plist (03:30, nightly) booted out then bootstrapped"

python3 - "$INSTALL" "$HOME" <<'PY' || fail "status-only update changed unrelated settings or jobs"
import os, pathlib, plistlib, subprocess, sys
install, home = sys.argv[1], pathlib.Path(sys.argv[2])
paths = [home / ".claude/settings.json", home / ".ai-remote/todo-hub.conf",
         home / ".ai-remote/bin/ai-todo-memory", home / "Library/LaunchAgents/com.ai-remote.todo-memory.plist"]
before = {str(p): p.read_bytes() if p.exists() else None for p in paths}
subprocess.run([install, "--status-only"], stdout=subprocess.DEVNULL, check=True)
assert before == {str(p): p.read_bytes() if p.exists() else None for p in paths}
if sys.platform == "darwin":
    job = plistlib.load(open(home / "Library/LaunchAgents/com.ai-remote.todo-status.plist", "rb"))
    assert job["RunAtLoad"] and job["KeepAlive"], job
    assert job["ProgramArguments"] == [str(home / ".ai-remote/bin/ai-todo-status"), "watch"], job
PY
pass "status-only installs the persistent monitor without changing Claude, hub credentials or nightly memory"

python3 - "$INSTALL" "$HOME" <<'PY' || fail "Claude-only status update changed unrelated settings or jobs"
import pathlib, subprocess, sys
install, home = sys.argv[1], pathlib.Path(sys.argv[2])
paths = [home / ".codex/config.toml", home / ".codex/hooks.json", home / ".ai-remote/todo-hub.conf",
         home / ".ai-remote/bin/ai-todo-memory", home / "Library/LaunchAgents/com.ai-remote.todo-memory.plist"]
before = {str(p): p.read_bytes() if p.exists() else None for p in paths}
subprocess.run([install, "--claude-status-only"], stdout=subprocess.DEVNULL, check=True)
assert before == {str(p): p.read_bytes() if p.exists() else None for p in paths}
PY
pass "claude-status-only preserves Codex settings, hub credentials and nightly memory"

"$INSTALL" --token newtok >/dev/null
grep -qx "TODO_HUB_URL='http://hub:8080'" "${HOME}/.ai-remote/todo-hub.conf" || fail "hub URL lost when only --token was given"
grep -qx "TODO_API_TOKEN='newtok'" "${HOME}/.ai-remote/todo-hub.conf" || fail "token not updated"
pass "re-running with --token updates only the token"

OUR_NOTIFY="notify = [\"${HOME}/.ai-remote/bin/ai-todo-codex-notify\"]"
[[ -x "${HOME}/.ai-remote/bin/ai-todo-codex-notify" ]] || fail "ai-todo-codex-notify not installed"
[[ "$(grep -c '^notify' "${HOME}/.codex/config.toml")" -eq 1 ]] && grep -qxF "$OUR_NOTIFY" "${HOME}/.codex/config.toml" \
  || fail "codex notify not added exactly once: $(cat "${HOME}/.codex/config.toml")"
pass "install adds our notify to a codex config without one, once"

CX="${SANDBOX}/codex-hooks"
mkdir -p "$CX"
cat >"${CX}/hooks.json" <<'EOF'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
EOF
: >"$CODEX_TRUST_LOG"
out="$(CODEX_HOME="$CX" "$INSTALL")"
CODEX_HOME="$CX" "$INSTALL" >/dev/null
python3 - "${CX}/hooks.json" "${HOME}/.ai-remote/bin/ai-todo-hook" <<'PY' || fail "codex hooks.json wrong: $(cat "${CX}/hooks.json")"
import json, sys
hooks = json.load(open(sys.argv[1]))["hooks"]
cmds = {e: [h["command"] for g in groups for h in g["hooks"]] for e, groups in hooks.items()}
b = sys.argv[2]
assert cmds == {"Stop": ["say done", f"{b} --codex idle"], "UserPromptSubmit": [f"{b} --codex busy"],
                "PermissionRequest": [f"{b} --codex waiting"], "PostToolUse": [f"{b} --codex tool"],
                "PreToolUse": [f"{b} --codex tool"], "Interrupt": [f"{b} --codex idle"],
                "SessionEnd": [f"{b} --codex idle"]}, cmds
PY
grep -q "codex hooks: trusted 7" <<<"$out" || fail "install did not report trusting the codex hooks: $out"
python3 - "$CODEX_TRUST_LOG" "${CX}/hooks.json" <<'PY' || fail "codex trust writes wrong: $(cat "$CODEX_TRUST_LOG")"
import json, sys
writes = [json.loads(l) for l in open(sys.argv[1])]
assert len(writes) == 1, writes  # the re-run found them trusted already
edit = writes[0]["edits"][0]
assert edit["keyPath"] == "hooks.state" and edit["mergeStrategy"] == "upsert", edit
keys = sorted(edit["value"])
assert keys == sorted(f"{sys.argv[2]}:{e}" for e in ["PermissionRequest:0:0", "PostToolUse:0:0", "PreToolUse:0:0", "Interrupt:0:0", "SessionEnd:0:0", "Stop:1:0", "UserPromptSubmit:0:0"]), keys
assert all(v["trusted_hash"].startswith("sha256:") for v in edit["value"].values())
PY
CODEX_HOME="$CX" "$INSTALL" --uninstall >/dev/null
[[ "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "${CX}/hooks.json")" \
  == '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}' ]] \
  || fail "uninstall did not leave only the foreign codex hook: $(cat "${CX}/hooks.json")"
printf '{ broken' >"${CX}/hooks.json"
out="$(CODEX_HOME="$CX" "$INSTALL" 2>&1)" || fail "install failed on an invalid codex hooks.json: $out"
[[ "$(cat "${CX}/hooks.json")" == "{ broken" ]] || fail "install modified an invalid codex hooks.json"
out="$(CODEX_HOME="$CX" "$INSTALL" --uninstall 2>&1)"
grep -qF "WARNING: our hooks are still in ${CX}/hooks.json" <<<"$out" || fail "uninstall did not warn about an invalid codex hooks.json: $out"
[[ "$(cat "${CX}/hooks.json")" == "{ broken" ]] || fail "uninstall modified an invalid codex hooks.json"
"$INSTALL" >/dev/null
pass "install merges the codex hooks into hooks.json and trusts exactly ours (not a lookalike, past a server request reusing the id); uninstall keeps foreign hooks and warns when it can't remove ours"

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

printf "AI_TODO_MEMORY_MODEL='opus'\n" >>"${HOME}/.ai-remote/todo-hub.conf"
"$INSTALL" --computer-id 78e7ef89-0000-4000-8000-000000000001 >/dev/null
grep -qx "TODO_COMPUTER_ID='78e7ef89-0000-4000-8000-000000000001'" "${HOME}/.ai-remote/todo-hub.conf" || fail "--computer-id not written"
grep -qx "TODO_HUB_URL='http://hub:8080'" "${HOME}/.ai-remote/todo-hub.conf" && grep -qx "TODO_API_TOKEN='newtok'" "${HOME}/.ai-remote/todo-hub.conf" \
  && grep -qx "AI_TODO_MEMORY_MODEL='opus'" "${HOME}/.ai-remote/todo-hub.conf" || fail "--computer-id lost other settings: $(cat "${HOME}/.ai-remote/todo-hub.conf")"
"$INSTALL" --computer-id 78e7ef89-0000-4000-8000-000000000002 >/dev/null
[[ $(grep -c '^TODO_COMPUTER_ID=' "${HOME}/.ai-remote/todo-hub.conf") -eq 1 ]] || fail "TODO_COMPUTER_ID duplicated"
[[ "$(stat -f '%Lp' "${HOME}/.ai-remote/todo-hub.conf" 2>/dev/null || stat -c '%a' "${HOME}/.ai-remote/todo-hub.conf")" == 600 ]] || fail "todo-hub.conf lost mode 600"
pass "--computer-id is written to todo-hub.conf (once), keeping the other settings"

: >"$LAUNCHCTL_LOG"
"$INSTALL" --no-nightly >/dev/null
check_installed || fail "settings.json changed by --no-nightly: $(cat "$SETTINGS")"
if on_mac; then
  [[ ! -e "$PLIST" && "$(cat "$LAUNCHCTL_LOG")" == "bootout ${GUI}/com.ai-remote.todo-memory"* ]] || fail "--no-nightly left the job: $(cat "$LAUNCHCTL_LOG")"
fi
"$INSTALL" >/dev/null
{ ! on_mac || [[ -f "$PLIST" ]]; } || fail "re-install did not restore the plist"
check_installed || fail "settings.json hooks differ from before after re-installing: $(cat "$SETTINGS")"
pass "install_no_nightly: no plist, the job is booted out; settings.json hooks stay exactly today's"

LINK_SRC="${SANDBOX}/mcp-src"
mkdir -p "$LINK_SRC" "${HOME}/.ai-remote/mcp"
printf '{}\n' >"${LINK_SRC}/one.json"
printf '{}\n' >"${LINK_SRC}/two.json"
printf 'not a server\n' >"${LINK_SRC}/notes.txt"
printf '{"mine":true}\n' >"${HOME}/.ai-remote/mcp/two.json"
"$INSTALL" --mcp-link "$LINK_SRC" >/dev/null
"$INSTALL" --mcp-link "$LINK_SRC" >/dev/null
[[ -L "${HOME}/.ai-remote/mcp/one.json" && "$(readlink "${HOME}/.ai-remote/mcp/one.json")" == "${LINK_SRC}/one.json" ]] \
  || fail "--mcp-link did not symlink one.json: $(ls -l "${HOME}/.ai-remote/mcp")"
[[ ! -L "${HOME}/.ai-remote/mcp/two.json" && "$(cat "${HOME}/.ai-remote/mcp/two.json")" == '{"mine":true}' ]] \
  || fail "--mcp-link replaced an existing two.json"
[[ ! -e "${HOME}/.ai-remote/mcp/notes.txt" ]] || fail "--mcp-link linked a non-json file"
[[ "$(ls "${HOME}/.ai-remote/mcp" | wc -l | tr -d ' ')" -eq 2 ]] || fail "--mcp-link duplicated: $(ls "${HOME}/.ai-remote/mcp")"
[[ "$(stat -f '%Lp' "${HOME}/.ai-remote/mcp" 2>/dev/null || stat -c '%a' "${HOME}/.ai-remote/mcp")" == 700 ]] || fail "mcp folder is not mode 700"
status=0
"$INSTALL" --mcp-link "${SANDBOX}/no-such-dir" >/dev/null 2>&1 || status=$?
[[ $status -eq 64 ]] || fail "--mcp-link with a missing folder exited $status"
pass "install_mcp_link"

cp "$SETTINGS" "${SANDBOX}/settings.good"
printf '{ broken' >"$SETTINGS"
if "$INSTALL" >/dev/null 2>&1; then fail "install accepted an invalid settings.json"; fi
[[ "$(cat "$SETTINGS")" == "{ broken" ]] || fail "install modified an invalid settings.json"
cp "${SANDBOX}/settings.good" "$SETTINGS"
pass "install refuses an invalid settings.json and leaves it alone"

mkdir -p "${HOME}/.ai-remote/hook-state" && printf 'busy\n' >"${HOME}/.ai-remote/hook-state/someid"
mkdir -p "${HOME}/.ai-remote/memory-state/sessions"
touch "${HOME}/.ai-remote/memory-state/sessions/claude-x.json"
: >"$LAUNCHCTL_LOG"
"$INSTALL" --uninstall >"${SANDBOX}/uninstall.out"
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
assert "projectInstructions" not in s, s.get("projectInstructions")
PY
for helper in "${SCRIPT_DIR}"/ai-todo-* "${SCRIPT_DIR}"/ai_todo_*.py; do
  [[ ! -e "${HOME}/.ai-remote/bin/$(basename "$helper")" ]] || fail "uninstall left $(basename "$helper") behind"
done
[[ ! -e "${HOME}/.ai-remote/tmux.conf" ]] || fail "uninstall left tmux.conf behind"
! grep -q 'ai-remote/tmux.conf' "${HOME}/.tmux.conf" || fail "uninstall left the tmux source line"
grep -q 'set -g status off' "${HOME}/.tmux.conf" || fail "uninstall removed other ~/.tmux.conf lines"
pass "uninstall removes only our hooks, scripts, tmux line, codex notify and hook state"

[[ ! -e "${HOME}/.ai-remote/bin/ai-todo-memory" && ! -e "${HOME}/.ai-remote/bin/ai_todo_redact.py" ]] || fail "uninstall left ai-todo-memory"
[[ -f "${HOME}/.ai-remote/memory-state/sessions/claude-x.json" ]] || fail "uninstall removed memory-state"
grep -q "kept ${HOME}/.ai-remote/memory-state" "${SANDBOX}/uninstall.out" || fail "uninstall did not print the memory-state path"
[[ -L "${HOME}/.ai-remote/mcp/one.json" ]] || fail "uninstall removed ~/.ai-remote/mcp"
grep -q "kept ${HOME}/.ai-remote/mcp" "${SANDBOX}/uninstall.out" || fail "uninstall did not print the mcp path"
if on_mac; then
  [[ ! -e "$PLIST" && "$(cat "$LAUNCHCTL_LOG")" == "bootout ${GUI}/com.ai-remote.todo-memory"* ]] || fail "uninstall did not boot out the job: $(cat "$LAUNCHCTL_LOG")"
fi
pass "uninstall_removes_job_keeps_state: bootout, plist and ai-todo-memory removed, memory-state kept and printed"

"$INSTALL" >/dev/null
REMOVE_ALL_LOG="${SANDBOX}/remove-all.log"
printf '#!/bin/sh\n[ -e "%s" ] && echo "$* (plist still there)" >>"%s" || echo "$*" >>"%s"\n' "$PLIST" "$REMOVE_ALL_LOG" "$REMOVE_ALL_LOG" \
  >"${HOME}/.ai-remote/bin/ai-todo-memory"
"$INSTALL" --uninstall --remove-digests >/dev/null
[[ "$(cat "$REMOVE_ALL_LOG" 2>/dev/null)" == "digest --remove-all"* && ! -e "${HOME}/.ai-remote/bin/ai-todo-memory" ]] \
  || fail "--remove-digests did not run digest --remove-all before removing ai-todo-memory: $(cat "$REMOVE_ALL_LOG" 2>/dev/null)"
pass "uninstall_remove_digests_runs_remove_all_first"

LIMITS="${SCRIPT_DIR}/ai-todo-limits"
chmod +x "$LIMITS"
TOKEN="sk-ant-oat01-TESTTOKEN-DO-NOT-LEAK"
CURSOR_TOKEN="cursor-access-TESTTOKEN-DO-NOT-LEAK"
export AI_TODO_LIMITS_OFFLINE=1

mkdir -p "${HOME}/.claude"
cat >"${HOME}/.claude/.credentials.json" <<EOF
{"claudeAiOauth":{"accessToken":"${TOKEN}","refreshToken":"refresh-should-not-leak","expiresAt":1}}
EOF
export AI_TODO_LIMITS_HTTP_STATUS=200
export AI_TODO_LIMITS_HTTP_BODY='{"five_hour":{"utilization":25,"resets_at":"2026-10-18T15:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2026-10-20T00:00:00Z"},"seven_day_opus":{"utilization":40,"resets_at":"2026-10-20T00:00:00Z"},"extra_usage":{"is_enabled":false,"utilization":99,"monthly_limit":100,"used_credits":1}}'
"$LIMITS" --tool claude >"${SANDBOX}/limits-claude.out" 2>"${SANDBOX}/limits-claude.err" \
  || fail "claude limits failed: $(cat "${SANDBOX}/limits-claude.err")"
[[ ! -s "${SANDBOX}/limits-claude.err" ]] || fail "claude limits stderr: $(cat "${SANDBOX}/limits-claude.err")"
! grep -q "$TOKEN" "${SANDBOX}/limits-claude.out" "${SANDBOX}/limits-claude.err" || fail "claude token leaked"
! grep -q "refresh-should-not-leak" "${SANDBOX}/limits-claude.out" || fail "claude refresh token leaked"
python3 - "${SANDBOX}/limits-claude.out" <<'PY' || fail "claude limits JSON: $(cat "${SANDBOX}/limits-claude.out")"
import json, sys
data = json.load(open(sys.argv[1]))
assert data["tool"] == "claude", data
kinds = [(w["kind"], w.get("scope"), w["used_percent"]) for w in data["windows"]]
assert kinds == [("5h", None, 25.0), ("weekly", None, 40.0)], kinds
assert data["windows"][0]["resets_at"] == "2026-10-18T15:00:00Z"
assert all(w["kind"] != "monthly" for w in data["windows"])
PY
pass "limits_claude_5h_and_weekly: expired file token still used offline; matching opus weekly and disabled extra usage omitted"

export AI_TODO_LIMITS_HTTP_BODY='{"five_hour":null,"seven_day":null,"seven_day_opus":{"utilization":80,"resets_at":"2026-10-21T00:00:00Z"},"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2500}}'
"$LIMITS" --tool claude >"${SANDBOX}/limits-claude2.out" 2>"${SANDBOX}/limits-claude2.err" \
  || fail "claude scoped limits failed"
python3 - "${SANDBOX}/limits-claude2.out" <<'PY' || fail "claude scoped JSON: $(cat "${SANDBOX}/limits-claude2.out")"
import json, sys
data = json.load(open(sys.argv[1]))
kinds = [(w["kind"], w.get("scope"), w["used_percent"]) for w in data["windows"]]
assert kinds == [("weekly", "opus", 80.0), ("monthly", None, 25.0)], kinds
PY
pass "limits_claude_opus_weekly_and_extra_monthly: no overall weekly, monthly from credits over the cap"

rm -f "${HOME}/.claude/.credentials.json"
unset CLAUDE_CODE_OAUTH_TOKEN
"$LIMITS" --tool claude >"${SANDBOX}/limits-claude-none.out" 2>"${SANDBOX}/limits-claude-none.err" \
  || fail "claude limits without a login should still exit 0"
python3 - "${SANDBOX}/limits-claude-none.out" <<'PY' || fail "signed-out claude still showed limits: $(cat "${SANDBOX}/limits-claude-none.out")"
import json, sys
assert json.load(open(sys.argv[1]))["windows"] == []
PY
export AI_TODO_LIMITS_HTTP_STATUS=401
mkdir -p "${HOME}/.claude"
printf '%s\n' "{\"claudeAiOauth\":{\"accessToken\":\"${TOKEN}\",\"expiresAt\":9999999999999}}" >"${HOME}/.claude/.credentials.json"
status=0
"$LIMITS" --tool claude >"${SANDBOX}/limits-claude-401.out" 2>"${SANDBOX}/limits-claude-401.err" || status=$?
[[ $status -eq 75 ]] || fail "401 exit was $status: $(cat "${SANDBOX}/limits-claude-401.err" "${SANDBOX}/limits-claude-401.out")"
[[ ! -s "${SANDBOX}/limits-claude-401.out" ]] || fail "401 wrote a limits body: $(cat "${SANDBOX}/limits-claude-401.out")"
! grep -q "$TOKEN" "${SANDBOX}/limits-claude-401.out" "${SANDBOX}/limits-claude-401.err" || fail "token leaked on 401"
pass "limits_claude_signed_out_or_rejected: no login prints an empty list; a failed request exits 75 and prints nothing"

# The cache: a fresh reading is reused, a 429 pauses requests and shows the last reading.
export AI_TODO_LIMITS_CACHE=1
export AI_TODO_HUB_CONF="${SANDBOX}/no-hub.conf"   # local cache only here; the hub is tested next
LCACHE="${HOME}/.ai-remote/limits-cache/claude.json"
rm -f "$LCACHE"
limits_5h() {
  "$LIMITS" --tool claude 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["windows"][0]["used_percent"])'
}
age_cache() {  # $1: "at" seconds ago, $2: "blocked_until" seconds from now (optional)
  python3 - "$LCACHE" "$1" "${2:-}" <<'PY'
import json, sys, time
path, ago, until = sys.argv[1], float(sys.argv[2]), sys.argv[3]
data = json.load(open(path))
data["at"] = time.time() - ago
if until:
    data["blocked_until"] = time.time() + float(until)
json.dump(data, open(path, "w"))
PY
}
export AI_TODO_LIMITS_HTTP_STATUS=200
export AI_TODO_LIMITS_HTTP_BODY='{"five_hour":{"utilization":10,"resets_at":"2026-10-18T15:00:00Z"}}'
[[ "$(limits_5h)" == "10.0" ]] || fail "cache: first reading"
! grep -q "$TOKEN" "$LCACHE" || fail "cache stored the token"
export AI_TODO_LIMITS_HTTP_BODY='{"five_hour":{"utilization":20,"resets_at":"2026-10-18T15:00:00Z"}}'
[[ "$(limits_5h)" == "10.0" ]] || fail "cache: a fresh reading was not reused"
age_cache 600
export AI_TODO_LIMITS_HTTP_STATUS=429 AI_TODO_LIMITS_RETRY_AFTER=250
[[ "$(limits_5h)" == "10.0" ]] || fail "cache: a 429 did not show the last reading"
python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert 200 < d["blocked_until"] - time.time() <= 250, d' "$LCACHE" \
  || fail "cache: 429 did not pause for its Retry-After: $(cat "$LCACHE")"
export AI_TODO_LIMITS_HTTP_STATUS=200
[[ "$(limits_5h)" == "10.0" ]] || fail "cache: asked again while paused"
age_cache 600 -1
[[ "$(limits_5h)" == "20.0" ]] || fail "cache: no new request after the pause"
age_cache 7200 300
status=0
"$LIMITS" --tool claude >/dev/null 2>&1 || status=$?
[[ $status -eq 75 ]] || fail "cache: a paused request with only an old reading exited $status"
unset AI_TODO_LIMITS_CACHE AI_TODO_LIMITS_RETRY_AFTER
rm -f "$LCACHE"
pass "limits_cache: reuses a fresh reading, pauses for a 429's Retry-After showing the last reading, fails past an hour"

# Shared per account through the hub: reuse its reading, fetch only with the lease, report back.
LHUB_DIR="${SANDBOX}/limits-hub"
mkdir -p "$LHUB_DIR"
python3 - "$LHUB_DIR" <<'PY' &
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
d = sys.argv[1]
class Hub(BaseHTTPRequestHandler):
    def handle_one(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(os.path.join(d, "log"), "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        if self.command == "POST":
            out = open(os.path.join(d, "claim.json"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_response(204)
            self.end_headers()
    do_POST = handle_one
    do_PUT = handle_one
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), Hub)
open(os.path.join(d, "port"), "w").write(str(server.server_port))
server.serve_forever()
PY
EXTRA_PIDS="$EXTRA_PIDS $!"
for _ in $(seq 1 50); do [[ -s "${LHUB_DIR}/port" ]] && break; sleep 0.1; done
printf 'TODO_HUB_URL=http://127.0.0.1:%s\nTODO_API_TOKEN=hubtoken\n' "$(cat "${LHUB_DIR}/port")" >"${LHUB_DIR}/hub.conf"
export AI_TODO_HUB_CONF="${LHUB_DIR}/hub.conf" AI_TODO_LIMITS_CACHE=1
printf '{"oauthAccount":{"accountUuid":"acct-1234"}}\n' >"${HOME}/.claude.json"
ACCOUNT_KEY="claude-$(printf 'acct-1234' | shasum -a 256 | cut -c1-32)"
rm -f "$LCACHE" "${LHUB_DIR}/log"

# Another computer's fresh reading: shown, and no usage request (it would fail with a 500).
printf '{"fetch":false,"windows":[{"kind":"5h","used_percent":33.0}],"age_seconds":30,"blocked_seconds":null}' >"${LHUB_DIR}/claim.json"
export AI_TODO_LIMITS_HTTP_STATUS=500
[[ "$(limits_5h)" == "33.0" ]] || fail "hub: a shared reading was not used"
grep -q "\"path\": \"/api/limits/${ACCOUNT_KEY}/claim\"" "${LHUB_DIR}/log" || fail "hub: claim path: $(cat "${LHUB_DIR}/log")"
grep -q '"auth": "Bearer hubtoken"' "${LHUB_DIR}/log" || fail "hub: no hub token sent"
! grep -q 'acct-1234' "${LHUB_DIR}/log" || fail "hub: the account id left the computer"
! grep -q '"method": "PUT"' "${LHUB_DIR}/log" || fail "hub: reported without holding the lease"

# This computer holds the lease: it fetches and reports the windows.
rm -f "$LCACHE" "${LHUB_DIR}/log"
printf '{"fetch":true,"windows":null,"age_seconds":null,"blocked_seconds":null}' >"${LHUB_DIR}/claim.json"
export AI_TODO_LIMITS_HTTP_STATUS=200
export AI_TODO_LIMITS_HTTP_BODY='{"five_hour":{"utilization":44,"resets_at":"2026-10-18T15:00:00Z"}}'
[[ "$(limits_5h)" == "44.0" ]] || fail "hub: the lease holder did not fetch"
python3 - "${LHUB_DIR}/log" "$ACCOUNT_KEY" "$TOKEN" <<'PY' || fail "hub: report: $(cat "${LHUB_DIR}/log")"
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
put = [l for l in lines if l["method"] == "PUT"]
assert len(put) == 1 and put[0]["path"] == "/api/limits/" + sys.argv[2], lines
assert json.loads(put[0]["body"])["windows"][0]["used_percent"] == 44.0, put
assert sys.argv[3] not in open(sys.argv[1]).read()
PY

# A 429 while holding the lease pauses everyone: reported with its Retry-After.
rm -f "$LCACHE" "${LHUB_DIR}/log"
export AI_TODO_LIMITS_HTTP_STATUS=429 AI_TODO_LIMITS_RETRY_AFTER=200
status=0
"$LIMITS" --tool claude >/dev/null 2>&1 || status=$?
[[ $status -eq 75 ]] || fail "hub: 429 with nothing to show exited $status"
grep -q '"body": "{\\"rate_limited\\": true, \\"retry_after\\": 200}"' "${LHUB_DIR}/log" || fail "hub: 429 not reported: $(cat "${LHUB_DIR}/log")"

# Paused or someone else fetching, with nothing to show yet: fail without a request.
rm -f "$LCACHE" "${LHUB_DIR}/log"
printf '{"fetch":false,"windows":null,"age_seconds":null,"blocked_seconds":120}' >"${LHUB_DIR}/claim.json"
export AI_TODO_LIMITS_HTTP_STATUS=200
status=0
"$LIMITS" --tool claude >/dev/null 2>&1 || status=$?
[[ $status -eq 75 ]] || fail "hub: paused with nothing to show exited $status"
! grep -q '"method": "PUT"' "${LHUB_DIR}/log" || fail "hub: fetched while paused"
unset AI_TODO_LIMITS_CACHE AI_TODO_LIMITS_RETRY_AFTER AI_TODO_HUB_CONF
rm -f "$LCACHE" "${HOME}/.claude.json"
pass "limits_shared_per_account: reuses the hub's reading, fetches only with the lease, reports windows and 429s, never sends the account id or a token"

SID="11111111-2222-4333-8444-555555555555"
OTHER="99999999-8888-4777-8666-000000000000"
mkdir -p "${HOME}/.codex/sessions/2026/10/15" "${HOME}/.codex/sessions/2026/10/16"
cat >"${HOME}/.codex/sessions/2026/10/15/rollout-2026-10-15T10-00-00-${SID}.jsonl" <<'EOF'
{"timestamp":"2026-10-15T10:00:13.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":1791495755},"secondary":{"used_percent":50,"window_minutes":1440,"resets_at":1791495755}}}}
{"timestamp":"2026-10-15T10:00:20.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}
EOF
cat >"${HOME}/.codex/sessions/2026/10/16/rollout-2026-10-16T10-00-00-${OTHER}.jsonl" <<'EOF'
{"timestamp":"2026-10-16T10:00:13.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"window_minutes":10080,"resets_at":1791833135}}}}
EOF
"$LIMITS" --tool codex >"${SANDBOX}/limits-codex.out" 2>"${SANDBOX}/limits-codex.err" || fail "codex limits failed"
python3 - "${SANDBOX}/limits-codex.out" <<'PY' || fail "newest codex snapshot: $(cat "${SANDBOX}/limits-codex.out")"
import json, sys
data = json.load(open(sys.argv[1]))
kinds = [(w["kind"], w["used_percent"], w.get("resets_at")) for w in data["windows"]]
assert kinds == [("weekly", 99.0, "2026-10-12T19:25:35Z")], kinds
PY
"$LIMITS" --tool codex --session "$SID" >"${SANDBOX}/limits-codex-sid.out" 2>"${SANDBOX}/limits-codex-sid.err" \
  || fail "codex session limits failed: $(cat "${SANDBOX}/limits-codex-sid.err")"
python3 - "${SANDBOX}/limits-codex-sid.out" <<'PY' || fail "session codex snapshot: $(cat "${SANDBOX}/limits-codex-sid.out")"
import json, sys
data = json.load(open(sys.argv[1]))
kinds = [(w["kind"], w["used_percent"], w.get("resets_at")) for w in data["windows"]]
assert kinds == [("5h", 10.0, "2026-10-08T21:42:35Z")], kinds
PY
pass "limits_codex_windows_by_length: newest snapshot, session id wins, a 24h window is left out"

mkdir -p "${HOME}/.cursor"
printf '%s\n' "{\"accessToken\":\"${CURSOR_TOKEN}\",\"refreshToken\":\"cursor-refresh-should-not-leak\"}" >"${HOME}/.cursor/auth.json"
export AI_TODO_LIMITS_HTTP_STATUS=200
export AI_TODO_LIMITS_HTTP_BODY='{"billingCycleEnd":"1784958141000","planUsage":{"totalPercentUsed":53,"limit":7000,"totalSpend":3710},"spendLimitUsage":{"percentUsed":20,"limit":1,"used":9999}}'
"$LIMITS" --tool cursor >"${SANDBOX}/limits-cursor.out" 2>"${SANDBOX}/limits-cursor.err" || fail "cursor limits failed"
[[ ! -s "${SANDBOX}/limits-cursor.err" ]] || fail "cursor limits stderr: $(cat "${SANDBOX}/limits-cursor.err")"
! grep -q "$CURSOR_TOKEN" "${SANDBOX}/limits-cursor.out" || fail "cursor token leaked"
! grep -q "cursor-refresh-should-not-leak" "${SANDBOX}/limits-cursor.out" || fail "cursor refresh token leaked"
python3 - "${SANDBOX}/limits-cursor.out" <<'PY' || fail "cursor JSON: $(cat "${SANDBOX}/limits-cursor.out")"
import json, sys
data = json.load(open(sys.argv[1]))
kinds = [(w["kind"], w.get("scope"), w["used_percent"], w.get("resets_at")) for w in data["windows"]]
assert kinds == [("monthly", None, 53.0, "2026-07-25T05:42:21Z"), ("monthly", "on-demand", 20.0, None)], kinds
assert all(w["kind"] not in ("5h", "weekly") for w in data["windows"])
PY
export AI_TODO_LIMITS_HTTP_BODY='{"planUsage":{"totalPercentUsed":53},"spendLimitUsage":{"limit":1,"used":9999}}'
"$LIMITS" --tool cursor >"${SANDBOX}/limits-cursor-ratio.out" 2>"${SANDBOX}/limits-cursor-ratio.err" \
  || fail "cursor without an on-demand percent failed: $(cat "${SANDBOX}/limits-cursor-ratio.err")"
python3 - "${SANDBOX}/limits-cursor-ratio.out" <<'PY' || fail "on-demand was guessed from limit/used: $(cat "${SANDBOX}/limits-cursor-ratio.out")"
import json, sys
data = json.load(open(sys.argv[1]))
assert [(w["kind"], w.get("scope")) for w in data["windows"]] == [("monthly", None)], data
PY
rm -f "${HOME}/.cursor/auth.json"
"$LIMITS" --tool cursor >"${SANDBOX}/limits-cursor-none.out"
python3 - "${SANDBOX}/limits-cursor-none.out" <<'PY' || fail "cursor without a login showed limits"
import json, sys
assert json.load(open(sys.argv[1]))["windows"] == []
PY
pass "limits_cursor_monthly_only: included usage and an on-demand cap; no 5h or weekly"

status=0
"$LIMITS" --tool gemini >/dev/null 2>"${SANDBOX}/limits-bad.err" || status=$?
[[ $status -eq 64 ]] || fail "unknown tool exit was $status: $(cat "${SANDBOX}/limits-bad.err")"
status=0
"$LIMITS" --tool codex --session '../secrets' >/dev/null 2>>"${SANDBOX}/limits-bad.err" || status=$?
[[ $status -eq 64 ]] || fail "path session id exit was $status"
pass "limits_rejects_bad_arguments"

unset AI_TODO_LIMITS_OFFLINE AI_TODO_LIMITS_HTTP_BODY AI_TODO_LIMITS_HTTP_STATUS

TRANSCRIPT="${SCRIPT_DIR}/ai-todo-transcript"
T_DIR="${HOME}/.claude/projects/-home-programming"
mkdir -p "$T_DIR"
SID_A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
SID_B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
printf '%s\n' \
  '{"type":"user","message":{"content":"hello from the source"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hello back"}]}}' \
  >"${T_DIR}/${SID_A}.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"secret from the other session"}}' \
  >"${T_DIR}/${SID_B}.jsonl"
"$TRANSCRIPT" claude "$SID_A" >"${SANDBOX}/transcript.out"
grep -q "hello from the source" "${SANDBOX}/transcript.out" || fail "transcript missed the user turn: $(cat "${SANDBOX}/transcript.out")"
grep -q "hello back" "${SANDBOX}/transcript.out" || fail "transcript missed the assistant turn: $(cat "${SANDBOX}/transcript.out")"
! grep -q "secret from the other session" "${SANDBOX}/transcript.out" || fail "transcript included another session"
status=0
"$TRANSCRIPT" claude "00000000-0000-4000-8000-000000000099" >/dev/null 2>"${SANDBOX}/transcript.err" || status=$?
[[ $status -eq 94 ]] || fail "missing transcript exit was $status: $(cat "${SANDBOX}/transcript.err")"
pass "transcript_prints_one_session"

# A Cursor chat that only ended on an error has a file but no text to hand over.
U_EMPTY=cccccccc-cccc-4ccc-8ccc-cccccccccccc
mkdir -p "${HOME}/.cursor/projects/proj/agent-transcripts/${U_EMPTY}"
printf '%s\n' '{"type":"turn_ended","status":"error","error":"Total usage limit reached"}' \
  >"${HOME}/.cursor/projects/proj/agent-transcripts/${U_EMPTY}/${U_EMPTY}.jsonl"
status=0
"$TRANSCRIPT" cursor "$U_EMPTY" >"${SANDBOX}/transcript-empty.out" 2>"${SANDBOX}/transcript-empty.err" || status=$?
[[ $status -eq 94 && ! -s "${SANDBOX}/transcript-empty.out" ]] || fail "textless transcript exit was $status: $(cat "${SANDBOX}/transcript-empty.err")"
pass "transcript_without_text_is_missing"
python3 "${SCRIPT_DIR}/test-transcript.py" || fail "structured chat transcript regression tests"
"$TRANSCRIPT" claude "$SID_A" --json >"${SANDBOX}/chat.json"
python3 - "${SANDBOX}/chat.json" <<'PY' || fail "structured transcript CLI response"
import json, sys
messages = json.load(open(sys.argv[1]))
assert messages == [
    {"id": "0", "role": "user", "text": "hello from the source"},
    {"id": "1", "role": "assistant", "text": "hello back"},
], messages
PY
pass "chat transcript preserves roles, blank lines and indentation"
python3 "${SCRIPT_DIR}/test-status.py" || fail "Codex status delivery/runtime regressions"
pass "Codex runtime state, concurrency, durable retries and executable discovery"

# --- ai-todo-mcp ------------------------------------------------------------------

MCP="${SCRIPT_DIR}/ai-todo-mcp"
MCP_DIR="${HOME}/.ai-remote/mcp"
rm -rf "$MCP_DIR"
mkdir -p "$MCP_DIR"
# The Spread Mac's server shapes, with fake values.
cat >"${MCP_DIR}/grafana.json" <<'EOF'
{"mcpServers":{"grafana":{"command":"docker","args":["run","--rm","-i","-e","GRAFANA_URL","-e","GRAFANA_SERVICE_ACCOUNT_TOKEN","mcp/grafana","-t","stdio"],"env":{"GRAFANA_URL":"https://grafana.example.test"}}}}
EOF
cat >"${MCP_DIR}/slack.json" <<'EOF'
{"mcpServers":{"slack":{"command":"docker","args":["run","--rm","-i","-e","SLACK_MCP_XOXP_TOKEN","ghcr.io/example/slack-mcp"],"env":{"SLACK_TEAM_ID":"T0FAKETEAM"}}}}
EOF
cat >"${MCP_DIR}/atlassian.json" <<'EOF'
{"mcpServers":{"mcp-atlassian":{"command":"docker","args":["run","--rm","-i","-e","CONFLUENCE_URL","-e","CONFLUENCE_USERNAME","-e","CONFLUENCE_API_TOKEN","-e","JIRA_URL","-e","JIRA_USERNAME","-e","JIRA_API_TOKEN","ghcr.io/sooperset/mcp-atlassian:latest"],
 "env":{"CONFLUENCE_URL":"https://example.atlassian.net/wiki","CONFLUENCE_USERNAME":"${ATLASSIAN_EMAIL}","CONFLUENCE_API_TOKEN":"${ATLASSIAN_API_TOKEN}","JIRA_URL":"https://example.atlassian.net","JIRA_USERNAME":"${ATLASSIAN_EMAIL}","JIRA_API_TOKEN":"${ATLASSIAN_API_TOKEN}"}}}}
EOF
cat >"${MCP_DIR}/github.json" <<'EOF'
{"mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_TOKEN}"}}}}
EOF
MCP_CODEX="${SANDBOX}/mcp-codex"
mkdir -p "$MCP_CODEX"
cat >"${MCP_CODEX}/config.toml" <<'EOF'
model = "gpt-5"

[mcp_servers.grafana]
command = "docker"

[mcp_servers.grafana.env]
GRAFANA_URL = "https://grafana.example.test"

[mcp_servers.miro]
url = "https://mcp.miro.example/"

[mcp_servers."node_repl"]
command = "node"

[mcp_servers.computer-use]
command = "computer-use"
EOF

"$MCP" list --json >"${SANDBOX}/mcp-list.out" 2>"${SANDBOX}/mcp-list.err" || fail "mcp list failed: $(cat "${SANDBOX}/mcp-list.err")"
python3 - "${SANDBOX}/mcp-list.out" <<'PY' || fail "mcp list is wrong: $(cat "${SANDBOX}/mcp-list.out")"
import json, sys
servers = json.load(open(sys.argv[1]))
assert [s["name"] for s in servers] == ["atlassian", "github", "grafana", "slack"], servers
by = {s["name"]: s for s in servers}
assert all(set(s) == {"name", "kind", "summary", "error"} for s in servers), servers
assert all(s["error"] is None for s in servers), servers
assert by["github"]["kind"] == "http" and by["github"]["summary"] == "https://api.githubcopilot.com/mcp/", by["github"]
assert by["grafana"]["kind"] == "stdio" and by["grafana"]["summary"].startswith("docker run --rm -i"), by["grafana"]
assert all(len(s["summary"]) <= 120 for s in servers), servers
PY
for secret in '${' Bearer GITHUB_TOKEN ATLASSIAN_EMAIL T0FAKETEAM example.atlassian.net grafana.example.test; do
  ! grep -qF "$secret" "${SANDBOX}/mcp-list.out" || fail "mcp list printed '$secret': $(cat "${SANDBOX}/mcp-list.out")"
done
[[ "$(HOME="${SANDBOX}/no-mcp-home" "$MCP" list --json)" == "[]" ]] || fail "mcp list without the folder is not []"
pass "list_json_hides_secrets"

eval "set -- $("$MCP" launch-args claude grafana,slack)"
[[ "$*" == "--strict-mcp-config --mcp-config ${MCP_DIR}/grafana.json --mcp-config ${MCP_DIR}/slack.json" ]] \
  || fail "claude launch args: $*"
eval "set -- $("$MCP" launch-args claude '')"
[[ $# -eq 1 && "$1" == "--strict-mcp-config" ]] || fail "claude empty selection: $*"
pass "launch_args_claude_strict"

mcp_codex_args() { CODEX_HOME="$MCP_CODEX" "$MCP" launch-args codex "$1"; }
eval "set -- $(mcp_codex_args grafana)"
joined=" $* "
[[ "$joined" == *" -c mcp_servers.miro.enabled=false "* ]] || fail "codex did not disable miro: $*"
[[ "$joined" != *"grafana.enabled=false"* ]] || fail "codex disabled the selected grafana: $*"
[[ "$joined" == *' -c mcp_servers.grafana.command="/bin/sh" '* ]] || fail "codex did not add grafana: $*"
[[ "$joined" == *" -c mcp_servers.grafana.enabled=true "* ]] || fail "codex did not enable the selected grafana: $*"
eval "set -- $(mcp_codex_args '')"
# The Codex app's own servers (node_repl, computer-use) stay.
[[ "$*" == "-c mcp_servers.grafana.enabled=false -c mcp_servers.miro.enabled=false" ]] \
  || fail "codex empty selection: $*"
pass "launch_args_codex_disables_unselected_config_servers"

# The keep file lists more keys that stay; blank lines and comments are ignored.
printf '# servers to keep\n\n  miro  \n#grafana\n' >"${MCP_DIR}/keep"
eval "set -- $(mcp_codex_args '')"
[[ "$*" == "-c mcp_servers.grafana.enabled=false" ]] || fail "codex with a keep file: $*"
[[ "$("$MCP" list --json)" != *'"keep"'* ]] || fail "list shows the keep file"
rm "${MCP_DIR}/keep"
pass "launch_args_codex_keep_file"

# A selected server that config.toml turns off is turned on.
OFF_CODEX="${SANDBOX}/mcp-codex-off"
mkdir -p "$OFF_CODEX"
printf '[mcp_servers.slack]\ncommand = "docker"\nenabled = false\n' >"${OFF_CODEX}/config.toml"
eval "set -- $(CODEX_HOME="$OFF_CODEX" "$MCP" launch-args codex slack)"
[[ " $* " == *" -c mcp_servers.slack.enabled=true "* && " $* " != *"enabled=false"* ]] || fail "codex did not enable slack: $*"
pass "launch_args_codex_enables_selected"

# An undecodable config.toml disables nothing; an undecodable server file is skipped.
printf '[mcp_servers.miro]\nurl = "\377\376"\n' >"${OFF_CODEX}/config.toml"
status=0
out="$(CODEX_HOME="$OFF_CODEX" "$MCP" launch-args codex slack 2>"${SANDBOX}/mcp-decode.err")" || status=$?
[[ $status -eq 0 && "$out" == *slack.enabled=true* && "$out" != *enabled=false* ]] \
  || fail "codex with a non-UTF-8 config.toml: $status $out $(cat "${SANDBOX}/mcp-decode.err")"
printf '{"mcpServers":{"bad":{"command":"\377"}}}' >"${MCP_DIR}/latin.json"
status=0
out="$("$MCP" launch-args claude latin,slack 2>"${SANDBOX}/mcp-decode.err")" || status=$?
[[ $status -eq 0 && "$out" == *slack.json* && "$out" != *latin* ]] || fail "claude with a non-UTF-8 server file: $status $out"
grep -qx "ai-todo-mcp: skipped latin: not UTF-8" "${SANDBOX}/mcp-decode.err" || fail "non-UTF-8 skip: $(cat "${SANDBOX}/mcp-decode.err")"
python3 - "$("$MCP" list --json)" <<'PY' || fail "list does not show the non-UTF-8 file with an error"
import json, sys
by = {s["name"]: s for s in json.loads(sys.argv[1])}
assert by["latin"]["error"] == "not UTF-8", by["latin"]
PY
rm "${MCP_DIR}/latin.json"
rm -rf "$OFF_CODEX"
pass "launch_args_survive_undecodable_files"

# Non-BMP characters stay literal: TOML has no surrogate-pair escapes.
printf '{"mcpServers":{"emoji":{"command":"echo","args":["hi \360\237\231\202"]}}}' >"${MCP_DIR}/emoji.json"
eval "set -- $(mcp_codex_args emoji)"
emoji_args=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == -c && "$2" == mcp_servers.emoji.args=* ]] && emoji_args="${2#mcp_servers.emoji.args=}"
  shift
done
[[ "$emoji_args" == *'"hi '$'\360\237\231\202''"]' && "$emoji_args" != *'\u'* ]] || fail "codex emoji arg: $emoji_args"
rm "${MCP_DIR}/emoji.json"
pass "launch_args_codex_non_bmp_literal"

eval "set -- $(mcp_codex_args atlassian)"
[[ " $* " == *' -c mcp_servers.mcp-atlassian.command="/bin/sh" '* ]] || fail "codex atlassian command: $*"
atlassian_args=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == -c && "$2" == mcp_servers.mcp-atlassian.args=* ]] && atlassian_args="${2#mcp_servers.mcp-atlassian.args=}"
  shift
done
[[ -n "$atlassian_args" ]] || fail "codex atlassian has no args"
python3 - "$atlassian_args" "${SANDBOX}/mcp-wrapper" <<'PY' || fail "codex atlassian args are wrong: $atlassian_args"
import json, sys
args = json.loads(sys.argv[1])
assert args[0] == "-c" and args[2] == "ai-todo-mcp" and args[3] == "docker", args
assert args[4:] == ["run", "--rm", "-i", "-e", "CONFLUENCE_URL", "-e", "CONFLUENCE_USERNAME", "-e", "CONFLUENCE_API_TOKEN",
                    "-e", "JIRA_URL", "-e", "JIRA_USERNAME", "-e", "JIRA_API_TOKEN", "ghcr.io/sooperset/mcp-atlassian:latest"], args
script = args[1]
assert 'export CONFLUENCE_USERNAME="${ATLASSIAN_EMAIL}"' in script, script
assert "export CONFLUENCE_URL='https://example.atlassian.net/wiki'" in script, script
assert script.endswith('exec "$@"'), script
open(sys.argv[2], "w").write(script)
PY
printf 'ATLASSIAN_EMAIL=a@b\nATLASSIAN_API_TOKEN=fake-token\n' >"${MCP_DIR}/env"
printf '#!/bin/sh\necho "$CONFLUENCE_USERNAME $ATLASSIAN_API_TOKEN $*"\n' >"${SANDBOX}/bin/fake-mcp-server"
chmod +x "${SANDBOX}/bin/fake-mcp-server"
out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c "$(cat "${SANDBOX}/mcp-wrapper")" ai-todo-mcp "${SANDBOX}/bin/fake-mcp-server" one 'two words')"
[[ "$out" == "a@b fake-token one two words" ]] || fail "codex stdio wrapper printed '$out'"
rm "${MCP_DIR}/env"
out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c "$(cat "${SANDBOX}/mcp-wrapper")" ai-todo-mcp "${SANDBOX}/bin/fake-mcp-server" x)"
[[ "$out" == "  x" ]] || fail "codex stdio wrapper without an env file printed '$out'"
pass "launch_args_codex_stdio_wraps_env"

eval "set -- $(mcp_codex_args github)"
joined=" $* "
[[ "$joined" == *' -c mcp_servers.github.url="https://api.githubcopilot.com/mcp/" '* ]] || fail "codex github url: $*"
[[ "$joined" == *' -c mcp_servers.github.bearer_token_env_var="GITHUB_TOKEN" '* ]] || fail "codex github bearer: $*"
[[ "$joined" != *Bearer* ]] || fail "codex github passed the header value: $*"
cat >"${MCP_DIR}/keyed.json" <<'EOF'
{"mcpServers":{"keyed":{"type":"http","url":"https://keyed.example/mcp","headers":{"X-Api-Key":"${KEYED_KEY}"}}}}
EOF
cat >"${MCP_DIR}/literal.json" <<'EOF'
{"mcpServers":{"literal":{"type":"http","url":"https://literal.example/mcp","headers":{"Authorization":"Bearer sk-literal-DO-NOT-LEAK"}}}}
EOF
eval "set -- $(mcp_codex_args keyed,literal 2>"${SANDBOX}/mcp-headers.err")"
[[ " $* " == *' -c mcp_servers.keyed.env_http_headers.X-Api-Key="KEYED_KEY" '* ]] || fail "codex env_http_headers: $*"
[[ " $* " != *literal.example* ]] || fail "codex passed a literal header server: $*"
grep -qx "ai-todo-mcp: skipped literal: header can't be passed without its value" "${SANDBOX}/mcp-headers.err" \
  || fail "literal header skip: $(cat "${SANDBOX}/mcp-headers.err")"
! grep -q 'DO-NOT-LEAK' "${SANDBOX}/mcp-headers.err" || fail "the skip printed the header value"
rm "${MCP_DIR}/keyed.json" "${MCP_DIR}/literal.json"
pass "launch_args_codex_http_bearer"

printf '{ not json' >"${MCP_DIR}/broken.json"
for tool in claude codex; do
  status=0
  out="$(CODEX_HOME="$MCP_CODEX" "$MCP" launch-args "$tool" grafana,gone,broken 2>"${SANDBOX}/mcp-skip.err")" || status=$?
  [[ $status -eq 0 ]] || fail "$tool launch-args with skips exited $status"
  [[ "$out" == *grafana* && "$out" != *gone* && "$out" != *broken* ]] || fail "$tool launch-args with skips: $out"
  [[ "$(grep -c '^ai-todo-mcp: skipped ' "${SANDBOX}/mcp-skip.err")" -eq 2 ]] || fail "$tool skip lines: $(cat "${SANDBOX}/mcp-skip.err")"
  grep -q '^ai-todo-mcp: skipped gone: ' "${SANDBOX}/mcp-skip.err" && grep -q '^ai-todo-mcp: skipped broken: ' "${SANDBOX}/mcp-skip.err" \
    || fail "$tool skip lines: $(cat "${SANDBOX}/mcp-skip.err")"
done
python3 - "$("$MCP" list --json)" <<'PY' || fail "list does not show the broken file with an error"
import json, sys
by = {s["name"]: s for s in json.loads(sys.argv[1])}
assert by["broken"]["error"], by["broken"]
PY
rm "${MCP_DIR}/broken.json"
pass "launch_args_skip_missing_and_malformed"

for bad in "claude ../x" "claude a/b" "claude grafana,../x" "cursor grafana" "claude"; do
  status=0
  # shellcheck disable=SC2086
  "$MCP" launch-args $bad >/dev/null 2>&1 || status=$?
  [[ $status -eq 64 ]] || fail "launch-args $bad exited $status, expected 64"
done
long_name="$(printf 'a%.0s' $(seq 1 65))"
for bad in "$long_name" "grafana,${long_name}" . ..; do
  status=0
  "$MCP" launch-args claude "$bad" >/dev/null 2>&1 || status=$?
  [[ $status -eq 64 ]] || fail "launch-args claude '$bad' exited $status, expected 64"
done
status=0
"$MCP" bogus >/dev/null 2>&1 || status=$?
[[ $status -eq 64 ]] || fail "unknown command exited $status"
pass "launch_args_rejects_bad_names"

# Names may start with ".", "_" or "-" and be up to 64 characters, as on the hub.
max_name="$(printf 'b%.0s' $(seq 1 64))"
for odd in _x .dot -dash "$max_name"; do
  cp "${MCP_DIR}/slack.json" "${MCP_DIR}/${odd}.json"
done
python3 - "$("$MCP" list --json)" "$max_name" <<'PY' || fail "list hides names allowed on the hub: $("$MCP" list --json)"
import json, sys
names = [s["name"] for s in json.loads(sys.argv[1])]
for n in ("_x", ".dot", "-dash", sys.argv[2]):
    assert n in names, (n, names)
PY
eval "set -- $("$MCP" launch-args claude "_x,.dot,-dash,${max_name}")"
[[ "$*" == "--strict-mcp-config --mcp-config ${MCP_DIR}/_x.json --mcp-config ${MCP_DIR}/.dot.json --mcp-config ${MCP_DIR}/-dash.json --mcp-config ${MCP_DIR}/${max_name}.json" ]] \
  || fail "claude launch args for hub-valid names: $*"
for odd in _x .dot -dash "$max_name"; do rm "${MCP_DIR}/${odd}.json"; done
pass "names_match_the_hub_rule"

# --- ai-todo-open --mcp --------------------------------------------------------------
# Uses the server files above and the ai-todo-hook fake hub (HUB_LOG, CONF).

MCP_ARGV="${SANDBOX}/mcp-argv.log"
MCP_TOOL="${SANDBOX}/bin/mcp-tool"
# Records its arguments as [one][two words][three], then stays alive like a real session.
cat >"$MCP_TOOL" <<EOF
#!/bin/sh
for a in "\$@"; do printf '[%s]' "\$a"; done >>"$MCP_ARGV"
echo >>"$MCP_ARGV"
exec sleep 300
EOF
chmod +x "$MCP_TOOL"
open_mcp() { AI_TODO_HUB_CONF="$CONF" AI_TODO_OPEN_DETACH=1 "$OPEN" "$@"; }
mcp_posts() { grep -c '"path": "/api/conversations/mcp"' "$HUB_LOG" || true; }
wait_for_mcp_posts() { # <count>
  for _ in $(seq 1 50); do [[ $(mcp_posts) -ge $1 ]] && return 0; sleep 0.1; done
  fail "expected $1 MCP reports, got $(mcp_posts): $(cat "$HUB_LOG")"
}
last_mcp_post() { # the newest MCP report: its auth header, then the body as sorted compact JSON
  python3 - "$HUB_LOG" <<'PY'
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
req = [r for r in reqs if r["path"] == "/api/conversations/mcp"][-1]
print(req["auth"], json.dumps(req["body"], sort_keys=True, separators=(",", ":")))
PY
}
wait_for_argv_lines() { # <count>
  for _ in $(seq 1 50); do [[ -f "$MCP_ARGV" && $(wc -l <"$MCP_ARGV") -ge $1 ]] && return 0; sleep 0.1; done
  fail "the fake tool did not start (expected $1 argv lines)"
}

C_M1=aaaaaaaa-0000-4000-8000-000000000001
posts=$(mcp_posts)
out="$(AI_TODO_CLAUDE_BIN="$MCP_TOOL" open_mcp --mcp grafana,gone "ai/claude/todo-mcp1" '~/programming' "$C_M1" 2>"${SANDBOX}/mcp-open.err")" \
  || fail "claude open with --mcp failed: $(cat "${SANDBOX}/mcp-open.err")"
[[ "$out" == created ]] || fail "claude open with --mcp printed '$out'"
wait_for_argv_lines 1
[[ "$(tail -n 1 "$MCP_ARGV")" == "[--strict-mcp-config][--mcp-config][${MCP_DIR}/grafana.json][--session-id][${C_M1}]" ]] \
  || fail "claude argv with --mcp: $(tail -n 1 "$MCP_ARGV")"
grep -q '^ai-todo-mcp: skipped gone: ' "${SANDBOX}/mcp-open.err" || fail "skipped server not shown: $(cat "${SANDBOX}/mcp-open.err")"
# The attach clears stderr from the screen: the skip shows in the session's client too.
# A control-mode client receives it as a %message line.
( sleep 8 ) | tmux -L "$SOCK" -C attach -t "=ai/claude/todo-mcp1" >"${SANDBOX}/mcp-client.out" 2>&1 &
mcp_client=$!
for _ in $(seq 1 60); do grep -q '^%message ' "${SANDBOX}/mcp-client.out" && break; sleep 0.2; done
kill "$mcp_client" 2>/dev/null || true
grep -qx '%message ai-todo-mcp: skipped gone: not found' "${SANDBOX}/mcp-client.out" \
  || fail "skip not shown in the tmux client: $(cat "${SANDBOX}/mcp-client.out")"
wait_for_mcp_posts $((posts + 1))
[[ "$(last_mcp_post)" == "Bearer s3cret {\"mcp_servers\":[\"grafana\"],\"session_id\":\"${C_M1}\",\"tool\":\"claude\"}" ]] \
  || fail "claude MCP report: $(last_mcp_post)"
pass "open_claude_with_mcp"

posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
out="$(CODEX_HOME="$MCP_CODEX" AI_TODO_CODEX_BIN="$MCP_TOOL" open_mcp --mcp grafana "ai/codex/todo-mcp2" '~/programming' "$X_LINKED" codex)"
[[ "$out" == resumed ]] || fail "codex resume with --mcp printed '$out'"
wait_for_argv_lines $((lines + 1))
argv="$(tail -n 1 "$MCP_ARGV")"
[[ "$argv" == "[-c]"*"[resume][${X_LINKED}][--approve-for-me]" ]] || fail "codex argv with --mcp: $argv"
[[ "$argv" == *"[-c][mcp_servers.miro.enabled=false]"* && "$argv" == *'[-c][mcp_servers.grafana.command="/bin/sh"]'* ]] \
  || fail "codex argv lacks the MCP overrides: $argv"
wait_for_mcp_posts $((posts + 1))
[[ "$(last_mcp_post)" == "Bearer s3cret {\"mcp_servers\":[\"grafana\"],\"session_id\":\"${X_LINKED}\",\"tool\":\"codex\"}" ]] \
  || fail "codex MCP report: $(last_mcp_post)"
pass "open_codex_resume_with_mcp"

MCP_FRESH="${SANDBOX}/bin/codex-mcp-fresh"
cat >"$MCP_FRESH" <<EOF
#!/bin/sh
mkdir -p "\$HOME/.codex/sessions/2026/10/25"
echo '$META_CLI' > "\$HOME/.codex/sessions/2026/10/25/rollout-2026-10-25T00-00-00-NEWMCPX.jsonl"
exec "$MCP_TOOL" "\$@"
EOF
chmod +x "$MCP_FRESH"
# The app stores a fresh conversation's id on the hub only after it reads `created <id>`,
# so the first report can get a 404: the script tries again.
posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
: >"${SANDBOX}/not-found-once"
out="$(CODEX_HOME="$MCP_CODEX" AI_TODO_CODEX_BIN="$MCP_FRESH" AI_TODO_MCP_REPORT_DELAY=0.2 \
  open_mcp --mcp slack "ai/codex/todo-mcp3" '~/programming' - codex)"
[[ "$out" == "created NEWMCPX" ]] || fail "fresh codex with --mcp printed '$out'"
wait_for_argv_lines $((lines + 1))
[[ "$(tail -n 1 "$MCP_ARGV")" == "[-c]"*'[-c][mcp_servers.slack.command="/bin/sh"]'* ]] || fail "fresh codex argv: $(tail -n 1 "$MCP_ARGV")"
wait_for_mcp_posts $((posts + 2))
[[ ! -e "${SANDBOX}/not-found-once" ]] || fail "the fake hub never answered 404"
python3 - "$HUB_LOG" <<'PY2' || fail "fresh codex MCP reports: $(tail -n 2 "$HUB_LOG")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
last = [r for r in reqs if r["path"] == "/api/conversations/mcp"][-2:]
want = {"tool": "codex", "session_id": "NEWMCPX", "mcp_servers": ["slack"]}
assert [r["body"] for r in last] == [want, want], last
assert all(r["auth"] == "Bearer s3cret" for r in last), last
PY2
sleep 0.6
[[ $(mcp_posts) -eq $((posts + 2)) ]] || fail "the report was retried after the hub accepted it: $(mcp_posts) posts"
pass "open_codex_new_reports_after_id"

posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
out="$(AI_TODO_CLAUDE_BIN="$MCP_TOOL" open_mcp --mcp slack "ai/claude/todo-mcp1" '~/programming' "$C_M1")"
[[ "$out" == attach ]] || fail "second open with another --mcp printed '$out'"
sleep 0.5
[[ $(wc -l <"$MCP_ARGV") -eq $lines ]] || fail "attach started the tool again: $(tail -n 1 "$MCP_ARGV")"
[[ $(mcp_posts) -eq $posts ]] || fail "attach reported MCP servers: $(last_mcp_post)"
pass "open_attach_ignores_mcp"

# The tmux server's environment lacks the variable; the env file supplies it (a plain
# VAR=value line is exported too). The wrapper execs, so the pane's process is the tool.
printf 'ATLASSIAN_EMAIL=x@y\n' >"${MCP_DIR}/env"
ENV_TOOL="${SANDBOX}/bin/env-tool"
ENV_OUT="${SANDBOX}/env-tool.out"
printf '#!/bin/sh\nprintf "%%s\\n" "${ATLASSIAN_EMAIL:-unset}" >"%s"\nsleep 300\n' "$ENV_OUT" >"$ENV_TOOL"
chmod +x "$ENV_TOOL"
ESOCK="${SOCK}-mcpenv"
env -i HOME="$HOME" PATH=/usr/bin:/bin "$(command -v tmux)" -L "$ESOCK" new-session -d -s keep -- sleep 300
C_M5=aaaaaaaa-0000-4000-8000-000000000005
env -u ATLASSIAN_EMAIL AI_TODO_TMUX_SOCKET="$ESOCK" AI_TODO_CLAUDE_BIN="$ENV_TOOL" AI_TODO_HUB_CONF="$CONF" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" --mcp grafana "ai/claude/todo-mcp5" '~/programming' "$C_M5" >/dev/null || fail "open with the env file failed"
for _ in $(seq 1 50); do [[ -s "$ENV_OUT" ]] && break; sleep 0.1; done
env_seen="$(cat "$ENV_OUT" 2>/dev/null || true)"
pane_pid="$(tmux -L "$ESOCK" list-panes -t "=ai/claude/todo-mcp5" -F '#{pane_pid}')"
pane_args="$(ps -o args= -p "$pane_pid")"
[[ "$env_seen" == "x@y" ]] || fail "the tool did not get ATLASSIAN_EMAIL from the env file: '$env_seen'"
[[ "$pane_args" == "/bin/sh ${ENV_TOOL} "*" --session-id ${C_M5}" ]] || fail "the pane's process is not the tool: $pane_args"
pass "open_sources_mcp_env_file"

# No --mcp: today's arguments, no env file wrapper and no report, even with the env file present.
C_M6=aaaaaaaa-0000-4000-8000-000000000006
posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
rm -f "$ENV_OUT"
env -u ATLASSIAN_EMAIL AI_TODO_TMUX_SOCKET="$ESOCK" AI_TODO_CLAUDE_BIN="$ENV_TOOL" AI_TODO_HUB_CONF="$CONF" AI_TODO_OPEN_DETACH=1 \
  "$OPEN" "ai/claude/todo-mcp6" '~/programming' "$C_M6" >/dev/null || fail "open without --mcp failed"
for _ in $(seq 1 50); do [[ -s "$ENV_OUT" ]] && break; sleep 0.1; done
env_seen="$(cat "$ENV_OUT" 2>/dev/null || true)"
tmux -L "$ESOCK" kill-server >/dev/null 2>&1 || true
[[ "$env_seen" == unset ]] || fail "open without --mcp read the env file: $env_seen"
out="$(AI_TODO_CLAUDE_BIN="$MCP_TOOL" open_mcp "ai/claude/todo-mcp6" '~/programming' "$C_M6")"
[[ "$out" == created ]] || fail "open without --mcp printed '$out'"
wait_for_argv_lines $((lines + 1))
[[ "$(tail -n 1 "$MCP_ARGV")" == "[--session-id][${C_M6}]" ]] || fail "argv without --mcp: $(tail -n 1 "$MCP_ARGV")"
sleep 0.5
[[ $(mcp_posts) -eq $posts ]] || fail "open without --mcp reported MCP servers: $(last_mcp_post)"
rm "${MCP_DIR}/env"
pass "open_without_mcp_unchanged"

C_M7=aaaaaaaa-0000-4000-8000-000000000007
posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
out="$(AI_TODO_CLAUDE_BIN="$MCP_TOOL" open_mcp --mcp '' "ai/claude/todo-mcp7" '~/programming' "$C_M7")"
[[ "$out" == created ]] || fail "open with --mcp '' printed '$out'"
wait_for_argv_lines $((lines + 1))
[[ "$(tail -n 1 "$MCP_ARGV")" == "[--strict-mcp-config][--session-id][${C_M7}]" ]] || fail "argv with --mcp '': $(tail -n 1 "$MCP_ARGV")"
wait_for_mcp_posts $((posts + 1))
[[ "$(last_mcp_post)" == "Bearer s3cret {\"mcp_servers\":[],\"session_id\":\"${C_M7}\",\"tool\":\"claude\"}" ]] \
  || fail "empty MCP report: $(last_mcp_post)"
pass "open_empty_mcp_is_strict"

# Cursor has no MCP selection: --mcp is accepted and ignored, nothing is reported.
U_M8=aaaaaaaa-0000-4000-8000-000000000008
mkdir -p "${HOME}/.cursor/chats/workspace/${U_M8}"
posts=$(mcp_posts)
out="$(open_mcp --mcp grafana "ai/cursor/todo-mcp8" '~/programming' "$U_M8" cursor)" || fail "cursor open with --mcp failed"
[[ "$out" == resumed ]] || fail "cursor open with --mcp printed '$out'"
sleep 0.5
[[ $(mcp_posts) -eq $posts ]] || fail "cursor open reported MCP servers: $(last_mcp_post)"
pass "open_cursor_ignores_mcp"

# A failing ai-todo-mcp (not 64) starts the tool without the selection and reports nothing;
# 64 (bad arguments) still ends the open so the app retries without --mcp.
FAIL_DIR="${SANDBOX}/open-mcp-fails"
mkdir -p "$FAIL_DIR"
cp "$OPEN" "${FAIL_DIR}/ai-todo-open"
C_M9=aaaaaaaa-0000-4000-8000-000000000009
printf '#!/bin/sh\necho "Traceback: UnicodeDecodeError" >&2\nexit 1\n' >"${FAIL_DIR}/ai-todo-mcp"
chmod +x "${FAIL_DIR}/ai-todo-mcp"
posts=$(mcp_posts)
lines=$(wc -l <"$MCP_ARGV")
status=0
out="$(AI_TODO_CLAUDE_BIN="$MCP_TOOL" AI_TODO_HUB_CONF="$CONF" AI_TODO_OPEN_DETACH=1 \
  "${FAIL_DIR}/ai-todo-open" --mcp grafana "ai/claude/todo-mcp9" '~/programming' "$C_M9" 2>"${SANDBOX}/mcp-fail.err")" || status=$?
[[ $status -eq 0 && "$out" == created ]] || fail "open with a failing ai-todo-mcp: $status '$out' $(cat "${SANDBOX}/mcp-fail.err")"
grep -qx 'ai-todo-open: MCP servers not applied (ai-todo-mcp failed)' "${SANDBOX}/mcp-fail.err" \
  || fail "failing ai-todo-mcp not named: $(cat "${SANDBOX}/mcp-fail.err")"
wait_for_argv_lines $((lines + 1))
[[ "$(tail -n 1 "$MCP_ARGV")" == "[--session-id][${C_M9}]" ]] || fail "argv with a failing ai-todo-mcp: $(tail -n 1 "$MCP_ARGV")"
sleep 0.5
[[ $(mcp_posts) -eq $posts ]] || fail "a failing ai-todo-mcp was reported: $(last_mcp_post)"
tmux -L "$SOCK" kill-session -t "=ai/claude/todo-mcp9"
printf '#!/bin/sh\nexit 64\n' >"${FAIL_DIR}/ai-todo-mcp"
status=0
AI_TODO_CLAUDE_BIN="$MCP_TOOL" AI_TODO_HUB_CONF="$CONF" AI_TODO_OPEN_DETACH=1 \
  "${FAIL_DIR}/ai-todo-open" --mcp grafana "ai/claude/todo-mcp9" '~/programming' "$C_M9" >/dev/null 2>&1 || status=$?
[[ $status -eq 64 ]] || fail "ai-todo-mcp exit 64 became $status"
! tmux -L "$SOCK" has-session -t "=ai/claude/todo-mcp9" 2>/dev/null || fail "exit 64 still started the tool"
pass "open_mcp_helper_failure_starts_unmanaged"

[[ ! -e "${SANDBOX}/guard.log" ]] || fail "a test reached a real binary: $(cat "${SANDBOX}/guard.log")"
echo "All ${passes} todo script tests passed."
SUITE_COMPLETE=1
