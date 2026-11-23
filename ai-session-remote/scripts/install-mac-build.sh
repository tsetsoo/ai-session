#!/usr/bin/env bash
# Used over SSH by deploy-mac-app.sh to install signed builds on older Macs too.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

support="$HOME/Library/Application Support/AI Session Remote Updater"
app="AI Session Remote.app"
applications="$HOME/Applications"
destination="$applications/$app"
stamp="$applications/.ai-session-remote-commit"
requirement='=identifier "com.aisessionremote.mac" and anchor apple generic and certificate leaf[subject.OU] = "233QTK6KCL" and certificate leaf[subject.CN] = "Apple Development:"*'

mode="${1:-}"
[[ -d "$destination" ]] || {
  echo "Install the app in $applications to use updates." >&2
  exit 1
}

current_revision() {
  local revision
  revision="$(plutil -extract AISessionReleaseRevision raw "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$revision" ]]; then printf '%s\n' "$revision"; else cat "$stamp" 2>/dev/null || true; fi
}

valid_revision() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

status() {
  local installed pid="" revision="" running="stopped"
  installed="$(current_revision)"
  if [[ -r "$support/running-build" ]]; then
    read -r pid revision < "$support/running-build" || true
  fi
  running="$(ps -axo pid=,command= | awk -v binary="$destination/Contents/MacOS/AI Session Remote" \
    -v pid="$pid" -v revision="$revision" '
      {
        command = $0
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
        if (command == binary || index(command, binary " ") == 1) {
          arguments = substr(command, length(binary) + 2)
          if (arguments ~ /^--(background-app-update|install-app-update|install-fleet-app-update)( |$)/) next
          found = 1
          if ($1 == pid && length(revision) == 40 && revision !~ /[^0-9a-f]/) matched = 1
        }
      }
      END { print matched ? revision : (found ? "unknown" : "stopped") }
    ')"
  printf 'installed=%s running=%s\n' "${installed:-unknown}" "$running"
}

case "$mode" in
  --revision)
    current_revision
    ;;
  --status)
    status
    ;;
  --local)
    archive="$2"
    revision="$3"
    expected="$4"
    valid_revision "$revision"
    [[ -z "$expected" ]] || valid_revision "$expected"
    [[ "$(current_revision)" == "$expected" ]] || { echo "Installed revision changed. Retry deployment." >&2; exit 1; }
    stage="$applications/.ai-session-remote-update.$(/usr/bin/uuidgen)"
    mkdir -m 700 "$stage"
    trap 'if [[ ! -e "$stage/preserve-rollback" ]]; then rm -rf "$stage"; fi' EXIT
    ditto -x -k "$archive" "$stage"
    candidate="$stage/$app"
    # Verify before executing the native installer, including on pre-updater Macs.
    codesign --verify --deep --strict -R "$requirement" "$candidate"
    [[ "$(plutil -extract AISessionReleaseRevision raw "$candidate/Contents/Info.plist")" == "$revision" ]]
    "$candidate/Contents/MacOS/AI Session Remote" --install-fleet-app-update "${stage##*/}" "$revision" "$expected"
    ;;
  *)
    echo "Usage: $0 --revision | --status | --local <archive> <revision> <installed-revision>" >&2
    exit 2
    ;;
esac
