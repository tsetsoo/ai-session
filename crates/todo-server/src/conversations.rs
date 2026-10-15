//! Computers, section → computer mapping, and per-todo AI conversations.
//!
//! The server only stores which conversation belongs to which todo. Clients
//! SSH to the computer themselves and run `ai-todo-open` with the stored
//! `tmux_name`, `cwd` and `claude_session_id`.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, ErrorCode, OptionalExtension, Row};
use todo_shared::{
    Computer, Conversation, ConversationStatus, ConversationStatusRequest, CreateComputerRequest, DeleteResponse,
    Section, SectionComputer, SetSectionComputerRequest, UpdateComputerRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::db::DbPool;

const SUPPORTED_TOOLS: &[&str] = &["claude"];

const COMPUTER_COLS: &str = "id, name, hostname, port, username, created_at, updated_at";

/// Conversation columns (0..=8) followed by its computer (9..=15).
const CONVERSATION_SELECT: &str = "SELECT c.todo_id, c.cwd, c.tool, c.tmux_name, c.claude_session_id, c.status,
        c.status_message, c.status_updated_at, c.created_at,
        m.id, m.name, m.hostname, m.port, m.username, m.created_at, m.updated_at
     FROM conversations c JOIN computers m ON m.id = c.computer_id";

/// Section mapping columns (0..=2) followed by its computer (3..=9).
const SECTION_COMPUTER_SELECT: &str = "SELECT s.section, s.cwd, s.tool,
        m.id, m.name, m.hostname, m.port, m.username, m.created_at, m.updated_at
     FROM section_computers s JOIN computers m ON m.id = s.computer_id";

fn error(status: actix_web::http::StatusCode, msg: impl ToString) -> HttpResponse {
    HttpResponse::build(status).json(serde_json::json!({"error": msg.to_string()}))
}

fn server_error(e: impl ToString) -> HttpResponse {
    error(actix_web::http::StatusCode::INTERNAL_SERVER_ERROR, e)
}

fn bad_request(msg: &str) -> HttpResponse {
    error(actix_web::http::StatusCode::BAD_REQUEST, msg)
}

fn not_found(msg: &str) -> HttpResponse {
    error(actix_web::http::StatusCode::NOT_FOUND, msg)
}

fn conflict(msg: impl ToString) -> HttpResponse {
    error(actix_web::http::StatusCode::CONFLICT, msg)
}

fn computer_at(row: &Row, start: usize) -> rusqlite::Result<Computer> {
    Ok(Computer {
        id: row.get(start)?,
        name: row.get(start + 1)?,
        hostname: row.get(start + 2)?,
        port: row.get(start + 3)?,
        username: row.get(start + 4)?,
        created_at: row.get(start + 5)?,
        updated_at: row.get(start + 6)?,
    })
}

fn row_to_conversation(row: &Row) -> rusqlite::Result<Conversation> {
    let status: String = row.get(5)?;
    Ok(Conversation {
        todo_id: row.get(0)?,
        cwd: row.get(1)?,
        tool: row.get(2)?,
        tmux_name: row.get(3)?,
        claude_session_id: row.get(4)?,
        status: ConversationStatus::parse(&status).unwrap_or(ConversationStatus::Unknown),
        status_message: row.get(6)?,
        status_updated_at: row.get(7)?,
        created_at: row.get(8)?,
        computer: computer_at(row, 9)?,
    })
}

fn row_to_section_computer(row: &Row) -> rusqlite::Result<SectionComputer> {
    let section: String = row.get(0)?;
    Ok(SectionComputer {
        section: Section::parse(&section).unwrap_or(Section::P),
        cwd: row.get(1)?,
        tool: row.get(2)?,
        computer: computer_at(row, 3)?,
    })
}

pub(crate) fn get_computer(conn: &Connection, id: &str) -> rusqlite::Result<Option<Computer>> {
    conn.query_row(&format!("SELECT {COMPUTER_COLS} FROM computers WHERE id = ?1"), params![id], |r| computer_at(r, 0))
        .optional()
}

pub(crate) fn load_conversation(conn: &Connection, todo_id: &str) -> rusqlite::Result<Option<Conversation>> {
    conn.query_row(&format!("{CONVERSATION_SELECT} WHERE c.todo_id = ?1"), params![todo_id], row_to_conversation)
        .optional()
}

#[derive(Debug)]
pub(crate) enum OpenError {
    TodoNotFound,
    NoComputer(String),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for OpenError {
    fn from(e: rusqlite::Error) -> Self {
        OpenError::Db(e)
    }
}

/// tmux names must match `[a-z0-9-]+` per segment (ai-session-remote's slug rule).
fn slug(id: &str) -> String {
    id.chars()
        .map(|c| c.to_ascii_lowercase())
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect()
}

fn is_constraint_violation(e: &rusqlite::Error) -> bool {
    matches!(e, rusqlite::Error::SqliteFailure(f, _) if f.code == ErrorCode::ConstraintViolation)
}

/// Get the todo's conversation, creating it from its section's computer if missing.
/// Reopening a closed conversation resets its status to `unknown`.
pub(crate) fn open_conversation_db(conn: &Connection, todo_id: &str) -> Result<Conversation, OpenError> {
    let section: String = conn
        .query_row("SELECT section FROM todos WHERE id = ?1", params![todo_id], |r| r.get(0))
        .optional()?
        .ok_or(OpenError::TodoNotFound)?;

    if load_conversation(conn, todo_id)?.is_some() {
        conn.execute(
            "UPDATE conversations SET status = 'unknown', status_message = NULL, status_updated_at = datetime('now')
             WHERE todo_id = ?1 AND status = 'closed'",
            params![todo_id],
        )?;
        return load_conversation(conn, todo_id)?.ok_or(OpenError::Db(rusqlite::Error::QueryReturnedNoRows));
    }

    let mapping: Option<(String, String, String)> = conn
        .query_row(
            "SELECT computer_id, cwd, tool FROM section_computers WHERE section = ?1",
            params![section],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let Some((computer_id, cwd, tool)) = mapping else {
        return Err(OpenError::NoComputer(section));
    };

    let session_id = Uuid::new_v4().to_string();
    let full = slug(todo_id);
    let short: String = full.chars().take(8).collect();
    for name in [format!("ai/{tool}/todo-{short}"), format!("ai/{tool}/todo-{full}")] {
        let inserted = conn.execute(
            "INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, claude_session_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![todo_id, computer_id, cwd, tool, name, session_id],
        );
        match inserted {
            Ok(_) => break,
            // A concurrent open created it, or the short tmux name is taken: retry.
            Err(e) if is_constraint_violation(&e) => {
                if let Some(existing) = load_conversation(conn, todo_id)? {
                    return Ok(existing);
                }
            }
            Err(e) => return Err(e.into()),
        }
    }
    load_conversation(conn, todo_id)?.ok_or(OpenError::Db(rusqlite::Error::QueryReturnedNoRows))
}

/// Apply a hook status update. Returns the number of conversations updated (0 or 1).
pub(crate) fn set_status_db(conn: &Connection, req: &ConversationStatusRequest) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE conversations SET status = ?1, status_message = ?2, status_updated_at = datetime('now')
         WHERE claude_session_id = ?3",
        params![req.status.as_str(), req.message, req.claude_session_id],
    )
}

fn valid_text(s: &str) -> bool {
    !s.trim().is_empty()
}

fn valid_hostname(s: &str) -> bool {
    valid_text(s) && !s.chars().any(char::is_whitespace)
}

// ---------------------------------------------------------------------------
// Computers
// ---------------------------------------------------------------------------

pub async fn list_computers(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let mut stmt = match conn.prepare(&format!("SELECT {COMPUTER_COLS} FROM computers ORDER BY name")) {
        Ok(s) => s,
        Err(e) => return server_error(e),
    };
    let computers: Vec<Computer> = match stmt.query_map([], |r| computer_at(r, 0)) {
        Ok(rows) => rows.filter_map(Result::ok).collect(),
        Err(e) => return server_error(e),
    };
    HttpResponse::Ok().json(computers)
}

pub async fn create_computer(
    pool: web::Data<DbPool>,
    body: web::Json<CreateComputerRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    if !valid_text(&body.name) || !valid_hostname(&body.hostname) || !valid_text(&body.username) {
        return bad_request("name, hostname and username are required (hostname without spaces)");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let id = Uuid::new_v4().to_string();
    if let Err(e) = conn.execute(
        "INSERT INTO computers (id, name, hostname, port, username) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![id, body.name.trim(), body.hostname.trim(), body.port.unwrap_or(22), body.username.trim()],
    ) {
        return server_error(e);
    }
    broadcaster.send();
    match get_computer(&conn, &id) {
        Ok(Some(c)) => HttpResponse::Created().json(c),
        Ok(None) => not_found("Computer not found"),
        Err(e) => server_error(e),
    }
}

pub async fn update_computer(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateComputerRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    if body.name.as_deref().is_some_and(|s| !valid_text(s))
        || body.hostname.as_deref().is_some_and(|s| !valid_hostname(s))
        || body.username.as_deref().is_some_and(|s| !valid_text(s))
    {
        return bad_request("name, hostname and username cannot be empty (hostname without spaces)");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let affected = conn.execute(
        "UPDATE computers SET
            name = COALESCE(?1, name),
            hostname = COALESCE(?2, hostname),
            port = COALESCE(?3, port),
            username = COALESCE(?4, username),
            updated_at = datetime('now')
         WHERE id = ?5",
        params![
            body.name.as_deref().map(str::trim),
            body.hostname.as_deref().map(str::trim),
            body.port,
            body.username.as_deref().map(str::trim),
            id
        ],
    );
    match affected {
        Ok(0) => return not_found("Computer not found"),
        Ok(_) => {}
        Err(e) => return server_error(e),
    }
    broadcaster.send();
    match get_computer(&conn, &id) {
        Ok(Some(c)) => HttpResponse::Ok().json(c),
        Ok(None) => not_found("Computer not found"),
        Err(e) => server_error(e),
    }
}

pub async fn delete_computer(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute("DELETE FROM computers WHERE id = ?1", params![id]) {
        Ok(0) => not_found("Computer not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: id })
        }
        Err(e) if is_constraint_violation(&e) => {
            conflict("Computer is still assigned to a section or used by a conversation")
        }
        Err(e) => server_error(e),
    }
}

// ---------------------------------------------------------------------------
// Section → computer mapping
// ---------------------------------------------------------------------------

pub async fn list_section_computers(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let mut stmt = match conn.prepare(SECTION_COMPUTER_SELECT) {
        Ok(s) => s,
        Err(e) => return server_error(e),
    };
    let mut mappings: Vec<SectionComputer> = match stmt.query_map([], row_to_section_computer) {
        Ok(rows) => rows.filter_map(Result::ok).collect(),
        Err(e) => return server_error(e),
    };
    mappings.sort_by_key(|m| Section::all().iter().position(|s| *s == m.section));
    HttpResponse::Ok().json(mappings)
}

pub async fn set_section_computer(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetSectionComputerRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let Some(section) = Section::parse(&path.into_inner()) else {
        return bad_request("Invalid section");
    };
    let tool = body.tool.as_deref().unwrap_or("claude");
    if !SUPPORTED_TOOLS.contains(&tool) {
        return bad_request("Unsupported tool");
    }
    if !valid_text(&body.cwd) {
        return bad_request("cwd is required");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match get_computer(&conn, &body.computer_id) {
        Ok(Some(_)) => {}
        Ok(None) => return not_found("Computer not found"),
        Err(e) => return server_error(e),
    }
    if let Err(e) = conn.execute(
        "INSERT INTO section_computers (section, computer_id, cwd, tool) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(section) DO UPDATE SET computer_id = excluded.computer_id, cwd = excluded.cwd, tool = excluded.tool",
        params![section.as_str(), body.computer_id, body.cwd.trim(), tool],
    ) {
        return server_error(e);
    }
    broadcaster.send();
    match conn
        .query_row(&format!("{SECTION_COMPUTER_SELECT} WHERE s.section = ?1"), params![section.as_str()], row_to_section_computer)
    {
        Ok(m) => HttpResponse::Ok().json(m),
        Err(e) => server_error(e),
    }
}

pub async fn clear_section_computer(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let Some(section) = Section::parse(&path.into_inner()) else {
        return bad_request("Invalid section");
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute("DELETE FROM section_computers WHERE section = ?1", params![section.as_str()]) {
        Ok(0) => not_found("Section has no computer"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(serde_json::json!({"section": section}))
        }
        Err(e) => server_error(e),
    }
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

pub async fn list_conversations(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let mut stmt = match conn.prepare(&format!("{CONVERSATION_SELECT} ORDER BY c.created_at DESC")) {
        Ok(s) => s,
        Err(e) => return server_error(e),
    };
    let conversations: Vec<Conversation> = match stmt.query_map([], row_to_conversation) {
        Ok(rows) => rows.filter_map(Result::ok).collect(),
        Err(e) => return server_error(e),
    };
    HttpResponse::Ok().json(conversations)
}

pub async fn get_conversation(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match load_conversation(&conn, &path.into_inner()) {
        Ok(Some(c)) => HttpResponse::Ok().json(c),
        Ok(None) => not_found("Todo has no conversation"),
        Err(e) => server_error(e),
    }
}

pub async fn open_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match open_conversation_db(&conn, &path.into_inner()) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Todo not found"),
        Err(OpenError::NoComputer(section)) => conflict(format!("Section {section} has no computer assigned")),
        Err(OpenError::Db(e)) => server_error(e),
    }
}

pub async fn close_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let todo_id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute(
        "UPDATE conversations SET status = 'closed', status_message = NULL, status_updated_at = datetime('now')
         WHERE todo_id = ?1",
        params![todo_id],
    ) {
        Ok(0) => return not_found("Todo has no conversation"),
        Ok(_) => {}
        Err(e) => return server_error(e),
    }
    broadcaster.send();
    match load_conversation(&conn, &todo_id) {
        Ok(Some(c)) => HttpResponse::Ok().json(c),
        Ok(None) => not_found("Todo has no conversation"),
        Err(e) => server_error(e),
    }
}

pub async fn delete_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let todo_id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute("DELETE FROM conversations WHERE todo_id = ?1", params![todo_id]) {
        Ok(0) => not_found("Todo has no conversation"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: todo_id })
        }
        Err(e) => server_error(e),
    }
}

