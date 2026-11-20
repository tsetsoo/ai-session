# Scoped API tokens

The hub accepts bearer tokens with per-token project, computer, and todo grants. The existing `TODO_API_TOKEN` still grants full access and can be used to look up the IDs for those grants.

Set `TODO_SCOPED_TOKENS_FILE` in the server environment to the path of a JSON file readable by the hub service account. Limit access to that account and keep the file outside version control. Use a fresh random token for each installation, for example with `openssl rand -hex 32`. Replace the key and IDs in this example with the generated token and the IDs returned by the hub.

```json
{
  "replace-with-a-generated-random-token": {
    "project_ids": ["project-id"],
    "computer_ids": ["spread-computer-id", "tsvetelin-computer-id"],
    "todo_ids": ["individually-shared-todo-id"]
  }
}
```

Omitted or empty lists grant no access in that category. Set `"include_computer_projects": true` to inherit grants to all projects and their todos on the listed computers. Inherited grants track current section-to-computer assignments, including for newly created projects. The server reads the file at startup. Restart the service after adding, changing, or revoking a token. A missing or malformed configured file prevents startup. Configuring scoped tokens enables authentication even when `TODO_API_TOKEN` is unset.

| Grant | Access |
| --- | --- |
| Project ID | Todos assigned to the project. The project record is visible when its current computer is also granted. |
| Computer ID | That computer's hub entry and section mappings. |
| Todo ID | That individual todo, including when its project is outside the token's project grants. |

Conversation lists include only conversations attached to visible todos, on granted computers, and in granted projects when the conversation has a project. Section counts reflect visible todos. Direct reads of hidden todos or projects return 404.

Scoped tokens can read the todo and project lists and individual records, plus the computer, section, section-to-computer, and conversation lists. Use manual refresh with a scoped token. These grants govern the Todo Hub API. SSH access uses separate credentials.

Scoped tokens can also make these writes:

| Resource | Writes |
| --- | --- |
| Todo | Edit or toggle any visible todo. Create in or move to a granted project on a granted computer. Delete when the todo has no linked conversations, memories, job runs, ideas, or push mute. |
| Project | Edit the name, digest and daily update settings, worktree preference, and MCP defaults on a visible project. |
| Computer | Rename a granted computer and set its MCP defaults. |
| Conversation | Start a conversation in a granted project on a granted computer. Save or remove a conversation when its todo, project and computer are visible to the token. |

Creating or deleting a project or computer, changing a project's folder or repository, and changing a computer's SSH settings require a full-access token. The same applies to WebSocket updates and endpoints for other resources.

When switching an existing app installation from a full-access token to a scoped token, clear the app's existing hub cache before giving that installation to a restricted user. Older snapshots may contain data downloaded with the full-access token.

## MacBook policy

Use the full-access token for Tsvetelin’s app. Use separate scoped tokens for Spread and codbex, with `include_computer_projects` enabled and the `computer_ids` returned by the hub for these grants:

| Installation | Computers |
| --- | --- |
| Spread | Spread and Tsvetelin |
| codbex | codbex and Tsvetelin |

Machine-wide enforcement also requires removing full-access credentials from accounts on the restricted Macs and preventing those accounts from reaching a full-access account over SSH. Existing host helpers use endpoints outside the scoped app policy. Plan their credential migration before revoking the shared token, so status reporting and background jobs continue to work.

## Background helper credentials

Add a separate token per computer to the same server configuration file. Its entry takes this form.

```json
{
  "replace-with-a-generated-helper-token": {
    "helper_computer_id": "computer-id"
  }
}
```

Set `TODO_HELPER_API_TOKEN` in that computer's private `~/.ai-remote/todo-hub.conf` after upgrading its host helpers. Status and session hooks, the job runner, nightly memory, and project updates prefer the helper token and fall back to the existing token when the field is absent. Verify the new token before rotating the old credential. The hub binds status reports, resume and session reconciliation, session-stat uploads, health and watcher inventory, job claims and results, memory operations, and daily and weekly updates to the configured computer. Keep helper and app tokens separate.

Other host scripts still use `TODO_API_TOKEN`. Audit and migrate their credentials before removing the old shared token from the server. A restricted app token cannot substitute for a helper credential.

Before rotating the shared token, verify an independent Pi administrator login. Check from the shared tmux login that its keys and SSH agent cannot administer the Pi or access the full-access Hub login. Only then revoke the old credentials and verify that they are rejected. Keep the Pi administrator keys and the full-access Hub token outside the shared login.
