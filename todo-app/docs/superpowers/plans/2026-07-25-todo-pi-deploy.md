# Todo App Pi Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every push to `main`, GitHub Actions publishes an armv7 build to rolling release `pi-latest`, and the Pi pulls it, swaps, and restarts with auto-rollback on health-check failure.

**Architecture:** CI cross-compiles `todo-server` for `armv7-unknown-linux-gnueabihf` and builds the WASM frontend; assets go to GitHub Release `pi-latest`. A systemd timer on the Pi runs `todo-update.sh`, which compares SHAs, downloads the tarball, atomically flips `/opt/todo/current`, restarts `todo.service`, and rolls back if `/api/sections` fails.

**Tech Stack:** GitHub Actions, Rust/`cross` (or equivalent armv7 cross toolchain), Trunk, GitHub Releases, bash, systemd, Tailscale SSH to `raspberrypi`.

**Spec:** `docs/superpowers/specs/2026-07-25-todo-pi-deploy-design.md`

## Global Constraints

- Trigger: every push to `main` (not PRs)
- Target triple: `armv7-unknown-linux-gnueabihf` (Pi is `armv7l` Raspbian Buster)
- Rolling release tag/name: `pi-latest`
- Assets: `todo-pi.tar.gz` + plaintext `SHA` (git commit)
- Pi layout: `/opt/todo/{current,releases/<sha>,data/todos.db}`
- Service bind: `0.0.0.0:8080`; DB: `/opt/todo/data/todos.db`; `FRONTEND_DIR=/opt/todo/current/frontend-dist`
- Keep last 3 release dirs; health check `GET http://127.0.0.1:8080/api/sections`
- Fail closed on download/extract errors (no symlink flip / restart)
- No GitHub token required on the Pi (public repo)
- Do not build Rust on the Pi

## File Structure

| Path | Responsibility |
|---|---|
| `.github/workflows/deploy-pi.yml` | Build armv7 + WASM; publish/clobber `pi-latest` |
| `deploy/pi/todo-update.sh` | Puller: SHA compare, download, swap, health, prune, rollback |
| `deploy/pi/todo.service` | systemd unit for the app |
| `deploy/pi/todo-update.service` | oneshot unit that runs the puller |
| `deploy/pi/todo-update.timer` | runs puller every 2 minutes |
| `deploy/pi/bootstrap.sh` | one-time install of dirs + units + first pull on the Pi |
| `deploy/pi/fixtures/` + `deploy/pi/test-todo-update.sh` | offline test of updater logic with mocked downloads |

---

### Task 1: Updater script + offline test harness

**Files:**
- Create: `deploy/pi/todo-update.sh`
- Create: `deploy/pi/test-todo-update.sh`
- Create: `deploy/pi/fixtures/make_release.sh` (builds fake tarball + SHA for tests)

**Interfaces:**
- Consumes: env `TODO_ROOT` (default `/opt/todo`), `TODO_RELEASE_BASE` (default `https://github.com/tsetsoo/todo-app/releases/download/pi-latest`), `TODO_HEALTH_URL` (default `http://127.0.0.1:8080/api/sections`), `TODO_SYSTEMCTL` (default `systemctl`, overridable for tests)
- Produces: exit 0 when up-to-date or successful deploy; non-zero on failure after any attempted rollback; writes `/opt/todo/releases/<sha>/` and updates `current` symlink

- [ ] **Step 1: Write the offline test (failing until script exists)**

Create `deploy/pi/fixtures/make_release.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
OUT="${1:?usage: make_release.sh <outdir> <sha>}"
SHA="${2:?}"
mkdir -p "$OUT/payload/frontend-dist"
printf '%s\n' "$SHA" > "$OUT/SHA"
cat > "$OUT/payload/todo-server" <<'EOF'
#!/bin/sh
echo fake-server
EOF
chmod +x "$OUT/payload/todo-server"
echo '<!doctype html><title>ok</title>' > "$OUT/payload/frontend-dist/index.html"
printf '%s\n' "$SHA" > "$OUT/payload/SHA"
tar -C "$OUT/payload" -czf "$OUT/todo-pi.tar.gz" todo-server frontend-dist SHA
```

