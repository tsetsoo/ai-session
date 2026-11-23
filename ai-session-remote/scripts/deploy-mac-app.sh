#!/usr/bin/env bash
# Build a committed revision once and deploy it to this Mac and the selected SSH hosts.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
updater="$root/scripts/install-mac-build.sh"
revision="$(git -C "$root" rev-parse HEAD)"
if [[ -n "$(git -C "$root" status --porcelain --untracked-files=all)" ]]; then
  echo "Commit the source changes before deploying so every app can identify its build." >&2
  exit 1
fi

if [[ $# == 0 ]]; then
  set -- tsvetelinpantev@100.94.164.63 tsetso@100.107.204.56
fi
for host in "$@"; do
  [[ "$host" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
    echo "Use an SSH destination in user@host format." >&2
    exit 2
  }
done

ssh_options=(-i "${AISESSION_DEPLOY_KEY:-$HOME/.ssh/id_ed25519_aisession}" -o IdentitiesOnly=yes
  -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8
  -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
app="$(AISESSION_RELEASE_REVISION="$revision" "$root/scripts/build-mac-release.sh" "$scratch/derived" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)"
codesign --verify --deep --strict -R '=identifier "com.aisessionremote.mac" and anchor apple generic and certificate leaf[subject.OU] = "233QTK6KCL" and certificate leaf[subject.CN] = "Apple Development:"*' "$app"
test "$(plutil -extract AISessionReleaseRevision raw "$app/Contents/Info.plist")" = "$revision"
architectures="$(lipo -archs "$app/Contents/MacOS/AI Session Remote")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
archive="$scratch/app.zip"
ditto -c -k --keepParent "$app" "$archive"

can_deploy() {
  local installed="$1"
  [[ -z "$installed" ]] && return 0
  [[ "$installed" =~ ^[0-9a-f]{40}$ ]] && git -C "$root" merge-base --is-ancestor "$installed" "$revision"
}

deploy_remote() {
  local host="$1" installed transfer result=0
  if installed="$(ssh "${ssh_options[@]}" "$host" '/bin/bash -s -- --revision' < "$updater" 2>"$scratch/ssh-error")"; then
    :
  else
    result=$?
    cat "$scratch/ssh-error" >&2
    if [[ "$result" == 255 ]] && grep -Eqi 'timed out|No route to host|Network is unreachable|Could not resolve hostname|Connection refused|Host is down' "$scratch/ssh-error"; then
      return 2
    fi
    return 1
  fi
  if [[ "$installed" == "$revision" ]]; then echo "Already updated"; return 0; fi
  can_deploy "$installed" || { echo "Installed build $installed is outside this revision’s history." >&2; return 1; }

  transfer="$(ssh "${ssh_options[@]}" "$host" '/usr/bin/mktemp -d /tmp/aisession-deploy.XXXXXXXX')" || return 1
  [[ "$transfer" =~ ^/tmp/aisession-deploy[.][a-zA-Z0-9]{8}$ ]] || return 1
  if scp "${ssh_options[@]}" "$archive" "$host:$transfer/app.zip"; then
    # All remote arguments are constrained above to hex or a mktemp path.
    ssh "${ssh_options[@]}" "$host" "/bin/bash -s -- --local '$transfer/app.zip' '$revision' '$installed'" < "$updater" || result=$?
  else
    result=1
  fi
  ssh "${ssh_options[@]}" "$host" "/bin/rm -rf '$transfer'" || true
  if (( result )); then return 1; fi
}

failed=()
offline=()
echo "== This Mac =="
if installed="$("$updater" --revision)" && can_deploy "$installed"; then
  if [[ "$installed" == "$revision" ]]; then
    echo "Already updated"
  elif ! "$updater" --local "$archive" "$revision" "$installed"; then
    failed+=("this Mac")
  fi
else
  echo "Could not verify the installed build’s history." >&2
  failed+=("this Mac")
fi
if report="$("$updater" --status)"; then
  echo "$report"
  if [[ "$report" != "installed=$revision "* && ${#failed[@]} == 0 ]]; then
    failed+=("this Mac (installed revision mismatch)")
  fi
else
  failed+=("this Mac (status unavailable)")
fi
for host in "$@"; do
  echo "== $host =="
  if deploy_remote "$host"; then
    if report="$(ssh "${ssh_options[@]}" "$host" '/bin/bash -s -- --status' < "$updater")"; then
      echo "$report"
      if [[ "$report" != "installed=$revision "* ]]; then
        failed+=("$host (installed revision mismatch)")
      fi
    else
      failed+=("$host (status unavailable)")
    fi
  else
    result=$?
    if [[ "$result" == 2 ]]; then
      offline+=("$host")
    else
      failed+=("$host")
      ssh "${ssh_options[@]}" "$host" '/bin/bash -s -- --status' < "$updater" || echo "App status unavailable"
    fi
  fi
done
if (( ${#offline[@]} )); then printf 'Offline or unreachable: %s\n' "${offline[@]}" >&2; fi
if (( ${#failed[@]} )); then printf 'Update failed on %s\n' "${failed[@]}" >&2; fi
if (( ${#offline[@]} + ${#failed[@]} )); then exit 1; fi
