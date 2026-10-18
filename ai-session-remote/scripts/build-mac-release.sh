#!/usr/bin/env bash
# Build the Release macOS app and print the path to the .app.
#
# Usage:
#   scripts/build-mac-release.sh [derived-data-dir]
#
# Signed with the stable local identity "AI Session Remote Local" so login-keychain
# access survives rebuilds. Copy it to ~/Applications to install:
#   cp -R "$(scripts/build-mac-release.sh | tail -1)" ~/Applications/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${1:-${ROOT}/.build/mac-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }
"$ROOT/scripts/ensure-mac-signing-identity.sh"
xcodegen generate >/dev/null

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if ! xcodebuild -scheme AISessionRemoteMac -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" build >"$log" 2>&1; then
  grep -E "error:" "$log" >&2 || tail -40 "$log" >&2
  echo "Release build failed (full log above)" >&2
  exit 1
fi

app="$(find "${DERIVED}/Build/Products/Release" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$app" ]] || { echo "built, but no .app found under ${DERIVED}/Build/Products/Release" >&2; exit 1; }
echo "$app"
