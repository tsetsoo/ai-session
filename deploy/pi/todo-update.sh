#!/usr/bin/env bash
set -euo pipefail

TODO_ROOT="${TODO_ROOT:-/opt/todo}"
TODO_RELEASE_BASE="${TODO_RELEASE_BASE:-https://github.com/tsetsoo/todo-app/releases/download/pi-latest}"
TODO_HEALTH_URL="${TODO_HEALTH_URL:-http://127.0.0.1:8080/api/health}"
TODO_SYSTEMCTL="${TODO_SYSTEMCTL:-systemctl}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"

mkdir -p "$TODO_ROOT/releases" "$TODO_ROOT/data"

remote_sha="$(curl -fsSL "$TODO_RELEASE_BASE/SHA" | tr -d '[:space:]')"
if [[ -z "$remote_sha" || ! "$remote_sha" =~ ^[0-9a-f]{7,40}$ ]]; then
  echo "invalid remote SHA: '$remote_sha'" >&2
  exit 1
fi

local_sha=""
if [[ -f "$TODO_ROOT/current/SHA" ]]; then
  local_sha="$(tr -d '[:space:]' < "$TODO_ROOT/current/SHA")"
fi

if [[ "$remote_sha" == "$local_sha" ]]; then
  echo "already at $remote_sha"
  exit 0
fi

prev=""
if [[ -L "$TODO_ROOT/current" ]]; then
  prev="$(readlink -f "$TODO_ROOT/current" || true)"
fi

# Atomically point $TODO_ROOT/current at $1 (symlink swap via rename, not
# an in-place unlink+relink) so a reader never observes a missing symlink.
# "current" is itself a symlink to a directory, so a plain `mv src current`
# would (on both GNU and BSD mv) follow it and move src *into* that
# directory instead of replacing the symlink. GNU mv's -T and BSD mv's -h
# both suppress that directory-following behavior; detect which we have.
flip_current() {
  local tmp="$TODO_ROOT/current.tmp"
  ln -sfn "$1" "$tmp"
  if mv --version >/dev/null 2>&1; then
    mv -Tf "$tmp" "$TODO_ROOT/current"
  else
    mv -hf "$tmp" "$TODO_ROOT/current"
  fi
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -fsSL "$TODO_RELEASE_BASE/todo-pi.tar.gz" -o "$workdir/todo-pi.tar.gz"
dest="$TODO_ROOT/releases/$remote_sha"
rm -rf "$dest"
mkdir -p "$dest"
tar --no-same-owner -C "$dest" -xzf "$workdir/todo-pi.tar.gz"

# The web UI is retired: a payload is just the server binary and its SHA. (Releases
# still carry a placeholder frontend-dist/ for updaters installed before this change.)
if [[ ! -x "$dest/todo-server" || ! -f "$dest/SHA" ]]; then
  echo "release payload incomplete" >&2
  rm -rf "$dest"
  exit 1
fi

# Trust the SHA baked into the payload itself, but only if it matches what
# the release manifest (remote_sha) advertised — otherwise we could deploy
# content under the wrong version label. Never overwrite the extracted SHA
# file with remote_sha: if they disagree, abort instead of masking it.
extracted_sha="$(tr -d '[:space:]' < "$dest/SHA")"
if [[ "$extracted_sha" != "$remote_sha" ]]; then
  echo "payload SHA mismatch: extracted '$extracted_sha' != remote '$remote_sha'" >&2
  rm -rf "$dest"
  exit 1
fi
chmod +x "$dest/todo-server"

flip_current "$dest"

restart_failed=0
"$TODO_SYSTEMCTL" restart todo || restart_failed=1

ok=0
if [[ "$restart_failed" -eq 0 ]]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "$TODO_HEALTH_URL" >/dev/null; then
      ok=1
      break
    fi
    sleep 1
  done
fi

if [[ "$restart_failed" -eq 1 || "$ok" -ne 1 ]]; then
  echo "health check failed; rolling back" >&2
  if [[ -n "$prev" && -d "$prev" ]]; then
    "$TODO_SYSTEMCTL" reset-failed todo || true
    flip_current "$prev"
    "$TODO_SYSTEMCTL" restart todo || true
  fi
  exit 1
fi

# prune old releases (keep newest KEEP_RELEASES by mtime)
# shellcheck disable=SC2012
ls -1dt "$TODO_ROOT/releases"/* 2>/dev/null | tail -n +"$((KEEP_RELEASES + 1))" | while read -r old; do
  # never delete the live current target
  [[ "$(readlink -f "$TODO_ROOT/current")" == "$(readlink -f "$old")" ]] && continue
  rm -rf "$old"
done

echo "deployed $remote_sha"