Create `deploy/pi/test-todo-update.sh` that:
1. Uses a temp `TODO_ROOT`
2. Points `TODO_RELEASE_BASE` at a local `file://` or HTTP fixture dir (prefer a tiny `python3 -m http.server` on a free port serving the fixture)
3. Stubs `TODO_SYSTEMCTL` with a script that records `restart todo` and always succeeds
4. Stubs health with a tiny python HTTP server returning 200 for `/api/sections`
5. Asserts: first run installs `releases/<sha>` and `current` points there; second run is no-op; a “bad” release (missing `index.html`) does not move `current`

- [ ] **Step 2: Run test — expect failure (script missing)**

```bash
chmod +x deploy/pi/fixtures/make_release.sh deploy/pi/test-todo-update.sh
./deploy/pi/test-todo-update.sh
```

Expected: FAIL because `deploy/pi/todo-update.sh` does not exist or is incomplete.

- [ ] **Step 3: Implement `deploy/pi/todo-update.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

TODO_ROOT="${TODO_ROOT:-/opt/todo}"
TODO_RELEASE_BASE="${TODO_RELEASE_BASE:-https://github.com/tsetsoo/todo-app/releases/download/pi-latest}"
TODO_HEALTH_URL="${TODO_HEALTH_URL:-http://127.0.0.1:8080/api/sections}"
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

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -fsSL "$TODO_RELEASE_BASE/todo-pi.tar.gz" -o "$workdir/todo-pi.tar.gz"
dest="$TODO_ROOT/releases/$remote_sha"
rm -rf "$dest"
mkdir -p "$dest"
tar -C "$dest" -xzf "$workdir/todo-pi.tar.gz"

if [[ ! -x "$dest/todo-server" || ! -f "$dest/frontend-dist/index.html" ]]; then
  echo "release payload incomplete" >&2
  rm -rf "$dest"
  exit 1
fi
printf '%s\n' "$remote_sha" > "$dest/SHA"
chmod +x "$dest/todo-server"

ln -sfn "$dest" "$TODO_ROOT/current"
"$TODO_SYSTEMCTL" restart todo

ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "$TODO_HEALTH_URL" >/dev/null; then
    ok=1
    break
  fi
  sleep 1
done

if [[ "$ok" -ne 1 ]]; then
  echo "health check failed; rolling back" >&2
  if [[ -n "$prev" && -d "$prev" ]]; then
    ln -sfn "$prev" "$TODO_ROOT/current"
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
```

Make executable: `chmod +x deploy/pi/todo-update.sh`

- [ ] **Step 4: Run offline test — expect PASS**

```bash
./deploy/pi/test-todo-update.sh
```

Expected: PASS (up-to-date no-op, successful deploy, bad payload leaves current unchanged).

- [ ] **Step 5: Commit**

```bash
git add deploy/pi/todo-update.sh deploy/pi/test-todo-update.sh deploy/pi/fixtures/make_release.sh
git commit -m "Add Pi puller script and offline update tests"
```

---

### Task 2: systemd units + bootstrap script

**Files:**
- Create: `deploy/pi/todo.service`
- Create: `deploy/pi/todo-update.service`
- Create: `deploy/pi/todo-update.timer`
- Create: `deploy/pi/bootstrap.sh`

**Interfaces:**
- Consumes: `todo-update.sh` from Task 1; release assets once CI publishes (Task 3)
- Produces: installable units under `/etc/systemd/system/` via bootstrap; app runs as user `pi`

- [ ] **Step 1: Write unit files**

`deploy/pi/todo.service`:

```ini
[Unit]
Description=Todo app (Actix + Leptos)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/opt/todo/current
Environment=FRONTEND_DIR=/opt/todo/current/frontend-dist
ExecStart=/opt/todo/current/todo-server --db /opt/todo/data/todos.db --addr 0.0.0.0:8080
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`deploy/pi/todo-update.service`:

```ini
[Unit]
Description=Pull latest todo-app release from GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/opt/todo/todo-update.sh
```

`deploy/pi/todo-update.timer`:

```ini
[Unit]
Description=Check for todo-app updates every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
Unit=todo-update.service

