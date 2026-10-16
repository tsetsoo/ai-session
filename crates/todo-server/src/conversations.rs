//! Computers, section → computer mapping, and per-todo AI conversations.
//!
//! The server only stores which conversation belongs to which todo. Clients
//! SSH to the computer themselves and run `ai-todo-open` with the stored
//! `tmux_name`, `cwd`, `session_id` and `tool`.
//!
//! A conversation is either started from a todo (Claude only: the server picks the
//! session id and the client runs `claude --session-id`) or linked to one that already
//! exists on the computer (Claude, Codex or Cursor, by the tool's own session id).

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, ErrorCode, OptionalExtension, Row, Transaction, TransactionBehavior};
use todo_shared::{
    Computer, Conversation, ConversationStatus, ConversationStatusRequest, CreateComputerRequest, DeleteResponse,
    LinkConversationRequest, Section, SectionComputer, SetSectionComputerRequest, TodoFromConversationRequest,
    TodoWithConversation, UpdateComputerRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::handlers::SELECT_COLS;
use crate::models::row_to_todo;

/// Tools a section or a linked conversation may use (matches `db::TOOLS_SQL`).
const SUPPORTED_TOOLS: &[&str] = &["claude", "codex", "cursor"];

/// Tools a todo can start a new conversation with. Only Claude accepts a session id
/// chosen up front (`claude --session-id`); the others can only be linked.
const STARTABLE_TOOLS: &[&str] = &["claude"];

const COMPUTER_COLS: &str = "id, name, hostname, port, username, created_at, updated_at";

/// Conversation columns (0..=8) followed by its computer (9..=15).
const CONVERSATION_SELECT: &str = "SELECT c.todo_id, c.cwd, c.tool, c.tmux_name, c.session_id, c.status,
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
    let session_id: String = row.get(4)?;
    Ok(Conversation {
        todo_id: row.get(0)?,
        cwd: row.get(1)?,
        tool: row.get(2)?,
        tmux_name: row.get(3)?,
        claude_session_id: session_id.clone(),
        session_id,
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
    /// The section's tool can't start a conversation with a preset id; link one instead.
    CannotStart(String),
    /// Both the short and the full tmux name are taken by other todos.
    NoTmuxName,
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
///
/// Runs in one IMMEDIATE transaction so it can't interleave with a concurrent
/// close, status update or todo delete.
pub(crate) fn open_conversation_db(conn: &Connection, todo_id: &str) -> Result<Conversation, OpenError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let conversation = open_conversation_in(&tx, todo_id)?;
    tx.commit()?;
    Ok(conversation)
}

fn open_conversation_in(conn: &Connection, todo_id: &str) -> Result<Conversation, OpenError> {
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
    if !STARTABLE_TOOLS.contains(&tool.as_str()) {
        return Err(OpenError::CannotStart(tool));
    }

    let session_id = Uuid::new_v4().to_string();
    if !insert_conversation(conn, todo_id, &computer_id, &cwd, &tool, &session_id)? {
        return Err(OpenError::NoTmuxName);
    }
    load_conversation(conn, todo_id)?.ok_or(OpenError::TodoNotFound)
}

/// Insert a conversation row named `ai/<tool>/todo-<first 8 of id>`, falling back to the
/// full todo id when another todo holds the short name. Returns `false` when both names
/// are taken. Callers check the todo, computer and session constraints beforehand.
fn insert_conversation(
    conn: &Connection,
    todo_id: &str,
    computer_id: &str,
    cwd: &str,
    tool: &str,
    session_id: &str,
) -> rusqlite::Result<bool> {
    let full = slug(todo_id);
    let short: String = full.chars().take(8).collect();
    for name in [format!("ai/{tool}/todo-{short}"), format!("ai/{tool}/todo-{full}")] {
        let inserted = conn.execute(
            "INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![todo_id, computer_id, cwd, tool, name, session_id],
        );
        match inserted {
            Ok(_) => return Ok(true),
            // The short tmux name is taken by another todo: try the full id.
            Err(e) if is_constraint_violation(&e) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(false)
}

#[derive(Debug)]
pub(crate) enum LinkError {
    TodoNotFound,
    ComputerNotFound,
    /// The todo already has a different conversation (pass `replace` to swap it).
    TodoHasConversation,
    /// That conversation is already linked to another todo (its id).
    SessionTaken(String),
    NoTmuxName,
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for LinkError {
    fn from(e: rusqlite::Error) -> Self {
        LinkError::Db(e)
    }
}

/// The todo a (tool, session) conversation is linked to, other than `except_todo`.
fn todo_linked_to(conn: &Connection, tool: &str, session_id: &str, except_todo: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT todo_id FROM conversations WHERE tool = ?1 AND session_id = ?2 AND todo_id != ?3",
        params![tool, session_id, except_todo],
        |r| r.get(0),
    )
    .optional()
}

/// Validated, trimmed fields of a link request.
pub(crate) struct LinkTarget<'a> {
    pub computer_id: &'a str,
    pub tool: &'a str,
    pub session_id: &'a str,
    pub cwd: &'a str,
}

/// Checks a link request's fields; returns the 400 message on failure.
fn link_target<'a>(computer_id: &'a str, tool: &'a str, session_id: &'a str, cwd: &'a str) -> Result<LinkTarget<'a>, &'static str> {
    let tool = tool.trim();
    if !SUPPORTED_TOOLS.contains(&tool) {
        return Err("Unsupported tool");
    }
    let session_id = session_id.trim();
    if session_id.is_empty() || session_id.chars().any(char::is_whitespace) {
        return Err("session_id is required (no spaces)");
    }
    if !valid_text(cwd) {
        return Err("cwd is required");
    }
    Ok(LinkTarget { computer_id: computer_id.trim(), tool, session_id, cwd: cwd.trim() })
}

/// Link an existing conversation to a todo, in one IMMEDIATE transaction.
/// Linking the conversation the todo already has is a no-op; a different one needs `replace`.
pub(crate) fn link_conversation_db(
    conn: &Connection,
    todo_id: &str,
    target: &LinkTarget,
    replace: bool,
) -> Result<Conversation, LinkError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let todo_exists = tx
        .query_row("SELECT 1 FROM todos WHERE id = ?1", params![todo_id], |_| Ok(()))
        .optional()?
        .is_some();
    if !todo_exists {
        return Err(LinkError::TodoNotFound);
    }
    if get_computer(&tx, target.computer_id)?.is_none() {
        return Err(LinkError::ComputerNotFound);
    }
    if let Some(other) = todo_linked_to(&tx, target.tool, target.session_id, todo_id)? {
        return Err(LinkError::SessionTaken(other));
    }
    if let Some(existing) = load_conversation(&tx, todo_id)? {
        let same = existing.tool == target.tool
            && existing.session_id == target.session_id
            && existing.computer.id == target.computer_id
            && existing.cwd == target.cwd;
        if same {
            return Ok(existing);
        }
        if !replace {
            return Err(LinkError::TodoHasConversation);
        }
        tx.execute("DELETE FROM conversations WHERE todo_id = ?1", params![todo_id])?;
    }
    if !insert_conversation(&tx, todo_id, target.computer_id, target.cwd, target.tool, target.session_id)? {
        return Err(LinkError::NoTmuxName);
    }
    let conversation = load_conversation(&tx, todo_id)?.ok_or(LinkError::TodoNotFound)?;
    tx.commit()?;
    Ok(conversation)
}

/// Create a todo linked to an existing conversation, in one IMMEDIATE transaction.
pub(crate) fn todo_from_conversation_db(
    conn: &Connection,
    section: Section,
    title: &str,
    target: &LinkTarget,
) -> Result<TodoWithConversation, LinkError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if get_computer(&tx, target.computer_id)?.is_none() {
        return Err(LinkError::ComputerNotFound);
    }
    if let Some(other) = todo_linked_to(&tx, target.tool, target.session_id, "")? {
        return Err(LinkError::SessionTaken(other));
    }
    let todo_id = Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO todos (id, section, title) VALUES (?1, ?2, ?3)",
        params![todo_id, section.as_str(), title],
    )?;
    if !insert_conversation(&tx, &todo_id, target.computer_id, target.cwd, target.tool, target.session_id)? {
        return Err(LinkError::NoTmuxName);
    }
    let todo = tx.query_row(&format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1"), params![todo_id], row_to_todo)?;
    let conversation = load_conversation(&tx, &todo_id)?.ok_or(LinkError::TodoNotFound)?;
    tx.commit()?;
    Ok(TodoWithConversation { todo, conversation })
}

