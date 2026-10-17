#!/usr/bin/env bash
set -euo pipefail

# Fail loudly unless every test ran. bash reads a script as it goes, so a syntax error halfway
# down, or an edit to this file mid-run, used to end the run early with exit 0. Run from a
# private copy that parsed cleanly; cleanup() fails any exit that didn't reach the end.
if [[ -z "${TODO_UPDATE_TEST_COPY:-}" ]]; then
  TODO_UPDATE_TEST_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  TODO_UPDATE_TEST_COPY="$(mktemp)"
  cp "$0" "$TODO_UPDATE_TEST_COPY"
  if ! bash -n "$TODO_UPDATE_TEST_COPY"; then
    rm -f "$TODO_UPDATE_TEST_COPY"
    echo "FAIL: $0 does not parse" >&2
    exit 1
  fi
  export TODO_UPDATE_TEST_SCRIPT_DIR TODO_UPDATE_TEST_COPY
  exec bash "$TODO_UPDATE_TEST_COPY" "$@"
fi
SCRIPT_DIR="$TODO_UPDATE_TEST_SCRIPT_DIR"
SCRIPT_COPY="$TODO_UPDATE_TEST_COPY"
unset TODO_UPDATE_TEST_SCRIPT_DIR TODO_UPDATE_TEST_COPY
UPDATE="$SCRIPT_DIR/todo-update.sh"
MAKE_RELEASE="$SCRIPT_DIR/fixtures/make_release.sh"

GOOD_SHA="aabbccddeeff00112233445566778899aabbccdd"
BAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
HEALTH_FAIL_SHA="cafebabecafebabecafebabecafebabecafebabe"
MISMATCH_SHA="5555555555555555555555555555555555555555"
RESTART_FAIL_SHA="6666666666666666666666666666666666666666"
PRUNE_SHA_1="1111111111111111111111111111111111111111"
PRUNE_SHA_2="2222222222222222222222222222222222222222"
PRUNE_SHA_3="3333333333333333333333333333333333333333"
PRUNE_SHA_4="4444444444444444444444444444444444444444"

tmpdir="$(mktemp -d)"
health_pid=""
release_pid=""
suite_complete=""

