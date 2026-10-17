use actix_web::HttpResponse;
use serde_json::{json, Value};

pub async fn describe() -> HttpResponse {
    HttpResponse::Ok().json(description())
}

/// The whole self-describing document: the base endpoints plus projects, sessions,
/// stats and memories.
pub(crate) fn description() -> Value {
    let mut doc = base_description();
    if let Some(endpoints) = doc["endpoints"].as_array_mut() {
        endpoints.extend(project_endpoints());
        endpoints.extend(session_endpoints());
        endpoints.extend(memory_endpoints());
    }
    if let Some(models) = doc["data_model"].as_object_mut() {
        if let Value::Object(more) = project_models() {
            models.extend(more);
        }
    }
    doc
}

#[allow(clippy::too_many_lines)]
fn base_description() -> Value {
    json!({
        "app": "TODO List",
        "version": "2.1.0",
        "description": "Personal TODO list with 4 sections: Sp, I, Si, P. Each todo has a priority level and optional due date. Each section can be assigned a computer, and each todo can have one AI conversation (Claude Code in tmux) on that computer. Projects are folders on a computer; todos and conversations can belong to one. Computers push conversation stats and extracted memories; the server only stores them.",
        "auth": "When the server runs with TODO_API_TOKEN set, every /api endpoint except /api/health requires 'Authorization: Bearer <token>' (/api/ws also accepts ?token=).",
        "base_url": "/api",
        "quick_start": {
            "create_a_todo": "curl -X POST /api/todos -H 'Content-Type: application/json' -d '{\"section\":\"P\",\"title\":\"Go for a run\",\"importance\":\"high\",\"due_date\":\"2026-02-21\"}'",
            "list_all_todos": "curl /api/todos",
            "list_by_section": "curl /api/todos?section=P",
            "list_by_importance": "curl /api/todos?sort=importance",
            "toggle_complete": "curl -X POST /api/todos/{id}/toggle",
            "delete_todo": "curl -X DELETE /api/todos/{id}"
        },
        "sections": ["Sp", "I", "Si", "P"],
        "importance_levels": ["low", "medium", "high", "critical"],
        "endpoints": [
            {
                "method": "GET",
                "path": "/api/describe",
                "description": "Returns this self-describing API documentation"
            },
            {
                "method": "GET",
                "path": "/api/sections",
                "description": "List all sections with their todo counts",
                "example_response": [
                    {"section": "Sp", "total": 3, "completed": 1},
                    {"section": "I", "total": 5, "completed": 2},
                    {"section": "Si", "total": 2, "completed": 0},
                    {"section": "P", "total": 4, "completed": 3}
                ]
            },
            {
                "method": "GET",
                "path": "/api/todos",
                "description": "List all todos, optionally filtered by section and/or sorted",
                "parameters": [
                    {
                        "name": "section",
                        "in": "query",
                        "required": false,
                        "type": "string",
                        "enum": ["Sp", "I", "Si", "P"],
                        "description": "Filter todos by section"
                    },
                    {
                        "name": "sort",
                        "in": "query",
                        "required": false,
                        "type": "string",
                        "enum": ["importance", "due_date"],
                        "description": "Sort order. Default is newest first. 'importance' sorts critical first. 'due_date' sorts earliest due first."
                    },
                    {
                        "name": "project_id",
                        "in": "query",
                        "required": false,
                        "type": "string",
                        "description": "Only the todos of this project"
                    }
                ],
                "example_request": "GET /api/todos?section=P&sort=importance",
                "example_response": [
                    {
                        "id": "550e8400-e29b-41d4-a716-446655440000",
                        "section": "P",
                        "title": "Go for a run",
                        "completed": false,
                        "importance": "high",
                        "due_date": "2026-02-21",
                        "created_at": "2026-01-15 10:30:00",
                        "updated_at": "2026-01-15 10:30:00"
                    }
                ]
            },
            {
                "method": "GET",
                "path": "/api/todos/{id}",
                "description": "Get a single todo by ID",
                "parameters": [
                    {"name": "id", "in": "path", "required": true, "type": "string (UUID)"}
                ]
            },
            {
                "method": "POST",
                "path": "/api/todos",
                "description": "Create a new todo",
                "request_body": {
                    "content_type": "application/json",
                    "fields": {
                        "section": {"type": "string", "required": true, "enum": ["Sp", "I", "Si", "P"]},
                        "title": {"type": "string", "required": true, "description": "The todo title (non-empty)"},
                        "importance": {"type": "string", "required": false, "enum": ["low", "medium", "high", "critical"], "default": "medium"},
                        "due_date": {"type": "string", "required": false, "format": "YYYY-MM-DD", "description": "Optional due date"},
                        "project_id": {"type": "string", "required": false, "description": "Optional project; 404 if it doesn't exist"}
                    }
                },
                "example_request": {"section": "P", "title": "Go for a run", "importance": "high", "due_date": "2026-02-21"},
                "example_response": {
                    "id": "550e8400-e29b-41d4-a716-446655440000",
                    "section": "P",
                    "title": "Go for a run",
                    "completed": false,
                    "importance": "high",
                    "due_date": "2026-02-21",
                    "created_at": "2026-01-15 10:30:00",
                    "updated_at": "2026-01-15 10:30:00"
                },
                "response_status": 201
            },
            {
                "method": "PATCH",
                "path": "/api/todos/{id}",
                "description": "Partially update a todo. Only include fields you want to change.",
                "parameters": [
                    {"name": "id", "in": "path", "required": true, "type": "string (UUID)"}
                ],
                "request_body": {
                    "content_type": "application/json",
                    "fields": {
                        "title": {"type": "string", "required": false},
                        "completed": {"type": "boolean", "required": false},
                        "section": {"type": "string", "required": false, "enum": ["Sp", "I", "Si", "P"]},
                        "importance": {"type": "string", "required": false, "enum": ["low", "medium", "high", "critical"]},
                        "due_date": {"type": "string or null", "required": false, "format": "YYYY-MM-DD", "description": "Set to null to clear the due date"},
                        "project_id": {"type": "string or null", "required": false, "description": "Set to null to remove the todo from its project; 404 for an unknown project"}
                    }
                },
                "example_request": {"title": "Go for a long run", "importance": "critical"}
            },
            {
                "method": "DELETE",
                "path": "/api/todos/{id}",
                "description": "Delete a todo",
                "parameters": [
                    {"name": "id", "in": "path", "required": true, "type": "string (UUID)"}
                ],
                "example_response": {"deleted": "550e8400-e29b-41d4-a716-446655440000"}
            },
            {
                "method": "POST",
                "path": "/api/todos/{id}/toggle",
                "description": "Toggle the completed status of a todo",
                "parameters": [
                    {"name": "id", "in": "path", "required": true, "type": "string (UUID)"}
                ]
            },
            {"method": "GET", "path": "/api/health", "description": "Liveness check; never requires a token"},
            {"method": "GET", "path": "/api/computers", "description": "List computers"},
            {
                "method": "POST",
                "path": "/api/computers",
                "description": "Create a computer (no SSH keys are stored)",
                "example_request": {"name": "Mac", "hostname": "mac.tailnet.ts.net", "port": 22, "username": "me"},
                "response_status": 201
            },
            {"method": "PATCH", "path": "/api/computers/{id}", "description": "Update name, hostname, port or username"},
            {"method": "DELETE", "path": "/api/computers/{id}", "description": "Delete a computer; 409 while a section or conversation uses it"},
            {"method": "GET", "path": "/api/sections/computers", "description": "Section → computer mappings (sections without one are omitted)"},
            {
                "method": "PUT",
                "path": "/api/sections/{code}/computer",
                "description": "Assign a computer and default working directory to a section. tool: claude | codex | cursor (default claude). Only claude sections can start new conversations; the others can only link existing ones",
                "example_request": {"computer_id": "<uuid>", "cwd": "~/programming", "tool": "claude"}
            },
            {"method": "DELETE", "path": "/api/sections/{code}/computer", "description": "Remove a section's computer"},
            {"method": "GET", "path": "/api/conversations", "description": "All conversations with their computer and status"},
            {"method": "GET", "path": "/api/todos/{id}/conversation", "description": "The todo's conversation; 404 if none"},
            {
                "method": "POST",
                "path": "/api/todos/{id}/conversation",
                "description": "Get or create the todo's conversation from its section's computer (snapshotting computer and cwd). Reopening a closed one resets status to unknown. 409 if the section has no computer, or if the section's tool can't start conversations (codex, cursor: link one instead). The client then SSHes to the computer and runs: ai-todo-open <tmux_name> <cwd> <session_id> <tool>"
            },
            {
                "method": "POST",
                "path": "/api/todos/{id}/conversation/link",
                "description": "Link an existing conversation (made outside the todo app) to the todo. 200 with the Conversation. Linking the conversation the todo already has is a no-op; a different one gets 409 unless ?replace=true. 409 if that (tool, session_id) is linked to another todo. 404 if the todo or computer is missing. 400 for an unknown tool or empty session_id/cwd",
                "parameters": [
                    {"name": "replace", "in": "query", "required": false, "type": "boolean", "description": "Replace the todo's current conversation. The replacement gets its own tmux name (ai/<tool>/todo-<8>-<first 8 of session_id>), so it never attaches to the old conversation's still-running tmux session"}
                ],
                "example_request": {"computer_id": "<uuid>", "tool": "codex", "session_id": "019f8b4e-ff53-7201-8585-162b40a93fb3", "cwd": "~/programming/sigma-revenue"}
            },
            {
                "method": "POST",
                "path": "/api/todos/from-conversation",
                "description": "Create a todo linked to an existing conversation, atomically. 201 {todo, conversation}. Same 400/404/409 rules as link. Optional importance and due_date, as for POST /api/todos",
                "example_request": {"section": "Sp", "title": "Review data-management PR 630", "computer_id": "<uuid>", "tool": "claude", "session_id": "<uuid>", "cwd": "~/Spread/Repository", "importance": "high"},
                "response_status": 201
            },
            {"method": "POST", "path": "/api/todos/{id}/conversation/close", "description": "Mark closed after the client killed the tmux session; the conversation stays resumable"},
            {"method": "DELETE", "path": "/api/todos/{id}/conversation", "description": "Forget the conversation link (the conversation itself stays on the computer); afterwards only sections whose tool is claude can start a new conversation on open (POST /conversation); for codex and cursor sections, link a conversation again"},
            {
                "method": "POST",
                "path": "/api/conversations/status",
                "description": "Status hook endpoint. Identify the conversation with session_id (or claude_session_id, sent by older hooks) and tool (optional, default claude: older hooks are Claude hooks); one post updates at most one conversation. 204 on success, 404 for sessions that are not todo conversations, 400 without an id or for status closed",
                "example_request": {"session_id": "<uuid>", "tool": "claude", "status": "waiting", "message": "Claude needs your permission"}
            }
        ],
        "data_model": {
            "Todo": {
                "id": "string (UUID v4) - unique identifier",
                "section": "string enum: Sp | I | Si | P",
                "title": "string - the todo title",
                "completed": "boolean - whether the todo is done",
                "importance": "string enum: low | medium | high | critical",
                "due_date": "string (YYYY-MM-DD) or null - optional due date",
                "created_at": "string (datetime) - when the todo was created",
                "updated_at": "string (datetime) - when the todo was last modified",
                "conversation_status": "string enum or absent: busy | waiting | idle | unknown | closed",
                "project_id": "string or absent - the todo's project"
            },
            "Conversation": {
                "todo_id": "string (UUID)",
                "computer": "Computer {id, name, hostname, port, username, created_at, updated_at}",
                "cwd": "string - working directory snapshot (may start with ~)",
                "tool": "string enum: claude | codex | cursor",
                "tmux_name": "string - ai/<tool>/todo-<first 8 chars of todo id>",
                "session_id": "string - the tool's conversation id: claude --session-id / --resume <id>, codex resume <id>",
                "claude_session_id": "string or null - same value as session_id for claude conversations, null for other tools; kept for older clients",
                "status": "string enum: busy | waiting | idle | unknown | closed",
                "status_message": "string or null",
                "status_updated_at": "string (datetime) or null",
                "created_at": "string (datetime)",
                "project_id": "string or absent - the conversation's project (its session's, or matched from computer + cwd)"
            }
        },
        "usage_notes": [
            "All request/response bodies use JSON (Content-Type: application/json)",
            "Section values are case-sensitive: Sp, I, Si, P",
            "Importance values are lowercase: low, medium, high, critical",
            "If importance is omitted on create, it defaults to 'medium'",
            "due_date format is YYYY-MM-DD",
            "The toggle endpoint is a convenience for flipping completed status",
            "Todos are returned in reverse chronological order by default",
            "The PATCH endpoint only updates fields that are present in the request body",
            "Empty or whitespace-only titles are rejected with 400"
        ]
    })
}