/// Claude Code hook endpoint. Unknown session ids (sessions that are not todo
/// conversations) get a 404, which hooks ignore.
pub async fn post_conversation_status(
    pool: web::Data<DbPool>,
    body: web::Json<ConversationStatusRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_status_db(&conn, &body) {
        Ok(0) => not_found("Unknown claude_session_id"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::NoContent().finish()
        }
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::init_pool;

    fn pool() -> DbPool {
        let path = format!("/tmp/todo-conv-test-{}.db", Uuid::new_v4());
        init_pool(&path)
    }

    fn seed(conn: &Connection) {
        conn.execute(
            "INSERT INTO computers (id, name, hostname, username) VALUES ('m1', 'Mac', 'mac.tailnet', 'me')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO section_computers (section, computer_id, cwd) VALUES ('I', 'm1', '~/programming')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title) VALUES ('0f3a9c21-aaaa-4bbb-8ccc-123456789abc', 'I', 'with mapping')",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO todos (id, section, title) VALUES ('t-p', 'P', 'no mapping')", []).unwrap();
    }

    const TODO: &str = "0f3a9c21-aaaa-4bbb-8ccc-123456789abc";

    #[test]
    fn open_creates_once_and_snapshots_mapping() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);

        let first = open_conversation_db(&conn, TODO).unwrap();
        assert_eq!(first.tmux_name, "ai/claude/todo-0f3a9c21");
        assert_eq!(first.cwd, "~/programming");
        assert_eq!(first.computer.id, "m1");
        assert_eq!(first.status, ConversationStatus::Unknown);
        assert!(Uuid::parse_str(&first.claude_session_id).is_ok());

        // Changing the section mapping does not move an existing conversation.
        conn.execute("UPDATE section_computers SET cwd = '/elsewhere' WHERE section = 'I'", []).unwrap();
        let again = open_conversation_db(&conn, TODO).unwrap();
        assert_eq!(again.claude_session_id, first.claude_session_id);
        assert_eq!(again.cwd, "~/programming");
    }

    #[test]
    fn open_errors_without_todo_or_mapping() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        assert!(matches!(open_conversation_db(&conn, "missing"), Err(OpenError::TodoNotFound)));
        assert!(matches!(open_conversation_db(&conn, "t-p"), Err(OpenError::NoComputer(s)) if s == "P"));
    }

    #[test]
    fn short_tmux_name_collision_falls_back_to_full_id() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute(
            "INSERT INTO todos (id, section, title) VALUES ('0f3a9c21-ffff-4bbb-8ccc-000000000000', 'I', 'same prefix')",
            [],
        )
        .unwrap();
        open_conversation_db(&conn, TODO).unwrap();
        let second = open_conversation_db(&conn, "0f3a9c21-ffff-4bbb-8ccc-000000000000").unwrap();
        assert_eq!(second.tmux_name, "ai/claude/todo-0f3a9c21-ffff-4bbb-8ccc-000000000000");
    }

    #[test]
    fn status_updates_and_reopen_resets_closed() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO).unwrap();

        let req = ConversationStatusRequest {
            claude_session_id: conv.claude_session_id.clone(),
            status: ConversationStatus::Waiting,
            message: Some("needs approval".into()),
        };
        assert_eq!(set_status_db(&conn, &req).unwrap(), 1);
        let unknown = ConversationStatusRequest { claude_session_id: "nope".into(), status: ConversationStatus::Busy, message: None };
        assert_eq!(set_status_db(&conn, &unknown).unwrap(), 0);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Waiting);

        conn.execute("UPDATE conversations SET status = 'closed' WHERE todo_id = ?1", params![TODO]).unwrap();
        let reopened = open_conversation_db(&conn, TODO).unwrap();
        assert_eq!(reopened.status, ConversationStatus::Unknown);
        assert_eq!(reopened.claude_session_id, conv.claude_session_id);
    }

    #[test]
    fn deleting_todo_cascades_and_computer_in_use_is_protected() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        open_conversation_db(&conn, TODO).unwrap();

        let err = conn.execute("DELETE FROM computers WHERE id = 'm1'", []).unwrap_err();
        assert!(is_constraint_violation(&err));

        // A fresh pooled connection must also enforce foreign keys.
        let other = pool.get().unwrap();
        other.execute("DELETE FROM todos WHERE id = ?1", params![TODO]).unwrap();
        assert!(load_conversation(&conn, TODO).unwrap().is_none());
    }
}