cleanup() {
  local status=$?
  [[ -n "${health_pid:-}" ]] && kill "$health_pid" 2>/dev/null || true
  [[ -n "${release_pid:-}" ]] && kill "$release_pid" 2>/dev/null || true
  rm -rf "$tmpdir" "$SCRIPT_COPY"
  if [[ -z "$suite_complete" ]]; then
    echo "FAIL: tests stopped before the end" >&2
    ((status != 0)) || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

find_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

publish_release() {
  local sha="$1"
  "$MAKE_RELEASE" "$RELEASE_FIXTURE" "$sha"
}

[[ -x "$MAKE_RELEASE" ]] || fail "missing $MAKE_RELEASE"

SYSTEMCTL_STUB="$tmpdir/systemctl-stub.sh"
SYSTEMCTL_LOG="$tmpdir/systemctl.log"
SYSTEMCTL_MODE="$tmpdir/systemctl.mode"
echo ok >"$SYSTEMCTL_MODE"
cat > "$SYSTEMCTL_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SYSTEMCTL_LOG"
mode="\$(cat "$SYSTEMCTL_MODE" 2>/dev/null || true)"
if [[ "\$1" == "restart" && "\$mode" == "fail-restart" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$SYSTEMCTL_STUB"
touch "$SYSTEMCTL_LOG"

HEALTH_CONTROL="$tmpdir/health.mode"
echo ok >"$HEALTH_CONTROL"

HEALTH_PORT="$(find_free_port)"
python3 - "$HEALTH_PORT" "$HEALTH_CONTROL" <<'PY' &
import sys
import http.server

port = int(sys.argv[1])
control = sys.argv[2]


def health_ok() -> bool:
    try:
        with open(control, encoding="utf-8") as f:
            return f.read().strip() == "ok"
    except OSError:
        return True


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/sections" or self.path.startswith("/api/sections?"):
            if health_ok():
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"[]")
            else:
                self.send_response(503)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_args):
        pass


http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
health_pid=$!

export TODO_ROOT="$tmpdir/todo-root"
RELEASE_FIXTURE="$tmpdir/release-fixture"
publish_release "$GOOD_SHA"

RELEASE_PORT="$(find_free_port)"
python3 -m http.server "$RELEASE_PORT" --bind 127.0.0.1 --directory "$RELEASE_FIXTURE" &
release_pid=$!
sleep 0.5

export TODO_RELEASE_BASE="http://127.0.0.1:${RELEASE_PORT}"
export TODO_HEALTH_URL="http://127.0.0.1:${HEALTH_PORT}/api/sections"
export TODO_SYSTEMCTL="$SYSTEMCTL_STUB"
export KEEP_RELEASES="${KEEP_RELEASES:-3}"

if [[ ! -x "$UPDATE" ]]; then
  fail "todo-update.sh missing or not executable (expected before implementation)"
fi

# First run: install release and flip current
if ! "$UPDATE" >"$tmpdir/first.out" 2>"$tmpdir/first.err"; then
  cat "$tmpdir/first.out" "$tmpdir/first.err" >&2
  fail "first update run failed"
fi
grep -q "deployed $GOOD_SHA" "$tmpdir/first.out" || fail "first run did not report deploy"

current_target="$(readlink -f "$TODO_ROOT/current" 2>/dev/null || true)"
expected_target="$(readlink -f "$TODO_ROOT/releases/$GOOD_SHA")"
[[ "$current_target" == "$expected_target" ]] || fail "current does not point at releases/$GOOD_SHA"
[[ -x "$TODO_ROOT/releases/$GOOD_SHA/todo-server" ]] || fail "todo-server missing in release"
grep -q 'restart todo' "$SYSTEMCTL_LOG" || fail "systemctl restart not recorded"

pass "first run installed release and updated current"

# Second run: no-op
if ! "$UPDATE" >"$tmpdir/second.out" 2>"$tmpdir/second.err"; then
  cat "$tmpdir/second.out" "$tmpdir/second.err" >&2
  fail "second update run failed"
fi
grep -q "already at $GOOD_SHA" "$tmpdir/second.out" || fail "second run was not a no-op"
current_after="$(readlink -f "$TODO_ROOT/current")"
[[ "$current_after" == "$expected_target" ]] || fail "current changed on no-op run"

pass "second run is no-op"

# Bad release: incomplete payload (no server binary) must not move current
mkdir -p "$tmpdir/bad-payload"
printf '%s\n' "$BAD_SHA" > "$tmpdir/bad-payload/SHA"
tar -C "$tmpdir/bad-payload" -czf "$RELEASE_FIXTURE/todo-pi.tar.gz" SHA
printf '%s\n' "$BAD_SHA" > "$RELEASE_FIXTURE/SHA"

set +e
"$UPDATE" >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] || fail "bad release update should fail"
current_bad="$(readlink -f "$TODO_ROOT/current")"
[[ "$current_bad" == "$expected_target" ]] || fail "current moved after bad release"
[[ ! -d "$TODO_ROOT/releases/$BAD_SHA" ]] || fail "incomplete release dir should be removed"

pass "bad release left current unchanged"

# Payload SHA mismatch: extracted SHA disagrees with the remote manifest SHA
# (e.g. mid-publish clobber). Must abort without flipping current and must
# not overwrite/trust the mismatched extracted SHA.
mkdir -p "$tmpdir/mismatch-payload"
cat > "$tmpdir/mismatch-payload/todo-server" <<'EOF'
#!/bin/sh
echo fake-server
EOF
chmod +x "$tmpdir/mismatch-payload/todo-server"
printf '%s\n' "$GOOD_SHA" > "$tmpdir/mismatch-payload/SHA"
tar -C "$tmpdir/mismatch-payload" -czf "$RELEASE_FIXTURE/todo-pi.tar.gz" todo-server SHA
printf '%s\n' "$MISMATCH_SHA" > "$RELEASE_FIXTURE/SHA"

set +e
"$UPDATE" >"$tmpdir/mismatch.out" 2>"$tmpdir/mismatch.err"
mismatch_rc=$?
set -e
[[ "$mismatch_rc" -ne 0 ]] || fail "SHA mismatch update should fail"
grep -q "payload SHA mismatch" "$tmpdir/mismatch.err" || fail "expected SHA mismatch message on stderr"
current_mismatch="$(readlink -f "$TODO_ROOT/current")"
[[ "$current_mismatch" == "$expected_target" ]] || fail "current moved after SHA mismatch"
[[ ! -d "$TODO_ROOT/releases/$MISMATCH_SHA" ]] || fail "mismatched release dir should be removed"

pass "payload SHA mismatch left current unchanged"

# Health failure after symlink flip: rollback to previous release
publish_release "$HEALTH_FAIL_SHA"
echo fail >"$HEALTH_CONTROL"
restart_before_health_fail="$(grep -c 'restart todo' "$SYSTEMCTL_LOG" || true)"

