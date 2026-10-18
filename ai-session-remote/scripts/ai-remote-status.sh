#!/usr/bin/env bash
# Optional host-side helper for AI Session Remote.
# Writes per-session status JSON under ~/.ai-remote/status/ for the phone to poll.
#
# Usage:
#   ai-remote-status.sh waiting ai/claude/my-slug "Needs input"
#   ai-remote-status.sh busy ai/claude/my-slug
#   ai-remote-status.sh idle ai/claude/my-slug
#   ai-remote-status.sh clear ai/claude/my-slug
set -euo pipefail

STATUS_DIR="${HOME}/.ai-remote/status"
mkdir -p "$STATUS_DIR"

action="${1:-}"
tmux_name="${2:-}"
message="${3:-}"

if [[ -z "$action" || -z "$tmux_name" ]]; then
  echo "usage: $0 <waiting|busy|idle|clear> <tmux-session-name> [message]" >&2
  exit 1
fi

filename="${tmux_name//\//__}.json"
path="${STATUS_DIR}/${filename}"

case "$action" in
  clear)
    rm -f "$path"
    echo "cleared $path"
    ;;
  waiting|busy|idle)
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '{"status":"%s","tmuxName":"%s","updatedAt":"%s","message":"%s"}\n' \
      "$action" "$tmux_name" "$ts" "$message" >"$path"
    echo "wrote $path"
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 1
    ;;
esac
