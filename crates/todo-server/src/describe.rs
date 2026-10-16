use actix_web::HttpResponse;
use serde_json::json;

#[allow(clippy::too_many_lines)]
pub async fn describe() -> HttpResponse {
    let description = json!({
        "app": "TODO List",
        "version": "2.0.0",
        "description": "Personal TODO list with 4 sections: Sp, I, Si, P. Each todo has a priority level and optional due date. Each section can be assigned a computer, and each todo can have one AI conversation (Claude Code in tmux) on that computer.",
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
                        "due_date": {"type": "string", "required": false, "format": "YYYY-MM-DD", "description": "Optional due date"}
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
                        "due_date": {"type": "string or null", "required": false, "format": "YYYY-MM-DD", "description": "Set to null to clear the due date"}
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
                "conversation_status": "string enum or absent: busy | waiting | idle | unknown | closed"
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
                "created_at": "string (datetime)"
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
    });

    HttpResponse::Ok().json(description)
}
