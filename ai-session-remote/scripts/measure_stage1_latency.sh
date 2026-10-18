#!/usr/bin/env bash
# Approximate Stage 1 SSH latency acceptance using a delay proxy (~150ms RTT)
# and OpenSSH ControlMaster as a stand-in for the pooled connection.
set -euo pipefail

HOST="${MEASURE_HOST:-raspberrypi}"
UPSTREAM_IP="${MEASURE_UPSTREAM_IP:-100.118.255.23}"
PROXY_PORT="${MEASURE_PROXY_PORT:-18022}"
DELAY_MS="${MEASURE_DELAY_MS:-75}"
RUNS="${MEASURE_RUNS:-3}"
CTRL="/tmp/aisr-stage1-latency-mux-%C"
PROXY_PID=""

PATH_EXPORT='export PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"'
LIST_MERGED="$PATH_EXPORT; tmux ls -F '#{session_name}\t#{session_activity}\t#{session_attached}'; ls_exit=\$?; echo '---STATUS---'; if [ \$ls_exit -eq 0 ]; then mkdir -p ~/.ai-remote/status; setopt NULL_GLOB 2>/dev/null || true; shopt -s nullglob 2>/dev/null || true; for f in ~/.ai-remote/status/*.json; do [ -f \"\$f\" ] && echo \"---\$(basename \"\$f\")---\" && cat \"\$f\"; done; fi; exit \$ls_exit"
LIST_TMUX="$PATH_EXPORT; tmux ls -F '#{session_name}\t#{session_activity}\t#{session_attached}'"
LIST_STATUS="$PATH_EXPORT; mkdir -p ~/.ai-remote/status; setopt NULL_GLOB 2>/dev/null || true; shopt -s nullglob 2>/dev/null || true; for f in ~/.ai-remote/status/*.json; do [ -f \"\$f\" ] && echo \"---\$(basename \"\$f\")---\" && cat \"\$f\"; done; true"

cleanup() {
  if [[ -n "$PROXY_PID" ]]; then kill "$PROXY_PID" 2>/dev/null || true; fi
  ssh -o ControlPath="$CTRL" -O exit -p "$PROXY_PORT" pi@127.0.0.1 2>/dev/null || true
}
trap cleanup EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/delay_proxy.py" \
  --listen "127.0.0.1:$PROXY_PORT" \
  --upstream "$UPSTREAM_IP:22" \
  --delay-ms "$DELAY_MS" &
PROXY_PID=$!
sleep 0.3

SSH_BASE=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/tmp/aisr-stage1-known-hosts
  -i "$HOME/.ssh/id_ed25519"
  -o IdentitiesOnly=yes
  -p "$PROXY_PORT"
  pi@127.0.0.1
)

# Warm ControlMaster through the delay proxy (stand-in for pooled SSH).
"${SSH_BASE[@]}" -o ControlMaster=yes -o ControlPersist=60 -o ControlPath="$CTRL" -fN

ssh_warm() {
  "${SSH_BASE[@]}" -o ControlPath="$CTRL" -o ControlMaster=no "$@"
}

ssh_cold() {
  # Fresh TCP+SSH handshake each call (stand-in for pre-pool per-command dial).
  "${SSH_BASE[@]}" -o ControlMaster=no -o ControlPath=none "$@"
}

median() {
  # shellcheck disable=SC2207
  local sorted=($(printf '%s\n' "$@" | sort -n))
  local n=${#sorted[@]}
  local mid=$((n / 2))
  if (( n % 2 == 1 )); then
    echo "${sorted[$mid]}"
  else
    python3 -c "print((${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2)"
  fi
}

time_cmd() {
  local label=$1 mode=$2
  shift 2
  local times=()
  local i t0 t1 ms
  for ((i = 1; i <= RUNS; i++)); do
    t0=$(python3 -c 'import time; print(time.time())')
    if [[ "$mode" == warm ]]; then
      ssh_warm "$@" >/dev/null
    else
      ssh_cold "$@" >/dev/null
    fi
    t1=$(python3 -c 'import time; print(time.time())')
    ms=$(python3 -c "print(int(round(($t1 - $t0) * 1000)))")
    times+=("$ms")
    echo "  run $i: ${ms} ms" >&2
  done
  local med
  med=$(median "${times[@]}")
  printf '%s\t%s\t%s\n' "$label" "$mode" "$med"
}

time_two_warm() {
  local label=$1
  shift
  local times=()
  local i t0 t1 ms
  for ((i = 1; i <= RUNS; i++)); do
    t0=$(python3 -c 'import time; print(time.time())')
    # Two separate SSH execs over the multiplexed connection (pre-Stage-1 listSessions).
    ssh_warm "$LIST_TMUX" >/dev/null
    ssh_warm "$LIST_STATUS" >/dev/null
    t1=$(python3 -c 'import time; print(time.time())')
    ms=$(python3 -c "print(int(round(($t1 - $t0) * 1000)))")
    times+=("$ms")
    echo "  run $i: ${ms} ms" >&2
  done
  local med
  med=$(median "${times[@]}")
  printf '%s\t%s\t%s\n' "$label" "warm" "$med"
}

echo "Proxy RTT target ≈ $((DELAY_MS * 2)) ms  (one-way ${DELAY_MS} ms)  runs=$RUNS host=$HOST"
echo

# Sanity: one warm true
ssh_warm 'true' >/dev/null

echo "Measuring…"
{
  time_cmd "session list (merged, Stage1)" warm "$LIST_MERGED"
  time_two_warm "session list (2 execs, old)"
  time_cmd "first action cold dial+true" cold 'true'
  time_cmd "warm true (pooled stand-in)" warm 'true'
} | tee /tmp/aisr-stage1-latency.tsv

echo
echo "Medians (ms):"
column -t /tmp/aisr-stage1-latency.tsv
echo
echo "Note: this is Mac→delay-proxy→Pi SSH timing, not the iOS app UI path."
echo "It validates round-trip reduction from pooling + merged scripts under ~$((DELAY_MS * 2)) ms RTT."
