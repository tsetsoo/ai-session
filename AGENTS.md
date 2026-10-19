# Working in this repo

This repo is the working tree for both products. Edit them here. The older checkouts at `programming/todo-app` and `programming/ai-session-remote` are not this tree: the todo checkout there is behind GitHub, and the session checkout there can drift from the copy in this repo.

## Layout

- `todo-app/` — API-only Rust server. Crates are `crates/todo-shared` and `crates/todo-server`. No web UI.
- `ai-session-remote/` — Xcode app (`App/`), shared Swift package (`Sources/AISessionCore`), and host scripts (`scripts/todo/`).

A hub change usually touches both. Server routes and types live under `todo-app/crates/`. The client calls them from `ai-session-remote/Sources/AISessionCore/TodoHub/` and `ai-session-remote/App/AISessionRemote/Services/TodoHubStore.swift`. The machine-side scripts live in `ai-session-remote/scripts/todo/`.

## Connect them

Host config is `~/.ai-remote/todo-hub.conf` with `TODO_HUB_URL` and `TODO_API_TOKEN`. The server default is `http://<host>:8080`.

## Commands

From `todo-app/`:

- `cargo test`
- `cargo build -p todo-server`
- `./build.sh` for a release binary at `target/release/todo-server`

GitHub Actions for the server live in `.github/workflows/` at this repo's root and run Cargo in `todo-app/`. A push to `main` publishes `pi-latest` on this public repo only when server files change. The Pi downloads it from `https://github.com/tsetsoo/ai-session/releases/download/pi-latest`.

From `ai-session-remote/`:

- `xcodegen generate` then open `AISessionRemote.xcodeproj` (Xcode 16+, XcodeGen)
- `scripts/todo/test-todo-scripts.sh` for the host scripts (offline, no hub required)

## Rebuild the Mac app

When asked to rebuild, reinstall, or update the local Mac app, run this and do not invent another install:

```sh
ai-session-remote/scripts/rebuild-mac-app.sh
```

It builds Release with XcodeGen and `xcodebuild`, checks the signature is Apple Development team `233QTK6KCL`, quits AI Session Remote, waits until that process is gone, replaces `~/Applications/AI Session Remote.app`, and opens it.

Keep that team id. An ad-hoc build or one signed "AI Session Remote Local" has no Team ID, so the login keychain stores a new cdhash every rebuild and asks again for the SSH keys and the hub token. Those settings are on the `AISessionRemoteMac` target in `ai-session-remote/project.yml`. After a change of signing identity, the user clicks Always Allow once. Later rebuilds with the same team must not prompt.

Replace the app from this tree. The older checkout at `programming/ai-session-remote` is not the app to rebuild.

## History

Each directory was imported with `git subtree`, so file history from the original repos is still here. Update from an original repo with:

```sh
git subtree pull --prefix=todo-app todo-app main
git subtree pull --prefix=ai-session-remote ai-session-remote main
```

`origin` is `git@github.com:tsetsoo/ai-session.git`. The `todo-app` and `ai-session-remote` remotes are the original repos.
