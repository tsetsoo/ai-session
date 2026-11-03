# Watchers

Each folder is one watcher plugin:

- `watcher`: the executable. `watcher check` prints `{"problems": [{"key", "title", "details", "url", "folder"}], "partial": false}`; `watcher resolve <key>` resolves one problem at the source (optional).
- `watcher.json`: its manifest: `name`, `title`, `description`, `settings` (`key`, `label`, `secret`), `resolve`, `resolve_label`.

`scripts/todo/install.sh` installs them to `~/.ai-remote/watchers/<name>` and `<name>.json`. Settings go in `~/.ai-remote/watchers/env` on that computer (mode 600); the installer never writes it. The runner reports installed watchers to the hub (which settings are set, never their values), and a Watch job in the app picks one.
