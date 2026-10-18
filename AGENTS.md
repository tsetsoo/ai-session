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

## History

Each directory was imported with `git subtree`, so file history from the original repos is still here. Update from an original repo with:

```sh
git subtree pull --prefix=todo-app todo-app main
git subtree pull --prefix=ai-session-remote ai-session-remote main
```

`origin` is `git@github.com:tsetsoo/ai-session.git`. The `todo-app` and `ai-session-remote` remotes are the original repos.
