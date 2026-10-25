#!/usr/bin/env bash
# Rebuild the Mac app and replace ~/Applications/AI Session Remote.app.
#
# Run this when asked to rebuild or reinstall the Mac app:
#   scripts/rebuild-mac-app.sh
#
# The installed app must stay signed by Apple Development team 233QTK6KCL.
# An ad-hoc or "AI Session Remote Local" build has no Team ID, so the login
# keychain records a new cdhash on every rebuild and asks again for the SSH
# keys and the hub token.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AI Session Remote.app"
DEST="${HOME}/Applications/${APP_NAME}"
EXPECTED_TEAM="233QTK6KCL"
# The on-disk path, not the process name: macOS truncates that name.
PROCESS="/AI Session Remote.app/Contents/MacOS/AI Session Remote"

built="$("$ROOT/scripts/build-mac-release.sh" | tail -1)"
[[ -d "$built" ]] || { echo "build did not produce an app: ${built}" >&2; exit 1; }

team="$(codesign -dv "$built" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [[ "$team" != "$EXPECTED_TEAM" ]]; then
  echo "refusing to install: TeamIdentifier is '${team:-missing}', expected ${EXPECTED_TEAM}" >&2
  echo "AISessionRemoteMac in project.yml must be signed Apple Development for that team." >&2
  exit 1
fi

osascript -e 'quit app "AI Session Remote"' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  pgrep -f "$PROCESS" >/dev/null || break
  sleep 0.5
done
if pgrep -f "$PROCESS" >/dev/null; then
  echo "AI Session Remote is still running. Quit it, then run this again." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "${HOME}/Applications"
cp -R "$built" "$DEST"

# Opening in the same moment as quit fails with AppleEvent -600.
# A clean environment: the app passes its own to the conversations it starts, so launched
# from inside a conversation it carried that conversation's PATH on to the next ones.
env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin open "$DEST"
echo "$DEST"