fn project_endpoints() -> Vec<Value> {
    vec![
        json!({
            "method": "GET",
            "path": "/api/projects",
            "description": "List projects ordered by name, each with its computer and counts: open_todos, sessions, memories (not archived) and last_activity (latest session activity)"
        }),
        json!({
            "method": "POST",
            "path": "/api/projects",
            "description": "Create a project: a folder on one computer. folder must start with ~ or /; /Users/<username>/… and /home/<username>/… of that computer are stored as ~/…, without a trailing /. 201 with the Project. 404 for an unknown computer. 409 when (computer, folder) is taken, or when the folder is inside or contains another project's folder on the same computer (the message names it; projects can't be nested). Re-matches that computer's conversations",
            "example_request": {"name": "todo-app", "computer_id": "<uuid>", "folder": "~/programming/todo-app", "repo_url": "git@github.com:tsetsoo/todo-app.git", "digest_enabled": true},
            "response_status": 201
        }),
        json!({
            "method": "GET",
            "path": "/api/projects/suggestions",
            "description": "Suggested projects from the cwds of known conversations: a /.claude/worktrees/<x> suffix is dropped, then the path is cut to two segments below ~ (three for other absolute paths). Grouped by computer and folder, with the session count, latest activity, example cwds and the repo URL of a session whose repo root is that folder. Folders that already are, lie inside, or contain a project are left out. Ordered by session count. Accept one with POST /api/projects",
            "example_response": [{"computer": "Computer", "folder": "~/programming/sigma-revenue", "name": "sigma-revenue", "repo_url": null, "sessions": 19, "last_activity": "2026-10-16T09:12:03Z", "example_cwds": ["~/programming/sigma-revenue/sigma-revenue-backend"]}]
        }),
        json!({"method": "GET", "path": "/api/projects/{id}", "description": "One project (same shape as the list items); 404 if missing"}),
        json!({
            "method": "PATCH",
            "path": "/api/projects/{id}",
            "description": "Change any of name, folder, repo_url (null clears it) and digest_enabled. A new folder follows the same rules and 409s as on create, and re-matches the computer's conversations",
            "example_request": {"folder": "~/programming/todo-app", "digest_enabled": false}
        }),
        json!({
            "method": "DELETE",
            "path": "/api/projects/{id}",
            "description": "Delete a project. Its todos lose the project, conversations are matched to the remaining projects (overrides pointing at it are cleared) and memories follow their conversation or become project-less. Nothing else is deleted",
            "example_response": {"deleted": "<uuid>"}
        }),
    ]
}