fn link_error_response(e: LinkError) -> HttpResponse {
    match e {
        LinkError::TodoNotFound => not_found("Todo not found"),
        LinkError::ComputerNotFound => not_found("Computer not found"),
        LinkError::TodoHasConversation => {
            conflict("Todo already has a different conversation; pass ?replace=true to replace it")
        }
        LinkError::SessionTaken(other) => conflict(format!("That conversation is already linked to todo {other}")),
        LinkError::NoTmuxName => conflict("No free tmux session name for this todo"),
        LinkError::Db(e) => server_error(e),
    }
}

/// Apply a hook status update. Returns the number of conversations updated (0 or 1).
/// Closed conversations are left alone: a hook that lands after the user
/// closed the conversation must not make it look live again.
pub(crate) fn set_status_db(conn: &Connection, session_id: &str, req: &ConversationStatusRequest) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE conversations SET status = ?1, status_message = ?2, status_updated_at = datetime('now')
         WHERE session_id = ?3 AND status != 'closed'",
        params![req.status.as_str(), req.message, session_id],
    )
}

fn valid_text(s: &str) -> bool {
    !s.trim().is_empty()
}

fn valid_hostname(s: &str) -> bool {
    valid_text(s) && !s.chars().any(char::is_whitespace)
}

fn valid_port(p: Option<u16>) -> bool {
    p != Some(0)
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
        Ok(rows) => match rows.collect::<rusqlite::Result<_>>() {
            Ok(v) => v,
            Err(e) => return server_error(e),
        },
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
    if !valid_port(body.port) {
        return bad_request("port must be 1-65535");
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
    if !valid_port(body.port) {
        return bad_request("port must be 1-65535");
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
        Ok(rows) => match rows.collect::<rusqlite::Result<_>>() {
            Ok(v) => v,
            Err(e) => return server_error(e),
        },
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
        Ok(rows) => match rows.collect::<rusqlite::Result<_>>() {
            Ok(v) => v,
            Err(e) => return server_error(e),
        },
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
        Err(OpenError::CannotStart(tool)) => conflict(format!(
            "New {tool} conversations can't be started from a todo; link an existing one instead"
        )),
        Err(OpenError::NoTmuxName) => conflict("No free tmux session name for this todo"),
        Err(OpenError::Db(e)) => server_error(e),
    }
}

#[derive(serde::Deserialize)]
pub struct LinkQuery {
    #[serde(default)]
    pub replace: bool,
}

pub async fn link_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    query: web::Query<LinkQuery>,
    body: web::Json<LinkConversationRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let target = match link_target(&body.computer_id, &body.tool, &body.session_id, &body.cwd) {
        Ok(t) => t,
        Err(msg) => return bad_request(msg),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match link_conversation_db(&conn, &path.into_inner(), &target, query.replace) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(e) => link_error_response(e),
    }
}

