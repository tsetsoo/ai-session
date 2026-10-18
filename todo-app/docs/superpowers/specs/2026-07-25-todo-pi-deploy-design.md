# Todo App → Raspberry Pi Deploy Design

**Date:** 2026-07-25  
**Status:** Approved  


**Repo:** [tsetsoo/todo-app](https://github.com/tsetsoo/todo-app) (public)  
**Target:** `raspberrypi` (armv7l, Tailscale `100.118.255.23`)

## Goal

On every push to `main`, automatically ship a new build to the Pi with minimal downtime, without building Rust on the Pi, and without opening the Pi to inbound CI access.

## Non-goals (v1)

- Building the server binary on the Pi
- Pushing from GitHub Actions over Tailscale/SSH
- HTTPS / nginx reverse-proxy setup
- Multi-environment (staging) deploys
- Database backups as part of deploy

## Architecture

```
main push
  → GitHub Actions: WASM frontend + cross-compile todo-server (armv7)
  → publish/replace rolling Release tag `pi-latest` (tarball + SHA)
  → Pi timer (~every 2 min): compare remote SHA vs local
  → if new: download → atomic swap → systemctl restart todo
  → SQLite lives outside the release dir (never overwritten)
```

The Pi **pulls** prebuilt artifacts. CI never SSHes into the Pi.

## Artifact channel

Rolling GitHub Release with tag/name **`pi-latest`**.

| Asset | Purpose |
|---|---|
| `todo-pi.tar.gz` | Binary + `frontend-dist/` |
| `SHA` | Plaintext git commit SHA of the build |

Because the repo is public, the Pi can download with `curl` and no GitHub token.

Each `main` push rebuilds and **replaces** the `pi-latest` assets (delete + re-upload, or `gh release upload --clobber`).

## Pi filesystem layout

```
/opt/todo/
  current -> releases/<sha>/          # symlink flipped atomically
  releases/<sha>/
    todo-server                       # armv7 binary
    frontend-dist/                    # Trunk output
    SHA                               # commit that produced this release
  data/
    todos.db                          # persistent SQLite (never in releases/)
  todo-update.sh                      # puller script
```

Keep the last **3** release directories; delete older ones after a successful deploy.

## Components

### 1. GitHub Actions — `deploy-pi` job

**Trigger:** `push` to `main` (in addition to existing CI). Prefer a dedicated workflow or job that runs after/alongside build; it must not block PR CI.

**Steps:**

1. Checkout
2. Install Rust nightly + `wasm32-unknown-unknown` + Trunk
3. `trunk build --release` in `crates/todo-frontend` (output → `frontend-dist/`)
4. Cross-compile `todo-server` for `armv7-unknown-linux-gnueabihf`  
   - Preferred: [`cross`](https://github.com/cross-rs/cross) or an equivalent armv7 Linux GNU toolchain on `ubuntu-latest`
5. Stage payload:
   - `todo-server` (release binary)
   - `frontend-dist/`
   - `SHA` file containing `GITHUB_SHA`
6. `tar czf todo-pi.tar.gz …`
7. Create or update GitHub Release `pi-latest` with the tarball and `SHA` (clobber previous assets)

Existing clippy/build CI stays unchanged for PRs and `main`.

### 2. systemd unit — `todo.service`

- **ExecStart:** `/opt/todo/current/todo-server --db /opt/todo/data/todos.db --addr 0.0.0.0:8080`
- **Environment:** `FRONTEND_DIR=/opt/todo/current/frontend-dist`
- **User:** `pi` (or a dedicated `todo` user if we create one; default `pi` for v1)
- **Restart:** `on-failure`
- Working directory: `/opt/todo/current`

App listens on all interfaces; access via Tailscale (`http://raspberrypi:8080` / `http://100.118.255.23:8080`) or LAN.

### 3. Updater — `todo-update.sh` + timer

**Timer:** every 2 minutes (`OnUnitActiveSec=2min`), plus optional boot delay.

**Script logic:**

1. `curl` remote `SHA` from the `pi-latest` release asset URL
2. Compare to `/opt/todo/current/SHA` (if present)
3. If equal → exit 0
4. Download `todo-pi.tar.gz` to a temp dir
5. Extract into `/opt/todo/releases/<sha>/`
6. Verify `todo-server` is executable and `frontend-dist/index.html` exists
7. Record previous symlink target
8. `ln -sfn releases/<sha> /opt/todo/current` (atomic symlink replace)
9. `systemctl restart todo`
10. Health check: `GET http://127.0.0.1:8080/api/sections` (or `/api/describe`) within a short timeout/retry window
11. On health failure: restore previous symlink, restart, exit non-zero
12. On success: prune releases older than the newest 3

Logging: stdout/stderr via the systemd service/timer units (journald).

### 4. One-time Pi bootstrap

Documented script or manual steps (run once over SSH):

- Create `/opt/todo/{releases,data}` and install `todo-update.sh`
- Install `todo.service` + `todo-update.timer`
- Run updater once to fetch the first release (or seed from a local copy)
- Enable timer + service

Bootstrap assumes Tailscale SSH already works (`ssh raspberrypi`).

## Failure handling

| Failure | Behavior |
|---|---|
| Download/extract error | Leave `current` untouched; do not restart |
| Missing binary / frontend | Abort before symlink flip |
| Post-restart health check fails | Roll symlink back to previous release; restart; fail the run |
| GitHub/API unreachable | Exit quietly (retry next timer tick) |

## Data & migrations

- SQLite path is always `/opt/todo/data/todos.db`
- Schema changes continue to use the server’s existing startup migrations (`db.rs`)
- Deploy never copies or deletes the DB

## Manual operations

```bash
# Force update check
sudo /opt/todo/todo-update.sh

# Manual rollback
sudo ln -sfn /opt/todo/releases/<old-sha> /opt/todo/current
sudo systemctl restart todo
```

## Success criteria

1. Push to `main` produces an updated `pi-latest` release with armv7 binary + frontend
2. Within ~2–4 minutes, Pi is running that commit (verify `/opt/todo/current/SHA`)
3. Existing todos survive deploys
4. A broken build that fails health check does not leave the service down (auto-rollback)

## Open implementation notes

- Exact cross-compile tool (`cross` vs linker packages) chosen during implementation; must produce a binary that runs on Raspbian Buster armv7 (glibc compatibility — prefer building against an older glibc baseline or Debian buster-era image if the default Ubuntu runner binary fails at runtime)
- Health endpoint: prefer `/api/sections` (already exists, no auth)
- Timer interval may be tightened later; 2 minutes is the v1 default