fn session_endpoints() -> Vec<Value> {
    vec![
        json!({
            "method": "POST",
            "path": "/api/sessions/stats",
            "description": "Bulk upsert of conversation stats from a computer (ai-todo-memory / ai-todo-sessions stats --json). Stats are a full recompute per transcript, so the upsert is idempotent; days replaces all of that conversation's day rows. A conversation without a project override is matched to the project whose folder is the longest prefix of its cwd. 200 {upserted, sessions: [{tool, session_id, project_id}]}. 404 for an unknown computer_id, 400 for an unknown tool, empty session_id/cwd or a bad day",
            "example_request": {"computer_id": "<uuid>", "sessions": [{"tool": "claude", "session_id": "<id>", "cwd": "~/programming/todo-app", "title": "Add projects", "repo_root": "~/programming/todo-app", "repo_url": "git@github.com:tsetsoo/todo-app.git",
                "stats": {"prompts": 12, "assistant_turns": 12, "input_tokens": 4021, "output_tokens": 51234, "cache_read_tokens": 9_123_456, "cache_creation_tokens": 402_311, "active_seconds": 5400, "first_activity": "2026-10-16T07:01:12Z", "last_activity": "2026-10-16T09:12:03Z", "files_touched": ["crates/todo-server/src/db.rs"], "models": ["claude-opus-5-5"]},
                "days": [{"day": "2026-10-16", "prompts": 12, "assistant_turns": 12, "input_tokens": 4021, "output_tokens": 51234, "cache_read_tokens": 9_123_456, "cache_creation_tokens": 402_311, "active_seconds": 5400, "files_touched": 1}]}]}
        }),
        json!({
            "method": "GET",
            "path": "/api/sessions",
            "description": "Known conversations, newest activity first, with their stats; todo_id and status are added when a todo links the conversation",
            "parameters": [
                {"name": "project_id", "in": "query", "required": false, "type": "string"},
                {"name": "computer_id", "in": "query", "required": false, "type": "string"},
                {"name": "since", "in": "query", "required": false, "type": "string (YYYY-MM-DD or ISO 8601)", "description": "last_activity at or after this"},
                {"name": "limit", "in": "query", "required": false, "type": "integer", "description": "Default 200, at most 1000"}
            ]
        }),
        json!({
            "method": "PUT",
            "path": "/api/sessions/{tool}/{session_id}/project",
            "description": "Override a conversation's project: {\"project_id\": \"<id>\"} (the project must be on the conversation's computer, else 409), {\"project_id\": null} for no project, or {\"auto\": true} to clear the override and match automatically again. The conversation's memories move with it. 200 with the Session; 404 for an unknown session or project",
            "example_request": {"project_id": "<uuid>"}
        }),
        json!({
            "method": "GET",
            "path": "/api/stats/weekly",
            "description": "Usage of one week (Monday to Sunday), summed from the per-day rows: totals and by_project, by_section, by_computer. sessions counts distinct conversations with activity that week. Token sums are null when every value is null. A conversation's section is its todo's section, else the only section mapped to its computer, else null. 400 when week_start is not a Monday",
            "parameters": [
                {"name": "week_start", "in": "query", "required": false, "type": "string (YYYY-MM-DD, a Monday)", "description": "Default: the Monday of the server's local today"},
                {"name": "project_id", "in": "query", "required": false, "type": "string", "description": "Restrict every grouping to this project's conversations"}
            ],
            "example_response": {"week_start": "2026-10-12", "week_end": "2026-10-18",
                "totals": {"sessions": 23, "prompts": 180, "assistant_turns": 176, "input_tokens": 51_000, "output_tokens": 830_000, "cache_read_tokens": 90_000_000, "cache_creation_tokens": 4_000_000, "active_seconds": 61200, "files_touched": 88},
                "by_project": [{"project_id": "<uuid>", "name": "todo-app", "sessions": 5}, {"project_id": null, "name": null, "sessions": 18}],
                "by_section": [{"section": "Sp", "sessions": 4}, {"section": null, "sessions": 19}],
                "by_computer": [{"computer_id": "<uuid>", "name": "spreads-macbook-pro", "sessions": 4}]}
        }),
    ]
}