set +e
"$UPDATE" >"$tmpdir/health-fail.out" 2>"$tmpdir/health-fail.err"
health_fail_rc=$?
set -e
[[ "$health_fail_rc" -ne 0 ]] || fail "health-fail update should exit non-zero"
grep -q "health check failed; rolling back" "$tmpdir/health-fail.err" ||
  fail "expected health rollback message on stderr"

current_health="$(readlink -f "$TODO_ROOT/current")"
[[ "$current_health" == "$expected_target" ]] ||
  fail "current not rolled back to previous release after health failure"

restart_after_health_fail="$(grep -c 'restart todo' "$SYSTEMCTL_LOG" || true)"
restart_delta=$((restart_after_health_fail - restart_before_health_fail))
[[ "$restart_delta" -ge 2 ]] ||
  fail "expected deploy + rollback systemctl restart attempts (got delta $restart_delta)"

pass "health failure rolled back current and retried systemctl restart"

echo ok >"$HEALTH_CONTROL"

# systemctl restart failure (post-flip) must also roll back, without set -e
# aborting before the rollback path runs, and must reset-failed first.
publish_release "$RESTART_FAIL_SHA"
echo fail-restart >"$SYSTEMCTL_MODE"
restart_before_restart_fail="$(grep -c 'restart todo' "$SYSTEMCTL_LOG" || true)"

set +e
"$UPDATE" >"$tmpdir/restart-fail.out" 2>"$tmpdir/restart-fail.err"
restart_fail_rc=$?
set -e
echo ok >"$SYSTEMCTL_MODE"
[[ "$restart_fail_rc" -ne 0 ]] || fail "restart-fail update should exit non-zero"
grep -q "reset-failed todo" "$SYSTEMCTL_LOG" ||
  fail "expected reset-failed todo before rollback restart"

current_restart_fail="$(readlink -f "$TODO_ROOT/current")"
[[ "$current_restart_fail" == "$expected_target" ]] ||
  fail "current not rolled back to previous release after restart failure"

restart_after_restart_fail="$(grep -c 'restart todo' "$SYSTEMCTL_LOG" || true)"
restart_fail_delta=$((restart_after_restart_fail - restart_before_restart_fail))
[[ "$restart_fail_delta" -ge 2 ]] ||
  fail "expected initial + rollback systemctl restart attempts (got delta $restart_fail_delta)"

pass "systemctl restart failure rolled back current without aborting under set -e"

# KEEP_RELEASES pruning: four successful deploys leave only three dirs
export TODO_ROOT="$tmpdir/prune-root"
export KEEP_RELEASES=3
: >"$SYSTEMCTL_LOG"
mkdir -p "$TODO_ROOT"

prune_shas=("$PRUNE_SHA_1" "$PRUNE_SHA_2" "$PRUNE_SHA_3" "$PRUNE_SHA_4")
for sha in "${prune_shas[@]}"; do
  publish_release "$sha"
  if ! "$UPDATE" >"$tmpdir/prune-${sha}.out" 2>"$tmpdir/prune-${sha}.err"; then
    cat "$tmpdir/prune-${sha}.out" "$tmpdir/prune-${sha}.err" >&2
    fail "prune scenario deploy failed for $sha"
  fi
  grep -q "deployed $sha" "$tmpdir/prune-${sha}.out" ||
    fail "prune deploy did not report success for $sha"
  sleep 1
done

release_count="$(find "$TODO_ROOT/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[[ "$release_count" -eq 3 ]] ||
  fail "expected 3 release directories after prune, got $release_count"

[[ ! -d "$TODO_ROOT/releases/$PRUNE_SHA_1" ]] ||
  fail "oldest release should have been pruned"

for sha in "$PRUNE_SHA_2" "$PRUNE_SHA_3" "$PRUNE_SHA_4"; do
  [[ -d "$TODO_ROOT/releases/$sha" ]] ||
    fail "expected release $sha to remain after prune"
done

prune_current="$(readlink -f "$TODO_ROOT/current")"
prune_expected="$(readlink -f "$TODO_ROOT/releases/$PRUNE_SHA_4")"
[[ "$prune_current" == "$prune_expected" ]] ||
  fail "current should point at newest release after prune sequence"
[[ -d "$prune_current" ]] ||
  fail "live current target directory missing after prune"

pass "KEEP_RELEASES=3 retained three releases and kept live current"

echo "All offline update tests passed."
suite_complete=1