pub async fn todo_from_conversation(
    pool: web::Data<DbPool>,
    body: web::Json<TodoFromConversationRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let title = body.title.trim();
    if title.is_empty() {
        return bad_request("Title cannot be empty");
    }
    let target = match link_target(&body.computer_id, &body.tool, &body.session_id, &body.cwd) {
        Ok(t) => t,
        Err(msg) => return bad_request(msg),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match todo_from_conversation_db(&conn, body.section, title, &target) {
        Ok(created) => {
            broadcaster.send();
            HttpResponse::Created().json(created)
        }
        Err(e) => link_error_response(e),
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

/// Status hook endpoint. Takes `session_id` or (older hooks) `claude_session_id`.
/// Unknown session ids (sessions that are not todo conversations) get a 404, which hooks ignore.
pub async fn post_conversation_status(
    pool: web::Data<DbPool>,
    body: web::Json<ConversationStatusRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    if body.status == ConversationStatus::Closed {
        return bad_request("Hooks cannot close a conversation; use POST /api/todos/{id}/conversation/close");
    }
    let Some(session_id) = body.session_id() else {
        return bad_request("session_id (or claude_session_id) is required");
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_status_db(&conn, session_id, &body) {
        Ok(0) => not_found("Unknown or closed session_id"),
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
            status: ConversationStatus::Waiting,
            message: Some("needs approval".into()),
            ..Default::default()
        };
        assert_eq!(set_status_db(&conn, &conv.session_id, &req).unwrap(), 1);
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, ..Default::default() };
        assert_eq!(set_status_db(&conn, "nope", &busy).unwrap(), 0);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Waiting);

        conn.execute("UPDATE conversations SET status = 'closed' WHERE todo_id = ?1", params![TODO]).unwrap();
        // A late hook must not make a closed conversation look live again.
        let late = ConversationStatusRequest { status: ConversationStatus::Idle, ..Default::default() };
        assert_eq!(set_status_db(&conn, &conv.session_id, &late).unwrap(), 0);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Closed);

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

    fn target<'a>(tool: &'a str, session_id: &'a str) -> LinkTarget<'a> {
        link_target("m1", tool, session_id, "~/Repositories/app").unwrap()
    }

    #[test]
    fn link_target_validates_fields() {
        assert!(link_target("m1", "vim", "abc", "~").is_err());
        assert!(link_target("m1", "codex", " ", "~").is_err());
        assert!(link_target("m1", "codex", "a b", "~").is_err());
        assert!(link_target("m1", "codex", "abc", " ").is_err());
        let t = link_target(" m1 ", " codex ", " abc ", " ~/x ").unwrap();
        assert_eq!((t.computer_id, t.tool, t.session_id, t.cwd), ("m1", "codex", "abc", "~/x"));
    }

    #[test]
    fn link_existing_codex_conversation() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = link_conversation_db(&conn, TODO, &target("codex", "019f8b4e-ff53"), false).unwrap();
        assert_eq!(conv.tool, "codex");
        assert_eq!(conv.session_id, "019f8b4e-ff53");
        assert_eq!(conv.claude_session_id, conv.session_id);
        assert_eq!(conv.tmux_name, "ai/codex/todo-0f3a9c21");
        assert_eq!(conv.cwd, "~/Repositories/app");

        // Linking the same conversation again is a no-op; opening keeps it.
        let again = link_conversation_db(&conn, TODO, &target("codex", "019f8b4e-ff53"), false).unwrap();
        assert_eq!(again.session_id, conv.session_id);
        assert_eq!(open_conversation_db(&conn, TODO).unwrap().tool, "codex");
    }

    #[test]
    fn link_refuses_a_second_conversation_unless_replace() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let started = open_conversation_db(&conn, TODO).unwrap();
        assert!(matches!(
            link_conversation_db(&conn, TODO, &target("claude", "other-id"), false),
            Err(LinkError::TodoHasConversation)
        ));
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().session_id, started.session_id);

        let replaced = link_conversation_db(&conn, TODO, &target("claude", "other-id"), true).unwrap();
        assert_eq!(replaced.session_id, "other-id");
        assert_eq!(replaced.tmux_name, "ai/claude/todo-0f3a9c21");
    }

    #[test]
    fn a_conversation_links_to_one_todo_only() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO todos (id, section, title) VALUES ('t-2', 'I', 'second')", []).unwrap();
        link_conversation_db(&conn, TODO, &target("claude", "shared"), false).unwrap();
        assert!(matches!(
            link_conversation_db(&conn, "t-2", &target("claude", "shared"), true),
            Err(LinkError::SessionTaken(t)) if t == TODO
        ));
        // Same id under another tool is a different conversation.
        assert!(link_conversation_db(&conn, "t-2", &target("codex", "shared"), false).is_ok());
        assert!(matches!(
            todo_from_conversation_db(&conn, Section::I, "dup", &target("claude", "shared")),
            Err(LinkError::SessionTaken(_))
        ));
    }

    #[test]
    fn link_errors_for_missing_todo_or_computer() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        assert!(matches!(
            link_conversation_db(&conn, "missing", &target("claude", "x"), false),
            Err(LinkError::TodoNotFound)
        ));
        let nowhere = link_target("nope", "claude", "x", "~").unwrap();
        assert!(matches!(link_conversation_db(&conn, TODO, &nowhere, false), Err(LinkError::ComputerNotFound)));
        assert!(matches!(
            todo_from_conversation_db(&conn, Section::P, "t", &nowhere),
            Err(LinkError::ComputerNotFound)
        ));
        let todos: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(todos, 2, "a failed from-conversation must not leave a todo behind");
    }

    #[test]
    fn todo_from_conversation_creates_both() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let created = todo_from_conversation_db(&conn, Section::Sp, "Review PR 630", &target("claude", "49e9880f")).unwrap();
        assert_eq!(created.todo.section, Section::Sp);
        assert_eq!(created.todo.title, "Review PR 630");
        assert_eq!(created.todo.conversation_status, Some(ConversationStatus::Unknown));
        assert_eq!(created.conversation.todo_id, created.todo.id);
        assert_eq!(created.conversation.session_id, "49e9880f");
        assert!(created.conversation.tmux_name.starts_with("ai/claude/todo-"));
    }

    #[test]
    fn sections_mapped_to_codex_cannot_start_new_conversations() {
        let pool = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE section_computers SET tool = 'codex' WHERE section = 'I'", []).unwrap();
        assert!(matches!(open_conversation_db(&conn, TODO), Err(OpenError::CannotStart(t)) if t == "codex"));
        // A linked one still opens.
        link_conversation_db(&conn, TODO, &target("codex", "abc"), false).unwrap();
        assert_eq!(open_conversation_db(&conn, TODO).unwrap().session_id, "abc");
    }

    #[test]
    fn status_request_accepts_either_key() {
        let new: ConversationStatusRequest = serde_json::from_str(r#"{"session_id":"a","status":"busy"}"#).unwrap();
        assert_eq!(new.session_id(), Some("a"));
        let old: ConversationStatusRequest = serde_json::from_str(r#"{"claude_session_id":"b","status":"idle"}"#).unwrap();
        assert_eq!(old.session_id(), Some("b"));
        let both: ConversationStatusRequest =
            serde_json::from_str(r#"{"session_id":"a","claude_session_id":"b","status":"idle"}"#).unwrap();
        assert_eq!(both.session_id(), Some("a"));
        let none: ConversationStatusRequest = serde_json::from_str(r#"{"session_id":" ","status":"idle"}"#).unwrap();
        assert_eq!(none.session_id(), None);
    }
}