fn memory_endpoints() -> Vec<Value> {
    vec![
        json!({
            "method": "GET",
            "path": "/api/memories",
            "description": "Memories, pinned first, then newest first",
            "parameters": [
                {"name": "project_id", "in": "query", "required": false, "type": "string"},
                {"name": "todo_id", "in": "query", "required": false, "type": "string"},
                {"name": "kind", "in": "query", "required": false, "type": "string", "description": "decision | gotcha | open_thread | done | files_changed; repeat it or separate with commas"},
                {"name": "since", "in": "query", "required": false, "type": "string (YYYY-MM-DD or ISO 8601)", "description": "created_at at or after this"},
                {"name": "tool", "in": "query", "required": false, "type": "string"},
                {"name": "session_id", "in": "query", "required": false, "type": "string"},
                {"name": "pinned", "in": "query", "required": false, "type": "boolean"},
                {"name": "include_archived", "in": "query", "required": false, "type": "boolean", "description": "Default false"},
                {"name": "limit", "in": "query", "required": false, "type": "integer", "description": "Default 200, at most 1000"}
            ]
        }),
        json!({
            "method": "POST",
            "path": "/api/memories",
            "description": "Add a manual memory. project_id or todo_id is required; with only a todo, the memory takes the todo's project. text is 1-400 characters, files at most 20. 201 with the Memory; 404 for an unknown project or todo",
            "example_request": {"kind": "decision", "text": "Digests go into CLAUDE.local.md.", "files": ["scripts/todo/ai-todo-memory"], "project_id": "<uuid>", "pinned": true},
            "response_status": 201
        }),
        json!({
            "method": "POST",
            "path": "/api/memories/bulk",
            "description": "Memories extracted from one conversation (from ai-todo-memory). The conversation's session row is created if missing and matched to a project; todo_id comes from the todo that links the conversation. A memory is a duplicate (counted, not stored) when its normalized text equals that of any memory of the same project, archived included, or its word-set similarity is at least 0.8 with a memory of the same project and kind from the last 90 days. supersedes archives unpinned memories of the same project. 201 even when everything was a duplicate. 404 for an unknown computer, 400 for bad text, files, confidence or kind",
            "example_request": {"computer_id": "<uuid>", "tool": "claude", "session_id": "<id>", "cwd": "~/programming/todo-app",
                "memories": [{"kind": "decision", "text": "Stats are stored per local day.", "files": ["crates/todo-server/src/sessions.rs"], "confidence": 0.85, "supersedes": ["<memory id>"]}]},
            "example_response": {"inserted": ["Memory"], "duplicates": 2, "archived": ["<memory id>"], "project_id": "<uuid>", "todo_id": null},
            "response_status": 201
        }),
        json!({
            "method": "PATCH",
            "path": "/api/memories/{id}",
            "description": "Change any of text, kind, files, pinned, archived, project_id (null clears) and todo_id (null clears). Pin and archive with {\"pinned\": true} / {\"archived\": true}. 409 when the new text or kind equals another memory of the same conversation",
            "example_request": {"pinned": true}
        }),
        json!({"method": "DELETE", "path": "/api/memories/{id}", "description": "Delete a memory permanently (archive it instead to keep it from being extracted again)", "example_response": {"deleted": "<uuid>"}}),
    ]
}