[Install]
WantedBy=timers.target
```

- [ ] **Step 2: Write `deploy/pi/bootstrap.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Run on the Pi as root (or via sudo).
# Usage: sudo ./bootstrap.sh

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
install -d -o pi -g pi /opt/todo/releases /opt/todo/data
install -m 0755 "$REPO_DIR/todo-update.sh" /opt/todo/todo-update.sh
install -m 0644 "$REPO_DIR/todo.service" /etc/systemd/system/todo.service
install -m 0644 "$REPO_DIR/todo-update.service" /etc/systemd/system/todo-update.service
install -m 0644 "$REPO_DIR/todo-update.timer" /etc/systemd/system/todo-update.timer
systemctl daemon-reload
# First pull (may fail if pi-latest not published yet — OK)
/opt/todo/todo-update.sh || echo "first pull deferred until pi-latest exists"
systemctl enable --now todo.service || true
systemctl enable --now todo-update.timer
systemctl status todo.service --no-pager || true
systemctl list-timers todo-update.timer --no-pager
```

`chmod +x deploy/pi/bootstrap.sh`

- [ ] **Step 3: Sanity-check unit files locally**

```bash
grep -q '0.0.0.0:8080' deploy/pi/todo.service
grep -q 'OnUnitActiveSec=2min' deploy/pi/todo-update.timer
grep -q '/opt/todo/todo-update.sh' deploy/pi/todo-update.service
test -x deploy/pi/bootstrap.sh
```

Expected: all checks exit 0.

- [ ] **Step 4: Commit**

```bash
git add deploy/pi/todo.service deploy/pi/todo-update.service deploy/pi/todo-update.timer deploy/pi/bootstrap.sh
git commit -m "Add Pi systemd units and bootstrap script"
```

---

### Task 3: GitHub Actions workflow `deploy-pi`

**Files:**
- Create: `.github/workflows/deploy-pi.yml`

**Interfaces:**
- Consumes: `crates/todo-server`, `crates/todo-frontend` (Trunk.toml dist `../../frontend-dist`)
- Produces: GitHub Release `pi-latest` with assets `todo-pi.tar.gz` and `SHA`

- [ ] **Step 1: Add workflow file**

```yaml
name: Deploy Pi

on:
  push:
    branches: [main]

permissions:
  contents: write

env:
  CARGO_TERM_COLOR: always

jobs:
  deploy-pi:
    name: Build armv7 + publish pi-latest
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@nightly
        with:
          targets: wasm32-unknown-unknown,armv7-unknown-linux-gnueabihf

      - uses: Swatinem/rust-cache@v2
        with:
          key: deploy-pi

      - name: Install Trunk
        run: cargo install trunk --locked

      - name: Build frontend
        run: cd crates/todo-frontend && trunk build --release

      - name: Install cross
        run: cargo install cross --git https://github.com/cross-rs/cross --locked

      - name: Cross-compile server (armv7)
        run: cross build --release -p todo-server --target armv7-unknown-linux-gnueabihf

      - name: Pack release
        run: |
          stage="$(mktemp -d)"
          cp "target/armv7-unknown-linux-gnueabihf/release/todo-server" "$stage/todo-server"
          chmod +x "$stage/todo-server"
          cp -a frontend-dist "$stage/frontend-dist"
          printf '%s\n' "${GITHUB_SHA}" > "$stage/SHA"
          tar -C "$stage" -czf todo-pi.tar.gz todo-server frontend-dist SHA
          printf '%s\n' "${GITHUB_SHA}" > SHA
          ls -lh todo-pi.tar.gz SHA

      - name: Publish pi-latest release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if gh release view pi-latest >/dev/null 2>&1; then
            gh release upload pi-latest todo-pi.tar.gz SHA --clobber
          else
            gh release create pi-latest todo-pi.tar.gz SHA \
              --title "Pi deploy (rolling)" \
              --notes "Rolling artifact for raspberrypi. Updated on every main push." \
              --latest=false
          fi
          # Move tag to this commit so release points at current main tip
          git tag -f pi-latest "$GITHUB_SHA"
          git push -f origin refs/tags/pi-latest
