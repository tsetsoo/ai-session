#!/usr/bin/env bash
# Run as a Mac Xcode build phase, before the app is signed.
set -euo pipefail

version=v0.16.1
cache="${DERIVED_FILE_DIR:?}/terminal-browser/$version"
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/TerminalBrowser"
mkdir -p "$cache" "$resources"

staged=""
trap 'if [[ -n "$staged" ]]; then rm -f "$staged"; fi' EXIT

for arch in ${ARCHS:?}; do
  case "$arch" in
    arm64) target=darwin-arm64; checksum=7415324cac9182c672b25fd900673d68a6d99ced0718391a947962ca565e8614 ;;
    x86_64) target=darwin-x64; checksum=0b7e82fa57dcc6eff2ef753d372f1a52cc47b9035cf1c4713a14bfc601e75625 ;;
    *) echo "error: Terminal Browser does not support the Mac architecture $arch" >&2; exit 1 ;;
  esac
  name="terminal-browser-$target.tar.gz"
  archive="$cache/$name"
  verify() {
    printf '%s  %s\n' "$checksum" "$1" | /usr/bin/shasum -a 256 -c -s
  }
  if ! verify "$archive" 2>/dev/null; then
    staged="$(mktemp "$cache/$target.XXXXXX")"
    url="https://terminal-browser.sh/install/dl/stable/$version/$name"
    if ! /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 300 --retry 3 --output "$staged" "$url"; then
      echo "error: could not download Terminal Browser $version ($arch)" >&2
      exit 1
    fi
    if ! verify "$staged"; then
      echo "error: Terminal Browser $version ($arch) failed checksum verification" >&2
      exit 1
    fi
    mv -f "$staged" "$archive"
    staged=""
  fi
  if ! /usr/bin/cmp -s "$archive" "$resources/$name"; then
    cp -f "$archive" "$resources/$name"
  fi
  chmod 0644 "$resources/$name"
done
printf '%s\n' "$version" >"$resources/VERSION"
cp "${SRCROOT:?}/licenses/TerminalBrowser.txt" "$resources/LICENSE"
