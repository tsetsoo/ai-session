# AI Session

One repo for the todo hub and the session app, so an agent can change both sides of the same API without switching projects.

| Directory | What it is |
| --- | --- |
| `todo-app/` | Rust API server (`todo-server`, `todo-shared`) |
| `ai-session-remote/` | Swift iOS and Mac app, plus the host scripts that call the hub |

The app reaches the server through `TODO_HUB_URL` and `TODO_API_TOKEN` (`~/.ai-remote/todo-hub.conf`). The server listens on port 8080.

Original remotes, kept for `git subtree pull`:

- `todo-app` → `git@github.com:tsetsoo/todo-app.git`
- `ai-session-remote` → `git@github.com:tsetsoo/ai-session-remote.git`

See `AGENTS.md` for how to build and where to edit.