```

- [ ] **Step 2: Commit workflow (do not push yet unless ready to publish)**

```bash
git add .github/workflows/deploy-pi.yml
git commit -m "Add GitHub Actions workflow to publish pi-latest armv7 build"
```

- [ ] **Step 3: Push `main` and verify Actions + release**

```bash
git push origin main
gh run watch --exit-status
gh release view pi-latest
curl -fsSL https://github.com/tsetsoo/todo-app/releases/download/pi-latest/SHA
file <(curl -fsSL https://github.com/tsetsoo/todo-app/releases/download/pi-latest/todo-pi.tar.gz)
```

Expected: workflow green; `SHA` matches the pushed commit; tarball downloads.

**If the armv7 binary later fails on Buster with `GLIBC_… not found`:** change the cross step to build inside a Debian Buster armhf container (Docker/`cross` custom image) in a follow-up fix — do not build on the Pi.

---

### Task 4: Bootstrap the Pi and verify end-to-end

**Files:**
- No new repo files (uses Task 2 artifacts over SSH)

**Interfaces:**
- Consumes: published `pi-latest` from Task 3; `deploy/pi/*` from repo
- Produces: running `todo.service` on `raspberrypi` at `:8080` with `/opt/todo/current/SHA` matching `pi-latest`

- [ ] **Step 1: Copy deploy files to the Pi**

```bash
ssh raspberrypi 'mkdir -p ~/todo-deploy'
scp deploy/pi/todo-update.sh deploy/pi/todo.service \
    deploy/pi/todo-update.service deploy/pi/todo-update.timer \
    deploy/pi/bootstrap.sh raspberrypi:~/todo-deploy/
```

- [ ] **Step 2: Run bootstrap**

```bash
ssh raspberrypi 'cd ~/todo-deploy && sudo ./bootstrap.sh'
```

Expected: `/opt/todo/current/SHA` set; `todo.service` active; timer listed.

- [ ] **Step 3: Smoke test over Tailscale**

```bash
curl -fsS "http://100.118.255.23:8080/api/sections"
curl -fsS -o /dev/null -w "%{http_code}\n" "http://100.118.255.23:8080/"
ssh raspberrypi 'systemctl is-active todo; cat /opt/todo/current/SHA; readlink -f /opt/todo/current'
```

Expected: JSON sections response; frontend HTTP 200; SHA matches GitHub `pi-latest`.

- [ ] **Step 4: Verify binary arch + glibc on device**

```bash
ssh raspberrypi 'file /opt/todo/current/todo-server; ldd /opt/todo/current/todo-server | head'
```

Expected: ARM ELF, no missing libraries. If missing GLIBC symbols, stop and fix the CI cross image (Buster baseline) before proceeding.

- [ ] **Step 5: Empty commit or tiny docs tweak on `main` to prove auto-update**

```bash
# after a new main push + ~2–4 minutes
ssh raspberrypi 'cat /opt/todo/current/SHA'
curl -fsSL https://github.com/tsetsoo/todo-app/releases/download/pi-latest/SHA
```

Expected: Pi SHA updates to the new commit without manual bootstrap.

- [ ] **Step 6: Commit any bootstrap docs tweaks only if needed**

If bootstrap needed small fixes discovered on-device, commit them:

```bash
git add deploy/pi/
git commit -m "Fix Pi bootstrap after on-device verification"
git push origin main
```

---

## Spec coverage checklist

| Spec requirement | Task |
|---|---|
| Build WASM + armv7 on main push | Task 3 |
| Publish rolling `pi-latest` (`todo-pi.tar.gz` + `SHA`) | Task 3 |
| Pi timer pull every ~2 min | Task 2 |
| Atomic symlink swap + restart | Task 1 |
| Health check + rollback | Task 1 |
| Keep last 3 releases | Task 1 |
| DB outside releases at `/opt/todo/data/todos.db` | Task 2 (`todo.service`) |
| One-time bootstrap | Task 2 + Task 4 |
| Fail closed on bad download | Task 1 |
| No build-on-Pi / no CI SSH push | Tasks 1–4 |

## Self-review notes

- No TBD placeholders in steps; glibc risk has an explicit remediation path in Task 3/4
- `TODO_SYSTEMCTL` / `TODO_RELEASE_BASE` env overrides exist so Task 1 tests do not need real systemd or GitHub
- Release tag force-push requires `contents: write` (set in workflow)
