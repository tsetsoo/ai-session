# Job plugins

Each folder is a ready-made job: `job.json` (name, title, description, cron, tool, model, priority, limit, project: `choose` or a default project name) and `prompt.md` (the conversation's prompt; `{project}`, `{date}`, `{folder}` are filled in).

`scripts/todo/install.sh` installs them to `~/.ai-remote/jobs/<name>/`; the runner reports them to the hub, and the app's Jobs "+" → "From template" turns one into an ordinary job. Helpers a job needs belong to the core scripts (`scripts/todo`), not here.