fn project_models() -> Value {
    json!({
        "Project": {
            "id": "string (UUID)",
            "name": "string",
            "computer": "Computer",
            "folder": "string - folder on the computer, ~ for its home, no trailing /",
            "repo_url": "string or null",
            "digest_enabled": "boolean - whether the computer feeds this project's memories into new conversations",
            "created_at": "string (datetime)",
            "updated_at": "string (datetime)",
            "open_todos": "integer",
            "sessions": "integer",
            "memories": "integer - not archived",
            "last_activity": "string (ISO 8601) or null"
        },
        "ProjectSuggestion": {
            "computer": "Computer",
            "folder": "string",
            "name": "string - the folder's last segment",
            "repo_url": "string or null",
            "sessions": "integer",
            "last_activity": "string (ISO 8601) or null",
            "example_cwds": "array of string"
        },
        "Session": {
            "tool": "string enum: claude | codex | cursor",
            "session_id": "string",
            "computer_id": "string (UUID)",
            "cwd": "string (with ~)",
            "title": "string or null - first prompt, redacted, at most 120 characters",
            "repo_root": "string or null",
            "repo_url": "string or null",
            "project_id": "string or null",
            "project_override": "boolean - set in the app; automatic matching leaves the project alone",
            "prompts": "integer",
            "assistant_turns": "integer",
            "input_tokens": "integer or null",
            "output_tokens": "integer or null",
            "cache_read_tokens": "integer or null",
            "cache_creation_tokens": "integer or null",
            "active_seconds": "integer",
            "first_activity": "string (ISO 8601) or null",
            "last_activity": "string (ISO 8601) or null",
            "files_touched": "array of string - relative to cwd, at most 200",
            "models": "array of string",
            "stats_updated_at": "string (datetime) or null",
            "created_at": "string (datetime)",
            "todo_id": "string or absent - the todo that links this conversation",
            "status": "string enum or absent: busy | waiting | idle | unknown | closed"
        },
        "Memory": {
            "id": "string (UUID)",
            "project_id": "string or null",
            "todo_id": "string or null",
            "computer_id": "string or null",
            "tool": "string or null - null for manual memories",
            "session_id": "string or null",
            "kind": "string enum: decision | gotcha | open_thread | done | files_changed",
            "text": "string - 1 to 400 characters",
            "files": "array of string - relative to the project folder",
            "confidence": "number 0-1 or null",
            "source": "string enum: extracted | manual",
            "pinned": "boolean",
            "archived": "boolean",
            "created_at": "string (datetime)",
            "updated_at": "string (datetime)"
        },
        "WeeklyStats": {
            "week_start": "string (YYYY-MM-DD, Monday)",
            "week_end": "string (YYYY-MM-DD, Sunday)",
            "totals": "counters: sessions, prompts, assistant_turns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, active_seconds, files_touched",
            "by_project": "array of {project_id, name, …counters}; project_id null for conversations without a project",
            "by_section": "array of {section, …counters}; section null when unassigned",
            "by_computer": "array of {computer_id, name, …counters}"
        }
    })
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::description;

    const CODES: [&str; 4] = ["Sp", "I", "Si", "P"];

    fn endpoints(doc: &Value) -> Vec<(String, String)> {
        doc["endpoints"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| (e["method"].as_str().unwrap().to_string(), e["path"].as_str().unwrap().to_string()))
            .collect()
    }

    /// Every string in the document, keys included.
    fn strings(value: &Value, out: &mut Vec<String>) {
        match value {
            Value::String(s) => out.push(s.clone()),
            Value::Array(items) => items.iter().for_each(|v| strings(v, out)),
            Value::Object(map) => {
                for (k, v) in map {
                    out.push(k.clone());
                    strings(v, out);
                }
            }
            _ => {}
        }
    }

    /// Values of `section`/`sections` keys, and arrays that list section codes.
    fn section_values(value: &Value, out: &mut Vec<Value>) {
        match value {
            Value::Array(items) => {
                if items.iter().any(|v| v.as_str().is_some_and(|s| CODES.contains(&s))) {
                    out.extend(items.iter().cloned());
                }
                items.iter().for_each(|v| section_values(v, out));
            }
            Value::Object(map) => {
                for (k, v) in map {
                    if k == "section" || k == "sections" {
                        match v {
                            Value::Array(items) => out.extend(items.iter().cloned()),
                            other => out.push(other.clone()),
                        }
                    }
                    section_values(v, out);
                }
            }
            _ => {}
        }
    }

    #[test]
    fn describe_lists_new_endpoints_without_section_names() {
        let doc = description();
        let listed = endpoints(&doc);
        for (method, path) in [
            ("GET", "/api/projects"),
            ("POST", "/api/projects"),
            ("GET", "/api/projects/suggestions"),
            ("GET", "/api/projects/{id}"),
            ("PATCH", "/api/projects/{id}"),
            ("DELETE", "/api/projects/{id}"),
            ("POST", "/api/sessions/stats"),
            ("GET", "/api/sessions"),
            ("PUT", "/api/sessions/{tool}/{session_id}/project"),
            ("GET", "/api/stats/weekly"),
            ("GET", "/api/memories"),
            ("POST", "/api/memories"),
            ("POST", "/api/memories/bulk"),
            ("PATCH", "/api/memories/{id}"),
            ("DELETE", "/api/memories/{id}"),
        ] {
            assert!(listed.contains(&(method.to_string(), path.to_string())), "{method} {path} is described");
        }
        for model in ["Project", "ProjectSuggestion", "Session", "Memory", "WeeklyStats"] {
            assert!(doc["data_model"].get(model).is_some(), "data_model.{model}");
        }
        for model in ["Todo", "Conversation"] {
            assert!(doc["data_model"][model].get("project_id").is_some(), "{model}.project_id");
        }

        // Section codes only ever appear as the codes themselves.
        let mut values = Vec::new();
        section_values(&doc, &mut values);
        assert!(!values.is_empty());
        for value in &values {
            match value {
                // A field description ({"type", "enum", …}): its enum array is collected on its own.
                Value::Null | Value::Object(_) => {}
                Value::String(s) => {
                    let words: Vec<&str> = s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
                    let allowed = |w: &&str| CODES.contains(w) || ["string", "enum", "or", "null"].contains(w);
                    assert!(words.iter().all(allowed), "section value {s:?} holds more than codes");
                }
                other => panic!("unexpected section value {other}"),
            }
        }
        // …and no code is followed by something that reads like an expansion of it.
        let mut all = Vec::new();
        strings(&doc, &mut all);
        for s in &all {
            for code in CODES {
                for (i, _) in s.match_indices(code) {
                    let before = s[..i].chars().next_back();
                    let after = &s[i + code.len()..];
                    let whole_word = before.is_none_or(|c| !c.is_alphanumeric())
                        && after.chars().next().is_none_or(|c| !c.is_alphanumeric());
                    if !whole_word {
                        continue;
                    }
                    let next = after.trim_start().chars().next();
                    assert!(
                        !matches!(next, Some('(' | '=' | ':' | '-' | '–' | '—')),
                        "section code {code} looks expanded in {s:?}"
                    );
                }
            }
        }
    }
}
