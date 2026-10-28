//! Computers, section → computer mapping, and per-todo AI conversations.
//!
//! The server only stores which conversation belongs to which todo. Clients
//! SSH to the computer themselves and run `ai-todo-open` with the stored
//! `tmux_name`, `cwd`, `session_id` and `tool`.
//!
//! A conversation is started from a todo for Claude, Codex, or Cursor. Claude gets a
//! server-minted session id. Codex and Cursor start without one; the client stores the
//! id the tool assigns. An existing conversation can also be linked by its session id.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, ErrorCode, OptionalExtension, Row, Transaction, TransactionBehavior};
use todo_shared::{
    Computer, Conversation, ConversationStatus, ConversationStatusRequest, CreateComputerRequest, DeleteResponse,
    DuplicateConversationRequest, Importance, LinkConversationRequest, OpenConversationRequest, Section, SectionComputer,
    ReportConversationMcpRequest, SetConversationMcpRequest, SetConversationSessionRequest, SetSectionComputerRequest,
    TodoFromConversationRequest, TodoWithConversation, UpdateComputerRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::handlers::{insert_todo, SELECT_COLS};
use crate::models::row_to_todo;
use crate::projects::project_for;
use crate::push::{PushNotifier, Transition};

/// Tools a conversation may use (matches `db::TOOLS_SQL`).
pub(crate) const SUPPORTED_TOOLS: &[&str] = &["claude", "codex", "cursor"];

pub(crate) const COMPUTER_COLS: &str = "id, name, hostname, port, username, created_at, updated_at, mcp_default";

/// Conversation columns (0..=11), its computer (12..=19), then whether its session is known
/// and that session's project (20, 21).
const CONVERSATION_SELECT: &str = "SELECT c.id, c.todo_id, c.cwd, c.tool, c.tmux_name, c.session_id, c.status,
        c.status_message, c.status_updated_at, c.created_at, c.label, c.mcp_servers,
        m.id, m.name, m.hostname, m.port, m.username, m.created_at, m.updated_at, m.mcp_default,
        s.session_id IS NOT NULL, s.project_id, c.status_revision, c.reviewed
     FROM conversations c JOIN computers m ON m.id = c.computer_id
     LEFT JOIN sessions s ON s.tool = c.tool AND s.session_id = c.session_id";

/// Section mapping columns (0) followed by its computer (1..=8).
const SECTION_COMPUTER_SELECT: &str = "SELECT s.section,
        m.id, m.name, m.hostname, m.port, m.username, m.created_at, m.updated_at, m.mcp_default
     FROM section_computers s JOIN computers m ON m.id = s.computer_id";

pub(crate) fn error(status: actix_web::http::StatusCode, msg: impl ToString) -> HttpResponse {
    HttpResponse::build(status).json(serde_json::json!({"error": msg.to_string()}))
}

pub(crate) fn server_error(e: impl ToString) -> HttpResponse {
    error(actix_web::http::StatusCode::INTERNAL_SERVER_ERROR, e)
}

pub(crate) fn bad_request(msg: &str) -> HttpResponse {
    error(actix_web::http::StatusCode::BAD_REQUEST, msg)
}

pub(crate) fn not_found(msg: &str) -> HttpResponse {
    error(actix_web::http::StatusCode::NOT_FOUND, msg)
}

pub(crate) fn conflict(msg: impl ToString) -> HttpResponse {
    error(actix_web::http::StatusCode::CONFLICT, msg)
}

/// Most MCP servers one selection may hold.
const MAX_MCP_SERVERS: usize = 32;

/// A selection of MCP server names: each `[A-Za-z0-9._-]{1,64}` (a file name stem under
/// `~/.ai-remote/mcp/`, so never `.` or `..`), at most 32, duplicates dropped in first-seen order.
pub(crate) fn validate_mcp_names(names: Vec<String>) -> Result<Vec<String>, String> {
    const INVALID: &str = "invalid MCP server name";
    if names.len() > MAX_MCP_SERVERS {
        return Err(INVALID.into());
    }
    let mut kept: Vec<String> = Vec::with_capacity(names.len());
    for name in names {
        let valid = (1..=64).contains(&name.len())
            && name != "."
            && name != ".."
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
        if !valid {
            return Err(INVALID.into());
        }
        if !kept.contains(&name) {
            kept.push(name);
        }
    }
    Ok(kept)
}

/// Validate an optional selection (`None` stays `None`).
pub(crate) fn validate_mcp_option(names: Option<Vec<String>>) -> Result<Option<Vec<String>>, String> {
    names.map(validate_mcp_names).transpose()
}

/// A selection as stored: JSON text, NULL for none.
pub(crate) fn mcp_to_sql(names: Option<&[String]>) -> Option<String> {
    names.map(|n| serde_json::to_string(n).expect("a list of strings serializes"))
}

/// A stored selection; text that isn't a JSON list of strings reads as none.
pub(crate) fn mcp_from_sql(row: &Row, idx: usize) -> rusqlite::Result<Option<Vec<String>>> {
    let text: Option<String> = row.get(idx)?;
    Ok(text.and_then(|t| serde_json::from_str(&t).ok()))
}

pub(crate) fn computer_at(row: &Row, start: usize) -> rusqlite::Result<Computer> {
    Ok(Computer {
        id: row.get(start)?,
        name: row.get(start + 1)?,
        hostname: row.get(start + 2)?,
        port: row.get(start + 3)?,
        username: row.get(start + 4)?,
        created_at: row.get(start + 5)?,
        updated_at: row.get(start + 6)?,
        mcp_default: mcp_from_sql(row, start + 7)?,
    })
}

/// A conversation row and whether its session is known (`project_id` is then the session's).
fn row_to_conversation(row: &Row) -> rusqlite::Result<(Conversation, bool)> {
    let status: String = row.get(6)?;
    let tool: String = row.get(3)?;
    let session_id: Option<String> = row.get(5)?;
    let session_id = session_id.unwrap_or_default();
    let conversation = Conversation {
        id: row.get(0)?,
        todo_id: row.get(1)?,
        cwd: row.get(2)?,
        tmux_name: row.get(4)?,
        // Older apps and the 3-argument ai-todo-open treat this as a Claude id, so it is
        // only set for Claude conversations.
        claude_session_id: (tool == "claude").then(|| session_id.clone()),
        tool,
        session_id,
        status: ConversationStatus::parse(&status).unwrap_or(ConversationStatus::Unknown),
        status_message: row.get(7)?,
        status_updated_at: row.get(8)?,
        status_revision: row.get(22)?,
        reviewed: row.get(23)?,
        created_at: row.get(9)?,
        label: row.get(10)?,
        mcp_servers: mcp_from_sql(row, 11)?,
        computer: computer_at(row, 12)?,
        project_id: row.get(21)?,
    };
    Ok((conversation, row.get(20)?))
}

/// A conversation whose session isn't known yet gets its project matched on the fly.
fn with_project(conn: &Connection, (mut conversation, session_known): (Conversation, bool)) -> rusqlite::Result<Conversation> {
    if !session_known {
        conversation.project_id = project_for(conn, &conversation.computer.id, &conversation.cwd)?;
    }
    Ok(conversation)
}

fn row_to_section_computer(row: &Row) -> rusqlite::Result<SectionComputer> {
    let section: String = row.get(0)?;
    Ok(SectionComputer {
        section: Section::parse(&section).unwrap_or(Section::P),
        computer: computer_at(row, 1)?,
    })
}

pub(crate) fn get_computer(conn: &Connection, id: &str) -> rusqlite::Result<Option<Computer>> {
    conn.query_row(&format!("SELECT {COMPUTER_COLS} FROM computers WHERE id = ?1"), params![id], |r| computer_at(r, 0))
        .optional()
}

pub(crate) fn most_urgent(conversations: &[Conversation]) -> Option<&Conversation> {
    conversations.iter().min_by(|left, right| {
        urgency(left).cmp(&urgency(right)).then_with(|| {
            let left_at = left.status_updated_at.as_deref().unwrap_or("");
            let right_at = right.status_updated_at.as_deref().unwrap_or("");
            right_at.cmp(left_at)
        }).then(right.created_at.cmp(&left.created_at))
        .then(left.id.cmp(&right.id))
    })
}

fn urgency(conversation: &Conversation) -> u8 {
    match conversation.status {
        ConversationStatus::Waiting => 0,
        ConversationStatus::Busy => 1,
        ConversationStatus::Idle if !conversation.reviewed => 2,
        ConversationStatus::Idle | ConversationStatus::Unknown => 3,
        ConversationStatus::Closed => 4,
    }
}

pub(crate) fn load_conversation(conn: &Connection, todo_id: &str) -> rusqlite::Result<Option<Conversation>> {
    let mut stmt = conn.prepare(&format!("{CONVERSATION_SELECT} WHERE c.todo_id = ?1"))?;
    let rows = stmt.query_map(params![todo_id], row_to_conversation)?.collect::<rusqlite::Result<Vec<_>>>()?;
    drop(stmt);
    let loaded = rows.into_iter().map(|row| with_project(conn, row)).collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(most_urgent(&loaded).cloned())
}

#[derive(Debug)]
pub(crate) enum OpenError {
    TodoNotFound,
    NoComputer(String),
    UnsupportedTool,
    NoProject,
    BadRequest(&'static str),
    NoTmuxName,
    Conflict(&'static str),
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

pub(crate) fn is_constraint_violation(e: &rusqlite::Error) -> bool {
    matches!(e, rusqlite::Error::SqliteFailure(f, _) if f.code == ErrorCode::ConstraintViolation)
}

/// Get the todo's conversation, creating it from its section's computer if missing.
/// Reopening a closed conversation resets its status to `unknown`.
///
/// Runs in one IMMEDIATE transaction so it can't interleave with a concurrent
/// close, status update or todo delete.
///
/// `mcp_servers` (already validated) is stored only when this call creates the row.
pub(crate) fn open_conversation_db(
    conn: &Connection,
    todo_id: &str,
    tool: &str,
    mcp_servers: Option<&[String]>,
) -> Result<Conversation, OpenError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let conversation = open_conversation_in(&tx, todo_id, tool, mcp_servers)?;
    tx.commit()?;
    Ok(conversation)
}

fn open_conversation_in(
    conn: &Connection,
    todo_id: &str,
    tool: &str,
    mcp_servers: Option<&[String]>,
) -> Result<Conversation, OpenError> {
    let tool = tool.trim();
    if !SUPPORTED_TOOLS.contains(&tool) {
        return Err(OpenError::UnsupportedTool);
    }
    let section: String = conn
        .query_row("SELECT section FROM todos WHERE id = ?1", params![todo_id], |r| r.get(0))
        .optional()?
        .ok_or(OpenError::TodoNotFound)?;

    if let Some(existing) = load_conversation(conn, todo_id)? {
        if existing.status == ConversationStatus::Closed {
            conn.execute(
                "UPDATE conversations SET status = 'unknown', status_message = NULL, status_updated_at = datetime('now')
                 WHERE id = ?1",
                params![existing.id],
            )?;
            return load_conversation(conn, todo_id)?.ok_or(OpenError::Db(rusqlite::Error::QueryReturnedNoRows));
        }
        return Ok(existing);
    }

    let computer_id: Option<String> = conn
        .query_row("SELECT computer_id FROM section_computers WHERE section = ?1", params![section], |r| r.get(0))
        .optional()?;
    let Some(computer_id) = computer_id else {
        return Err(OpenError::NoComputer(section));
    };
    let cwd: String = conn
        .query_row(
            "SELECT p.folder FROM todos t JOIN projects p ON p.id = t.project_id WHERE t.id = ?1",
            params![todo_id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or(OpenError::NoProject)?;
    let session_id = (tool == "claude").then(|| Uuid::new_v4().to_string());
    if insert_conversation(conn, todo_id, &computer_id, &cwd, tool, session_id.as_deref(), false, None, mcp_servers)?.is_none() {
        return Err(OpenError::NoTmuxName);
    }
    load_conversation(conn, todo_id)?.ok_or(OpenError::TodoNotFound)
}

pub(crate) fn duplicate_conversation_db(
    conn: &Connection,
    todo_id: &str,
    source_id: &str,
    tool: &str,
    label: &str,
) -> Result<Conversation, OpenError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let created = duplicate_in(&tx, todo_id, source_id, tool, label)?;
    tx.commit()?;
    Ok(created)
}

fn duplicate_in(conn: &Connection, todo_id: &str, source_id: &str, tool: &str, label: &str) -> Result<Conversation, OpenError> {
    let label = label.trim();
    if label.is_empty() {
        return Err(OpenError::BadRequest("label is required"));
    }
    let tool = tool.trim();
    if !SUPPORTED_TOOLS.contains(&tool) {
        return Err(OpenError::UnsupportedTool);
    }
    let Some(source) = load_conversation_by_id(conn, source_id)? else {
        return Err(OpenError::TodoNotFound);
    };
    if source.todo_id != todo_id {
        return Err(OpenError::TodoNotFound);
    }
    let session_id = (tool == "claude").then(|| Uuid::new_v4().to_string());
    let Some(id) = insert_conversation(
        conn,
        todo_id,
        &source.computer.id,
        &source.cwd,
        tool,
        session_id.as_deref(),
        true,
        Some(label),
        // Cursor has no MCP selection.
        if tool == "cursor" { None } else { source.mcp_servers.as_deref() },
    )?
    else {
        return Err(OpenError::NoTmuxName);
    };
    load_conversation_by_id(conn, &id)?.ok_or(OpenError::TodoNotFound)
}

pub(crate) fn set_conversation_session_db(
    conn: &Connection,
    todo_id: &str,
    session_id: &str,
) -> Result<Conversation, OpenError> {
    let id = require_single(conn, todo_id)?;
    set_session_on(conn, &id, session_id)
}

fn set_session_on(conn: &Connection, conversation_id: &str, session_id: &str) -> Result<Conversation, OpenError> {
    let session_id = session_id.trim();
    if session_id.is_empty() {
        return Err(OpenError::BadRequest("session_id is required"));
    }
    let updated = conn.execute(
        "UPDATE conversations SET session_id = ?1 WHERE id = ?2",
        params![session_id, conversation_id],
    )?;
    if updated == 0 {
        return Err(OpenError::TodoNotFound);
    }
    load_conversation_by_id(conn, conversation_id)?.ok_or(OpenError::TodoNotFound)
}

/// The conversation id when the todo has exactly one. More than one is a conflict:
/// the caller has to name which conversation.
fn require_single(conn: &Connection, todo_id: &str) -> Result<String, OpenError> {
    let mut stmt = conn.prepare("SELECT id FROM conversations WHERE todo_id = ?1")?;
    let ids = stmt.query_map(params![todo_id], |row| row.get(0))?.collect::<rusqlite::Result<Vec<String>>>()?;
    match ids.len() {
        0 => Err(OpenError::TodoNotFound),
        1 => Ok(ids.into_iter().next().expect("len is 1")),
        _ => Err(OpenError::Conflict("conversation_id required")),
    }
}

pub(crate) fn load_conversation_by_id(conn: &Connection, id: &str) -> rusqlite::Result<Option<Conversation>> {
    let mut stmt = conn.prepare(&format!("{CONVERSATION_SELECT} WHERE c.id = ?1"))?;
    let row = stmt.query_row(params![id], row_to_conversation).optional()?;
    drop(stmt);
    row.map(|row| with_project(conn, row)).transpose()
}

fn tmux_name_taken(conn: &Connection, name: &str) -> rusqlite::Result<bool> {
    Ok(conn
        .query_row("SELECT 1 FROM conversations WHERE tmux_name = ?1", params![name], |_| Ok(()))
        .optional()?
        .is_some())
}

/// A free tmux session name for a todo's conversation.
///
/// The first conversation is `ai/<tool>/todo-<first 8 of todo id>`, or the full todo id
/// when another todo holds the short one. A conversation that *replaces* the todo's
/// previous one also carries its own session id (`…-<first 8 of session id>`): the old
/// conversation's tmux session may still be running under the old name, and
/// `ai-todo-open` attaches to whatever runs under the name it is given.
fn pick_tmux_name(
    conn: &Connection,
    tool: &str,
    todo_id: &str,
    session_id: &str,
    replacing: bool,
) -> rusqlite::Result<Option<String>> {
    let full = slug(todo_id);
    let short: String = full.chars().take(8).collect();
    let session: String = slug(session_id).chars().take(8).collect();
    let (first, second) = if replacing {
        (format!("ai/{tool}/todo-{short}-{session}"), format!("ai/{tool}/todo-{full}-{session}"))
    } else {
        (format!("ai/{tool}/todo-{short}"), format!("ai/{tool}/todo-{full}"))
    };
    let numbered: Vec<String> = (2..=50).map(|n| format!("{second}-r{n}")).collect();
    for name in [first, second].into_iter().chain(numbered) {
        if !tmux_name_taken(conn, &name)? {
            return Ok(Some(name));
        }
    }
    Ok(None)
}

/// Insert a conversation row under a free tmux name (see `pick_tmux_name`). Returns
/// `false` when no name is free. Any other constraint error is returned as is, for the
/// caller to report: names are checked first, so it is never mistaken for a name clash.
#[allow(clippy::too_many_arguments)]
fn insert_conversation(
    conn: &Connection,
    todo_id: &str,
    computer_id: &str,
    cwd: &str,
    tool: &str,
    session_id: Option<&str>,
    replacing: bool,
    label: Option<&str>,
    mcp_servers: Option<&[String]>,
) -> rusqlite::Result<Option<String>> {
    let Some(name) = pick_tmux_name(conn, tool, todo_id, session_id.unwrap_or(""), replacing)? else {
        return Ok(None);
    };
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, label, mcp_servers)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![id, todo_id, computer_id, cwd, tool, name, session_id, label, mcp_to_sql(mcp_servers)],
    )?;
    Ok(Some(id))
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
    /// The todo has more than one conversation, so a todo-scoped replace cannot pick one.
    Ambiguous,
    ProjectRequired,
    ProjectNotFound,
    SectionMismatch,
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

/// Turn a failed conversation insert into the most specific link error: the session is
/// linked elsewhere (409), the todo or computer is gone (404), or a database error (500).
fn link_insert_error(conn: &Connection, e: rusqlite::Error, todo_id: &str, target: &LinkTarget) -> LinkError {
    if !is_constraint_violation(&e) {
        return LinkError::Db(e);
    }
    match todo_linked_to(conn, target.tool, target.session_id, todo_id) {
        Ok(Some(other)) => return LinkError::SessionTaken(other),
        Ok(None) => {}
        Err(e) => return LinkError::Db(e),
    }
    match conn.query_row("SELECT 1 FROM todos WHERE id = ?1", params![todo_id], |_| Ok(())).optional() {
        Ok(None) => return LinkError::TodoNotFound,
        Ok(Some(())) => {}
        Err(e) => return LinkError::Db(e),
    }
    match get_computer(conn, target.computer_id) {
        Ok(None) => LinkError::ComputerNotFound,
        Ok(Some(_)) => LinkError::Db(e),
        Err(e) => LinkError::Db(e),
    }
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
    let mut replacing = false;
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
        let count: i64 = tx.query_row("SELECT COUNT(*) FROM conversations WHERE todo_id = ?1", params![todo_id], |r| r.get(0))?;
        if count > 1 {
            return Err(LinkError::Ambiguous);
        }
        tx.execute("DELETE FROM conversations WHERE id = ?1", params![existing.id])?;
        replacing = true;
    }
    match insert_conversation(&tx, todo_id, target.computer_id, target.cwd, target.tool, Some(target.session_id), replacing, None, None) {
        Ok(Some(_)) => {}
        Ok(None) => return Err(LinkError::NoTmuxName),
        Err(e) => return Err(link_insert_error(&tx, e, todo_id, target)),
    }
    let conversation = load_conversation(&tx, todo_id)?.ok_or(LinkError::TodoNotFound)?;
    tx.commit()?;
    Ok(conversation)
}

/// The new todo's fields for `todo_from_conversation_db`.
pub(crate) struct NewTodo<'a> {
    pub section: Section,
    pub title: &'a str,
    pub project_id: &'a str,
    pub importance: Option<Importance>,
    pub due_date: Option<&'a str>,
}

/// Create a todo linked to an existing conversation, in one IMMEDIATE transaction.
pub(crate) fn todo_from_conversation_db(
    conn: &Connection,
    new: &NewTodo,
    target: &LinkTarget,
) -> Result<TodoWithConversation, LinkError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if get_computer(&tx, target.computer_id)?.is_none() {
        return Err(LinkError::ComputerNotFound);
    }
    if let Some(other) = todo_linked_to(&tx, target.tool, target.session_id, "")? {
        return Err(LinkError::SessionTaken(other));
    }
    let project_id = new.project_id.trim();
    if project_id.is_empty() {
        return Err(LinkError::ProjectRequired);
    }
    let project_section: Option<String> = tx
        .query_row("SELECT section FROM projects WHERE id = ?1", params![project_id], |r| r.get(0))
        .optional()?;
    let Some(project_section) = project_section else {
        return Err(LinkError::ProjectNotFound);
    };
    if project_section != new.section.as_str() {
        return Err(LinkError::SectionMismatch);
    }
    let todo_id = insert_todo(&tx, new.section, new.title, new.importance, new.due_date, Some(project_id))?;
    match insert_conversation(&tx, &todo_id, target.computer_id, target.cwd, target.tool, Some(target.session_id), false, None, None) {
        Ok(Some(_)) => {}
        Ok(None) => return Err(LinkError::NoTmuxName),
        Err(e) => return Err(link_insert_error(&tx, e, &todo_id, target)),
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
        LinkError::Ambiguous => conflict("conversation_id required"),
        LinkError::ProjectRequired => bad_request("project_id is required"),
        LinkError::ProjectNotFound => not_found("Project not found"),
        LinkError::SectionMismatch => bad_request("section does not match project"),
        LinkError::Db(e) => server_error(e),
    }
}

/// A status post that matched a conversation: whose it is and what it was before.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StatusChange {
    pub todo_id: String,
    pub old: ConversationStatus,
}

/// Apply a hook status update to the `(tool, session_id)` conversation (UNIQUE, so at most
/// one). `None` when there is no such conversation or it is closed: a hook that lands after
/// the user closed the conversation must not make it look live again.
pub(crate) fn set_status_db(
    conn: &Connection,
    tool: &str,
    session_id: &str,
    req: &ConversationStatusRequest,
) -> rusqlite::Result<Option<StatusChange>> {
    // IMMEDIATE: take the write lock before reading, so a concurrent writer makes this wait
    // (busy timeout) instead of failing the update on a stale read snapshot.
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let current: Option<(String, String)> = tx
        .query_row(
            "SELECT todo_id, status FROM conversations WHERE tool = ?1 AND session_id = ?2 AND status != 'closed'",
            params![tool, session_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let Some((todo_id, old)) = current else { return Ok(None) };
    tx.execute(
        "UPDATE conversations SET
         status_revision = status_revision + CASE WHEN status != ?1 THEN 1 ELSE 0 END,
         reviewed = CASE WHEN status != ?1 THEN 0 ELSE reviewed END,
         status_updated_at = CASE WHEN status != ?1 OR status_message IS NOT ?2 THEN datetime('now') ELSE status_updated_at END,
         status = ?1, status_message = ?2
         WHERE tool = ?3 AND session_id = ?4 AND status != 'closed'",
        params![req.status.as_str(), req.message, tool, session_id],
    )?;
    tx.commit()?;
    Ok(Some(StatusChange { todo_id, old: ConversationStatus::parse(&old).unwrap_or(ConversationStatus::Unknown) }))
}

pub(crate) fn valid_text(s: &str) -> bool {
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
    let mcp_default = match body.mcp_default.clone().map(validate_mcp_option).transpose() {
        Ok(names) => names,
        Err(msg) => return bad_request(&msg),
    };
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
            mcp_default = CASE WHEN ?5 THEN ?6 ELSE mcp_default END,
            updated_at = datetime('now')
         WHERE id = ?7",
        params![
            body.name.as_deref().map(str::trim),
            body.hostname.as_deref().map(str::trim),
            body.port,
            body.username.as_deref().map(str::trim),
            mcp_default.is_some(),
            mcp_default.as_ref().and_then(|d| mcp_to_sql(d.as_deref())),
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
            conflict("Computer is still assigned to a section or used by a conversation or project")
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
    if !valid_text(&body.computer_id) {
        return bad_request("computer_id is required");
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
        "INSERT INTO section_computers (section, computer_id) VALUES (?1, ?2)
         ON CONFLICT(section) DO UPDATE SET computer_id = excluded.computer_id",
        params![section.as_str(), body.computer_id],
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
    let projects: i64 = match conn.query_row(
        "SELECT COUNT(*) FROM projects WHERE section = ?1",
        params![section.as_str()],
        |r| r.get(0),
    ) {
        Ok(n) => n,
        Err(e) => return server_error(e),
    };
    if projects > 0 {
        return conflict(format!("Section {section} still has projects"));
    }
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

#[derive(serde::Deserialize)]
pub struct ConversationsQuery {
    pub show: Option<String>,
}

/// Every conversation, newest first. By default it leaves out the conversations of
/// archived todos, the same todos `GET /api/todos` leaves out, so a list never shows
/// a conversation whose todo it can't name. `?show=all` includes them.
pub async fn list_conversations(pool: web::Data<DbPool>, query: web::Query<ConversationsQuery>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let filter = match query.show.as_deref() {
        None => {
            "WHERE NOT EXISTS (SELECT 1 FROM todos t WHERE t.id = c.todo_id
                 AND t.completed = 1 AND t.completed_at IS NOT NULL AND t.completed_at < datetime('now', '-1 day'))"
        }
        Some("all") => "",
        Some(_) => return error(actix_web::http::StatusCode::BAD_REQUEST, "Invalid show"),
    };
    let mut stmt = match conn.prepare(&format!("{CONVERSATION_SELECT} {filter} ORDER BY c.created_at DESC")) {
        Ok(s) => s,
        Err(e) => return server_error(e),
    };
    let rows: Vec<(Conversation, bool)> = match stmt.query_map([], row_to_conversation) {
        Ok(rows) => match rows.collect::<rusqlite::Result<_>>() {
            Ok(v) => v,
            Err(e) => return server_error(e),
        },
        Err(e) => return server_error(e),
    };
    let conversations: Vec<Conversation> = match rows.into_iter().map(|row| with_project(&conn, row)).collect() {
        Ok(v) => v,
        Err(e) => return server_error(e),
    };
    HttpResponse::Ok().json(conversations)
}

pub async fn list_todo_conversations(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let todo_id = path.into_inner();
    let mut stmt = match conn.prepare(&format!("{CONVERSATION_SELECT} WHERE c.todo_id = ?1 ORDER BY c.created_at")) {
        Ok(s) => s,
        Err(e) => return server_error(e),
    };
    let rows: Vec<(Conversation, bool)> = match stmt.query_map(params![todo_id], row_to_conversation) {
        Ok(rows) => match rows.collect::<rusqlite::Result<_>>() {
            Ok(v) => v,
            Err(e) => return server_error(e),
        },
        Err(e) => return server_error(e),
    };
    let conversations: Vec<Conversation> = match rows.into_iter().map(|row| with_project(&conn, row)).collect() {
        Ok(v) => v,
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
    body: web::Json<OpenConversationRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let mcp_servers = match validate_mcp_option(body.mcp_servers.clone()) {
        Ok(names) => names,
        Err(msg) => return bad_request(&msg),
    };
    match open_conversation_db(&conn, &path.into_inner(), &body.tool, mcp_servers.as_deref()) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Todo not found"),
        Err(OpenError::NoComputer(section)) => conflict(format!("Section {section} has no computer assigned")),
        Err(OpenError::UnsupportedTool) => bad_request("Unsupported tool"),
        Err(OpenError::NoProject) => bad_request("project_id is required"),
        Err(OpenError::BadRequest(msg)) => bad_request(msg),
        Err(OpenError::NoTmuxName) => conflict("No free tmux session name for this todo"),
        Err(OpenError::Conflict(msg)) => conflict(msg),
        Err(OpenError::Db(e)) => server_error(e),
    }
}

pub async fn duplicate_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<DuplicateConversationRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match duplicate_conversation_db(&conn, &path.into_inner(), &body.source_id, &body.tool, &body.label) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Conversation not found"),
        Err(e) => open_error(e),
    }
}

pub async fn set_conversation_session(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetConversationSessionRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_conversation_session_db(&conn, &path.into_inner(), &body.session_id) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Todo has no conversation"),
        Err(OpenError::Db(e)) if is_constraint_violation(&e) => conflict("That conversation is already linked to another todo"),
        Err(e) => open_error(e),
    }
}

fn open_error(e: OpenError) -> HttpResponse {
    match e {
        OpenError::TodoNotFound => not_found("Todo not found"),
        OpenError::NoComputer(section) => conflict(format!("Section {section} has no computer assigned")),
        OpenError::UnsupportedTool => bad_request("Unsupported tool"),
        OpenError::NoProject => bad_request("project_id is required"),
        OpenError::BadRequest(msg) => bad_request(msg),
        OpenError::NoTmuxName => conflict("No free tmux session name for this todo"),
        OpenError::Conflict(msg) => conflict(msg),
        OpenError::Db(e) => server_error(e),
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
    let project_id = body.project_id.trim();
    if project_id.is_empty() {
        return bad_request("project_id is required");
    }
    let new = NewTodo {
        section: body.section,
        title,
        project_id,
        importance: body.importance,
        due_date: body.due_date.as_deref(),
    };
    match todo_from_conversation_db(&conn, &new, &target) {
        Ok(created) => {
            broadcaster.send();
            HttpResponse::Created().json(created)
        }
        Err(e) => link_error_response(e),
    }
}

fn close_conversation_id(conn: &Connection, id: &str) -> Result<Conversation, OpenError> {
    let updated = conn.execute(
        "UPDATE conversations SET status = 'closed', status_message = NULL, status_updated_at = datetime('now')
         WHERE id = ?1",
        params![id],
    )?;
    if updated == 0 {
        return Err(OpenError::TodoNotFound);
    }
    load_conversation_by_id(conn, id)?.ok_or(OpenError::TodoNotFound)
}

fn review_conversation(conn: &Connection, id: &str, revision: i64) -> Result<Conversation, OpenError> {
    conn.execute(
        "UPDATE conversations SET reviewed = 1 WHERE id = ?1 AND status = 'idle' AND status_revision = ?2",
        params![id, revision],
    )?;
    load_conversation_by_id(conn, id)?.ok_or(OpenError::TodoNotFound)
}

pub async fn review_conversation_by_id(
    pool: web::Data<DbPool>, path: web::Path<String>,
    body: web::Json<todo_shared::ReviewConversationRequest>, broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match review_conversation(&conn, &path.into_inner(), body.status_revision) {
        Ok(c) => { broadcaster.send(); HttpResponse::Ok().json(c) }
        Err(e) => open_error(e),
    }
}

pub async fn close_conversation(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let id = match require_single(&conn, &path.into_inner()) {
        Ok(id) => id,
        Err(OpenError::TodoNotFound) => return not_found("Todo has no conversation"),
        Err(e) => return open_error(e),
    };
    match close_conversation_id(&conn, &id) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Todo has no conversation"),
        Err(e) => open_error(e),
    }
}

pub async fn close_conversation_by_id(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match close_conversation_id(&conn, &path.into_inner()) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Conversation not found"),
        Err(e) => open_error(e),
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
    let id = match require_single(&conn, &todo_id) {
        Ok(id) => id,
        Err(OpenError::TodoNotFound) => return not_found("Todo has no conversation"),
        Err(e) => return open_error(e),
    };
    match conn.execute("DELETE FROM conversations WHERE id = ?1", params![id]) {
        Ok(0) => not_found("Todo has no conversation"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: todo_id })
        }
        Err(e) => server_error(e),
    }
}

pub async fn delete_conversation_by_id(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute("DELETE FROM conversations WHERE id = ?1", params![id]) {
        Ok(0) => not_found("Conversation not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: id })
        }
        Err(e) => server_error(e),
    }
}

pub async fn set_conversation_session_by_id(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetConversationSessionRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_session_on(&conn, &path.into_inner(), &body.session_id) {
        Ok(c) => {
            broadcaster.send();
            HttpResponse::Ok().json(c)
        }
        Err(OpenError::TodoNotFound) => not_found("Conversation not found"),
        Err(OpenError::Db(e)) if is_constraint_violation(&e) => conflict("That conversation is already linked to another todo"),
        Err(e) => open_error(e),
    }
}

/// Replace a conversation's MCP selection (`null` clears it).
pub async fn set_conversation_mcp_by_id(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetConversationMcpRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let mcp_servers = match validate_mcp_option(body.mcp_servers.clone()) {
        Ok(names) => names,
        Err(msg) => return bad_request(&msg),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let id = path.into_inner();
    match conn.execute(
        "UPDATE conversations SET mcp_servers = ?1 WHERE id = ?2",
        params![mcp_to_sql(mcp_servers.as_deref()), id],
    ) {
        Ok(0) => return not_found("Conversation not found"),
        Ok(_) => {}
        Err(e) => return server_error(e),
    }
    broadcaster.send();
    match load_conversation_by_id(&conn, &id) {
        Ok(Some(c)) => HttpResponse::Ok().json(c),
        Ok(None) => not_found("Conversation not found"),
        Err(e) => server_error(e),
    }
}

/// The host script reports the servers it passed to a conversation, found by tool and
/// session id. Unknown sessions get a 404, which the script ignores (like status hooks).
pub async fn report_conversation_mcp(
    pool: web::Data<DbPool>,
    body: web::Json<ReportConversationMcpRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let mcp_servers = match validate_mcp_names(body.mcp_servers.clone()) {
        Ok(names) => names,
        Err(msg) => return bad_request(&msg),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute(
        "UPDATE conversations SET mcp_servers = ?1 WHERE tool = ?2 AND session_id = ?3",
        params![mcp_to_sql(Some(&mcp_servers)), body.tool.trim(), body.session_id.trim()],
    ) {
        Ok(0) => not_found("Unknown session_id"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::NoContent().finish()
        }
        Err(e) => server_error(e),
    }
}

/// Status hook endpoint. Takes `session_id` or (older hooks) `claude_session_id`, plus an
/// optional `tool` (default `claude`: hooks from before multi-tool support are Claude hooks).
/// Unknown session ids (sessions that are not todo conversations) get a 404, which hooks ignore.
pub async fn post_conversation_status(
    pool: web::Data<DbPool>,
    body: web::Json<ConversationStatusRequest>,
    broadcaster: web::Data<Broadcaster>,
    notifier: web::Data<PushNotifier>,
) -> HttpResponse {
    if body.status == ConversationStatus::Closed {
        return bad_request("Hooks cannot close a conversation; use POST /api/todos/{id}/conversation/close");
    }
    let Some(session_id) = body.session_id() else {
        return bad_request("session_id (or claude_session_id) is required");
    };
    let tool = body.tool();
    if !SUPPORTED_TOOLS.contains(&tool) {
        return bad_request("Unsupported tool");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_status_db(&conn, tool, session_id, &body) {
        Ok(None) => not_found("Unknown or closed session_id"),
        Ok(Some(change)) => {
            broadcaster.send();
            notifier.notify(Transition {
                todo_id: change.todo_id,
                old: change.old,
                new: body.status,
                attended: body.attended.unwrap_or(false),
                at: std::time::SystemTime::now(),
            });
            HttpResponse::NoContent().finish()
        }
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::TestDb;

    /// The test database (removed on drop) and its pool; the pool is dropped first.
    fn pool() -> (TestDb, DbPool) {
        let db = TestDb::new("conv");
        let pool = db.pool();
        (db, pool)
    }

    fn new_todo<'a>(section: Section, title: &'a str, project_id: &'a str) -> NewTodo<'a> {
        NewTodo { section, title, project_id, importance: None, due_date: None }
    }

    fn seed(conn: &Connection) {
        conn.execute(
            "INSERT INTO computers (id, name, hostname, username) VALUES ('m1', 'Mac', 'mac.tailnet', 'me')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO section_computers (section, computer_id) VALUES ('I', 'm1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO projects (id, name, section, folder) VALUES ('p1', 'programming', 'I', '~/programming')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('0f3a9c21-aaaa-4bbb-8ccc-123456789abc', 'I', 'with mapping', 'p1')",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO todos (id, section, title) VALUES ('t-p', 'P', 'no mapping')", []).unwrap();
    }

    const TODO: &str = "0f3a9c21-aaaa-4bbb-8ccc-123456789abc";

    fn sample(id: &str, status: ConversationStatus, updated: Option<&str>, created: &str) -> Conversation {
        Conversation {
            id: id.into(),
            todo_id: TODO.into(),
            computer: Computer {
                id: "m1".into(),
                name: "Mac".into(),
                hostname: "mac".into(),
                port: 22,
                username: "me".into(),
                created_at: String::new(),
                updated_at: String::new(),
                mcp_default: None,
            },
            cwd: "~/programming".into(),
            tool: "claude".into(),
            tmux_name: format!("ai/claude/{id}"),
            session_id: id.into(),
            claude_session_id: Some(id.into()),
            status,
            status_message: None,
            status_updated_at: updated.map(str::to_string),
            status_revision: 0,
            reviewed: false,
            created_at: created.into(),
            project_id: None,
            label: None,
            mcp_servers: None,
        }
    }

    #[test]
    fn most_urgent_picks_waiting_over_newer_idle() {
        let idle = sample("idle", ConversationStatus::Idle, Some("2026-10-20T12:00:00Z"), "2026-10-16T10:00:00Z");
        let waiting = sample("wait", ConversationStatus::Waiting, Some("2026-10-20T08:00:00Z"), "2026-10-16T09:00:00Z");
        assert_eq!(most_urgent(&[idle, waiting]).map(|c| c.id.as_str()), Some("wait"));

        let earlier = sample("a", ConversationStatus::Waiting, Some("2026-10-20T08:00:00Z"), "2026-10-16T09:00:00Z");
        let later = sample("b", ConversationStatus::Waiting, Some("2026-10-20T09:00:00Z"), "2026-10-16T08:00:00Z");
        assert_eq!(most_urgent(&[earlier, later]).map(|c| c.id.as_str()), Some("b"));
    }

    #[test]
    fn unread_result_outranks_newer_reviewed_and_unknown_conversations() {
        let unread = sample("unread", ConversationStatus::Idle, Some("2026-10-20T08:00:00Z"), "2026-10-16T08:00:00Z");
        let mut read = sample("read", ConversationStatus::Idle, Some("2026-10-20T12:00:00Z"), "2026-10-16T12:00:00Z");
        read.reviewed = true;
        let unknown = sample("unknown", ConversationStatus::Unknown, Some("2026-10-20T13:00:00Z"), "2026-10-16T13:00:00Z");
        assert_eq!(most_urgent(&[read, unread, unknown]).map(|c| c.id.as_str()), Some("unread"));
    }

    #[test]
    fn todo_status_follows_most_urgent() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute(
            "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, status, status_updated_at, created_at)
             VALUES ('idle', ?1, 'm1', '~/programming', 'claude', 'ai/claude/idle', 'sess-idle', 'idle', '2026-10-20 12:00:00', '2026-10-16 10:00:00'),
                    ('wait', ?1, 'm1', '~/programming', 'codex', 'ai/codex/wait', 'sess-wait', 'waiting', '2026-10-20 08:00:00', '2026-10-16 09:00:00')",
            params![TODO],
        )
        .unwrap();
        let todo = conn
            .query_row(
                &format!("SELECT {} FROM todos WHERE id = ?1", crate::handlers::SELECT_COLS),
                params![TODO],
                crate::models::row_to_todo,
            )
            .unwrap();
        assert_eq!(todo.conversation_status, Some(ConversationStatus::Waiting));
    }

    #[actix_web::test]
    async fn list_leaves_out_archived_todos_unless_show_all() {
        let (_db, pool) = crate::test_support::pool("archived");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, section, title, completed, completed_at) VALUES
                 ('t-old', 'I', 'archived', 1, datetime('now', '-2 days')),
                 ('t-new', 'I', 'done today', 1, datetime('now', '-1 hour'));
             INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, status) VALUES
                 ('c-open', '0f3a9c21-aaaa-4bbb-8ccc-123456789abc', 'm1', '~', 'claude', 'ai/claude/a', 's-open', 'idle'),
                 ('c-old', 't-old', 'm1', '~', 'claude', 'ai/claude/b', 's-old', 'idle'),
                 ('c-new', 't-new', 'm1', '~', 'claude', 'ai/claude/c', 's-new', 'idle');",
        )
        .unwrap();
        drop(conn);
        let ids = |body: serde_json::Value| -> Vec<String> {
            let mut ids: Vec<String> =
                body.as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_string()).collect();
            ids.sort();
            ids
        };
        let (status, body) = crate::test_support::get(&pool, "/api/conversations").await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        assert_eq!(ids(body), ["c-new", "c-open"]);
        let (_, body) = crate::test_support::get(&pool, "/api/conversations?show=all").await;
        assert_eq!(ids(body), ["c-new", "c-old", "c-open"]);
        let (status, _) = crate::test_support::get(&pool, "/api/conversations?show=nope").await;
        assert_eq!(status, actix_web::http::StatusCode::BAD_REQUEST);
    }

    async fn claude_on_mac(pool: &DbPool) -> serde_json::Value {
        let conn = pool.get().unwrap();
        crate::test_support::seed_computers(&conn);
        conn.execute(
            "INSERT INTO projects (id, name, section, folder) VALUES ('p1', 'programming', 'P', '~/programming')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('t1', 'P', 'keep going', 'p1')",
            [],
        )
        .unwrap();
        drop(conn);
        let (status, source) =
            crate::test_support::post(pool, "/api/todos/t1/conversation", serde_json::json!({"tool": "claude"})).await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{source}");
        source
    }

    #[actix_web::test]
    async fn duplicate_copies_computer_and_folder() {
        let (_db, pool) = crate::test_support::pool("dup");
        let source = claude_on_mac(&pool).await;
        let source_id = source["id"].as_str().unwrap();
        let (status, created) = crate::test_support::post(
            &pool,
            "/api/todos/t1/conversations",
            serde_json::json!({"source_id": source_id, "tool": "codex", "label": "duplicate"}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{created}");
        assert_ne!(created["id"], source["id"]);
        assert_ne!(created["tmux_name"], source["tmux_name"]);
        assert_eq!(created["tool"], "codex");
        assert_eq!(created["label"], "duplicate");
        assert_eq!(created["computer"]["id"], "mac");
        assert_eq!(created["cwd"], "~/programming");
        assert_eq!(created["session_id"], "");

        let (status, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{rows}");
        let kept = rows.as_array().unwrap().iter().find(|row| row["id"] == source["id"]).unwrap();
        assert_eq!(kept["tool"], "claude");
        assert_eq!(kept["tmux_name"], source["tmux_name"]);
        assert_eq!(kept["cwd"], "~/programming");
        assert_eq!(kept["computer"]["id"], "mac");
        assert!(kept.get("label").is_none() || kept["label"].is_null());
    }

    use crate::test_support::{post as post_json, put as put_json};

    #[actix_web::test]
    async fn open_stores_mcp_only_when_creating() {
        let (_db, pool) = crate::test_support::pool("mcp-open");
        claude_on_mac(&pool).await;
        // `claude_on_mac` already created t1's row without a selection; use a second todo.
        let conn = pool.get().unwrap();
        conn.execute("INSERT INTO todos (id, section, title, project_id) VALUES ('t2', 'P', 'two', 'p1')", [])
            .unwrap();
        drop(conn);
        let first = post_json(
            &pool,
            "/api/todos/t2/conversation",
            serde_json::json!({"tool": "claude", "mcp_servers": ["grafana", "slack", "grafana"]}),
        )
        .await
        .1;
        assert_eq!(first["mcp_servers"], serde_json::json!(["grafana", "slack"]));
        let second = post_json(
            &pool,
            "/api/todos/t2/conversation",
            serde_json::json!({"tool": "claude", "mcp_servers": ["x"]}),
        )
        .await
        .1;
        assert_eq!(second["mcp_servers"], serde_json::json!(["grafana", "slack"]));
        assert_eq!(second["id"], first["id"]);
    }

    #[actix_web::test]
    async fn duplicate_copies_mcp_servers() {
        let (_db, pool) = crate::test_support::pool("mcp-dup");
        claude_on_mac(&pool).await;
        let conn = pool.get().unwrap();
        conn.execute("UPDATE conversations SET mcp_servers = '[\"grafana\"]'", []).unwrap();
        drop(conn);
        let (_, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        let source_id = rows[0]["id"].as_str().unwrap().to_string();
        let (status, created) = post_json(
            &pool,
            "/api/todos/t1/conversations",
            serde_json::json!({"source_id": source_id, "tool": "codex", "label": "copy"}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{created}");
        assert_eq!(created["mcp_servers"], serde_json::json!(["grafana"]));
        let (status, cursor) = post_json(
            &pool,
            "/api/todos/t1/conversations",
            serde_json::json!({"source_id": source_id, "tool": "cursor", "label": "cursor copy"}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{cursor}");
        assert!(cursor.get("mcp_servers").is_none(), "{cursor}");
        let conn = pool.get().unwrap();
        let stored: Option<String> = conn
            .query_row("SELECT mcp_servers FROM conversations WHERE id = ?1", [cursor["id"].as_str().unwrap()], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, None);
    }

    #[actix_web::test]
    async fn set_conversation_mcp_null_and_empty_differ() {
        let (_db, pool) = crate::test_support::pool("mcp-set");
        let source = claude_on_mac(&pool).await;
        let uri = format!("/api/conversations/{}/mcp", source["id"].as_str().unwrap());
        let (status, body) = put_json(&pool, &uri, serde_json::json!({"mcp_servers": []})).await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        assert_eq!(body["mcp_servers"], serde_json::json!([]));
        let (_, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        assert_eq!(rows[0]["mcp_servers"], serde_json::json!([]));
        let (status, body) = put_json(&pool, &uri, serde_json::json!({"mcp_servers": null})).await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        assert!(body.get("mcp_servers").is_none());
        let (_, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        assert!(rows[0].get("mcp_servers").is_none());
        let (status, _) = put_json(&pool, "/api/conversations/missing/mcp", serde_json::json!({"mcp_servers": []})).await;
        assert_eq!(status, actix_web::http::StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn report_mcp_by_session() {
        let (_db, pool) = crate::test_support::pool("mcp-report");
        let source = claude_on_mac(&pool).await;
        let session = source["session_id"].as_str().unwrap();
        let (status, _) = post_json(
            &pool,
            "/api/conversations/mcp",
            serde_json::json!({"tool": "claude", "session_id": session, "mcp_servers": ["grafana"]}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::NO_CONTENT);
        let (_, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        assert_eq!(rows[0]["mcp_servers"], serde_json::json!(["grafana"]));
        let (status, _) = post_json(
            &pool,
            "/api/conversations/mcp",
            serde_json::json!({"tool": "claude", "session_id": "nope", "mcp_servers": ["grafana"]}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::NOT_FOUND);
        let (status, _) = post_json(
            &pool,
            "/api/conversations/mcp",
            serde_json::json!({"tool": "claude", "session_id": session, "mcp_servers": ["../x"]}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn rejects_bad_mcp_names() {
        let (_db, pool) = crate::test_support::pool("mcp-bad");
        let source = claude_on_mac(&pool).await;
        let uri = format!("/api/conversations/{}/mcp", source["id"].as_str().unwrap());
        let too_long = "a".repeat(65);
        let too_many: Vec<String> = (0..33).map(|n| format!("s{n}")).collect();
        for bad in [serde_json::json!(["../x"]), serde_json::json!([too_long]), serde_json::json!(too_many), serde_json::json!([""])] {
            let (status, body) = put_json(&pool, &uri, serde_json::json!({"mcp_servers": bad})).await;
            assert_eq!(status, actix_web::http::StatusCode::BAD_REQUEST, "{bad}");
            assert_eq!(body["error"], "invalid MCP server name");
        }
        let (status, _) = post_json(
            &pool,
            "/api/todos/t1/conversation",
            serde_json::json!({"tool": "claude", "mcp_servers": ["a/b"]}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::BAD_REQUEST);
        let (status, _) = crate::test_support::patch(
            &pool,
            "/api/computers/mac",
            serde_json::json!({"mcp_default": ["a b"]}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn computer_mcp_default_update_and_clear() {
        let (_db, pool) = crate::test_support::pool("mcp-computer");
        claude_on_mac(&pool).await;
        let patch = crate::test_support::patch;
        let (status, body) = patch(&pool, "/api/computers/mac", serde_json::json!({"mcp_default": ["grafana"]})).await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        assert_eq!(body["mcp_default"], serde_json::json!(["grafana"]));
        let (_, body) = patch(&pool, "/api/computers/mac", serde_json::json!({"name": "Renamed"})).await;
        assert_eq!(body["mcp_default"], serde_json::json!(["grafana"]), "absent leaves it unchanged");
        let (_, body) = patch(&pool, "/api/computers/mac", serde_json::json!({"mcp_default": []})).await;
        assert_eq!(body["mcp_default"], serde_json::json!([]));
        let (_, body) = patch(&pool, "/api/computers/mac", serde_json::json!({"mcp_default": null})).await;
        assert!(body.get("mcp_default").is_none());
    }

    #[actix_web::test]
    async fn delete_one_leaves_the_other() {
        let (_db, pool) = crate::test_support::pool("dup-del");
        let source = claude_on_mac(&pool).await;
        let (status, created) = crate::test_support::post(
            &pool,
            "/api/todos/t1/conversations",
            serde_json::json!({"source_id": source["id"], "tool": "codex", "label": "duplicate"}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{created}");
        let (status, body) =
            crate::test_support::delete(&pool, &format!("/api/conversations/{}", created["id"].as_str().unwrap())).await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        let (status, rows) = crate::test_support::get(&pool, "/api/todos/t1/conversations").await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{rows}");
        let rows = rows.as_array().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["id"], source["id"]);
        let (status, todo) = crate::test_support::get(&pool, "/api/todos/t1").await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{todo}");
    }

    #[actix_web::test]
    async fn todo_scoped_delete_conflicts_when_two_exist() {
        let (_db, pool) = crate::test_support::pool("dup-409");
        let source = claude_on_mac(&pool).await;
        let (status, created) = crate::test_support::post(
            &pool,
            "/api/todos/t1/conversations",
            serde_json::json!({"source_id": source["id"], "tool": "codex", "label": "duplicate"}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{created}");
        let (status, body) = crate::test_support::delete(&pool, "/api/todos/t1/conversation").await;
        assert_eq!(status, actix_web::http::StatusCode::CONFLICT, "{body}");
        assert_eq!(body["error"], "conversation_id required");
        let n: i64 = pool.get().unwrap().query_row("SELECT COUNT(*) FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 2);
    }

    #[test]
    fn open_creates_once_and_snapshots_mapping() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);

        let first = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert_eq!(first.tmux_name, "ai/claude/todo-0f3a9c21");
        assert_eq!(first.cwd, "~/programming");
        assert_eq!(first.computer.id, "m1");
        assert_eq!(first.status, ConversationStatus::Unknown);
        assert!(Uuid::parse_str(first.claude_session_id.as_deref().unwrap()).is_ok());
        assert_eq!(first.claude_session_id.as_deref(), Some(first.session_id.as_str()));

        // Changing the section mapping does not move an existing conversation.
        conn.execute("UPDATE projects SET folder = '/elsewhere' WHERE id = 'p1'", []).unwrap();
        let again = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert_eq!(again.claude_session_id, first.claude_session_id);
        assert_eq!(again.cwd, "~/programming");
    }

    #[test]
    fn open_errors_without_todo_or_mapping() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        assert!(matches!(open_conversation_db(&conn, "missing", "claude", None), Err(OpenError::TodoNotFound)));
        assert!(matches!(open_conversation_db(&conn, "t-p", "claude", None), Err(OpenError::NoComputer(s)) if s == "P"));
    }

    #[test]
    fn short_tmux_name_collision_falls_back_to_full_id() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('0f3a9c21-ffff-4bbb-8ccc-000000000000', 'I', 'same prefix', 'p1')",
            [],
        )
        .unwrap();
        open_conversation_db(&conn, TODO, "claude", None).unwrap();
        let second = open_conversation_db(&conn, "0f3a9c21-ffff-4bbb-8ccc-000000000000", "claude", None).unwrap();
        assert_eq!(second.tmux_name, "ai/claude/todo-0f3a9c21-ffff-4bbb-8ccc-000000000000");
    }

    #[test]
    fn status_update_waits_for_a_concurrent_writer() {
        // Another connection holds the write lock while the hook's update reads the old status;
        // the update must wait for it rather than fail on a stale snapshot.
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        let writer = pool.get().unwrap();
        writer.execute_batch("BEGIN IMMEDIATE; UPDATE todos SET title = 'renamed' WHERE id = 'nope';").unwrap();
        let handle = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            writer.execute_batch("UPDATE todos SET updated_at = datetime('now'); COMMIT;").unwrap();
        });
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, ..Default::default() };
        let change = set_status_db(&conn, "claude", &conv.session_id, &busy);
        handle.join().unwrap();
        assert!(change.unwrap().is_some());
    }

    #[test]
    fn status_change_reports_old_status() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, ..Default::default() };
        let waiting = ConversationStatusRequest { status: ConversationStatus::Waiting, ..Default::default() };
        let first = set_status_db(&conn, "claude", &conv.session_id, &busy).unwrap().unwrap();
        assert_eq!(first, StatusChange { todo_id: TODO.into(), old: ConversationStatus::Unknown });
        let second = set_status_db(&conn, "claude", &conv.session_id, &waiting).unwrap().unwrap();
        assert_eq!(second.old, ConversationStatus::Busy);
        let repeat = set_status_db(&conn, "claude", &conv.session_id, &waiting).unwrap().unwrap();
        assert_eq!(repeat.old, ConversationStatus::Waiting);
    }

    #[test]
    fn review_acknowledges_only_the_displayed_result_and_rearms_on_next_turn() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        let idle = ConversationStatusRequest { status: ConversationStatus::Idle, ..Default::default() };
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, ..Default::default() };
        set_status_db(&conn, "claude", &conv.session_id, &idle).unwrap();
        let first = load_conversation_by_id(&conn, &conv.id).unwrap().unwrap();
        assert!(!first.reviewed);
        assert!(review_conversation(&conn, &conv.id, first.status_revision).unwrap().reviewed);
        // Duplicate Stop/notify heartbeats must not make a read result unread again.
        set_status_db(&conn, "claude", &conv.session_id, &idle).unwrap();
        let repeated = load_conversation_by_id(&conn, &conv.id).unwrap().unwrap();
        assert!(repeated.reviewed);
        assert_eq!(repeated.status_revision, first.status_revision);
        assert_eq!(repeated.status_updated_at, first.status_updated_at);
        set_status_db(&conn, "claude", &conv.session_id, &busy).unwrap();
        assert!(!review_conversation(&conn, &conv.id, first.status_revision).unwrap().reviewed);
        set_status_db(&conn, "claude", &conv.session_id, &idle).unwrap();
        let second = review_conversation(&conn, &conv.id, first.status_revision).unwrap();
        assert!(!second.reviewed, "late acknowledgement must not clear a newer result");
        assert!(second.status_revision > first.status_revision);
        assert!(review_conversation(&conn, &conv.id, second.status_revision).unwrap().reviewed);
    }

    #[test]
    fn status_updates_and_reopen_resets_closed() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None).unwrap();

        let req = ConversationStatusRequest {
            status: ConversationStatus::Waiting,
            message: Some("needs approval".into()),
            ..Default::default()
        };
        let change = set_status_db(&conn, "claude", &conv.session_id, &req).unwrap().unwrap();
        assert_eq!((change.todo_id.as_str(), change.old), (TODO, ConversationStatus::Unknown));
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, ..Default::default() };
        assert_eq!(set_status_db(&conn, "claude", "nope", &busy).unwrap(), None);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Waiting);

        conn.execute("UPDATE conversations SET status = 'closed' WHERE todo_id = ?1", params![TODO]).unwrap();
        // A late hook must not make a closed conversation look live again.
        let late = ConversationStatusRequest { status: ConversationStatus::Idle, ..Default::default() };
        assert_eq!(set_status_db(&conn, "claude", &conv.session_id, &late).unwrap(), None);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Closed);

        let reopened = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert_eq!(reopened.status, ConversationStatus::Unknown);
        assert_eq!(reopened.claude_session_id, conv.claude_session_id);
    }

    #[test]
    fn deleting_todo_cascades_and_computer_in_use_is_protected() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        open_conversation_db(&conn, TODO, "claude", None).unwrap();

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
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = link_conversation_db(&conn, TODO, &target("codex", "019f8b4e-ff53"), false).unwrap();
        assert_eq!(conv.tool, "codex");
        assert_eq!(conv.session_id, "019f8b4e-ff53");
        assert_eq!(conv.claude_session_id, None, "older clients must not resume a Codex id with claude");
        assert_eq!(conv.tmux_name, "ai/codex/todo-0f3a9c21");
        assert_eq!(conv.cwd, "~/Repositories/app");

        // Linking the same conversation again is a no-op; opening keeps it.
        let again = link_conversation_db(&conn, TODO, &target("codex", "019f8b4e-ff53"), false).unwrap();
        assert_eq!(again.session_id, conv.session_id);
        assert_eq!(open_conversation_db(&conn, TODO, "claude", None).unwrap().tool, "codex");
    }

    #[test]
    fn link_refuses_a_second_conversation_unless_replace() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let started = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert!(matches!(
            link_conversation_db(&conn, TODO, &target("claude", "other-id"), false),
            Err(LinkError::TodoHasConversation)
        ));
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().session_id, started.session_id);

        let replaced = link_conversation_db(&conn, TODO, &target("claude", "other-id"), true).unwrap();
        assert_eq!(replaced.session_id, "other-id");
        // A new tmux name: the old conversation may still run under `ai/claude/todo-0f3a9c21`,
        // and opening the todo must not attach to it.
        assert_ne!(replaced.tmux_name, started.tmux_name);
        assert_eq!(replaced.tmux_name, "ai/claude/todo-0f3a9c21-other-id");

        let again = link_conversation_db(&conn, TODO, &target("codex", "019f8b4e-ff53"), true).unwrap();
        assert_eq!(again.tmux_name, "ai/codex/todo-0f3a9c21-019f8b4e");
        for name in [&started.tmux_name, &replaced.tmux_name, &again.tmux_name] {
            assert!(name.split('/').all(|seg| !seg.is_empty()
                && seg.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')));
        }
    }

    #[test]
    fn status_post_matches_one_tool_only() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO todos (id, section, title) VALUES ('t-2', 'I', 'second')", []).unwrap();
        link_conversation_db(&conn, TODO, &target("claude", "shared"), false).unwrap();
        link_conversation_db(&conn, "t-2", &target("codex", "shared"), false).unwrap();

        // Older hooks send no tool: they are Claude hooks.
        let legacy: ConversationStatusRequest =
            serde_json::from_str(r#"{"claude_session_id":"shared","status":"busy"}"#).unwrap();
        assert_eq!(legacy.tool(), "claude");
        assert!(set_status_db(&conn, legacy.tool(), "shared", &legacy).unwrap().is_some());
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Busy);
        assert_eq!(load_conversation(&conn, "t-2").unwrap().unwrap().status, ConversationStatus::Unknown);

        let codex: ConversationStatusRequest =
            serde_json::from_str(r#"{"session_id":"shared","tool":"codex","status":"idle"}"#).unwrap();
        assert!(set_status_db(&conn, codex.tool(), "shared", &codex).unwrap().is_some());
        assert_eq!(load_conversation(&conn, "t-2").unwrap().unwrap().status, ConversationStatus::Idle);
        assert_eq!(load_conversation(&conn, TODO).unwrap().unwrap().status, ConversationStatus::Busy);
    }

    #[test]
    fn failed_conversation_insert_reports_the_real_cause() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO todos (id, section, title) VALUES ('t-2', 'I', 'second')", []).unwrap();
        link_conversation_db(&conn, TODO, &target("claude", "taken"), false).unwrap();

        // Insert the same (tool, session) for another todo, bypassing the pre-checks.
        let err = insert_conversation(&conn, "t-2", "m1", "~", "claude", Some("taken"), false, None, None).unwrap_err();
        assert!(matches!(
            link_insert_error(&conn, err, "t-2", &target("claude", "taken")),
            LinkError::SessionTaken(t) if t == TODO
        ));
        let err = insert_conversation(&conn, "t-2", "missing-computer", "~", "codex", Some("x"), false, None, None).unwrap_err();
        let nowhere = link_target("missing-computer", "codex", "x", "~").unwrap();
        assert!(matches!(link_insert_error(&conn, err, "t-2", &nowhere), LinkError::ComputerNotFound));
    }

    #[test]
    fn a_conversation_links_to_one_todo_only() {
        let (_db, pool) = pool();
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
            todo_from_conversation_db(&conn, &new_todo(Section::I, "dup", "p1"), &target("claude", "shared")),
            Err(LinkError::SessionTaken(_))
        ));
    }

    #[test]
    fn link_errors_for_missing_todo_or_computer() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        assert!(matches!(
            link_conversation_db(&conn, "missing", &target("claude", "x"), false),
            Err(LinkError::TodoNotFound)
        ));
        let nowhere = link_target("nope", "claude", "x", "~").unwrap();
        assert!(matches!(link_conversation_db(&conn, TODO, &nowhere, false), Err(LinkError::ComputerNotFound)));
        assert!(matches!(
            todo_from_conversation_db(&conn, &new_todo(Section::P, "t", "p1"), &nowhere),
            Err(LinkError::ComputerNotFound)
        ));
        let todos: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(todos, 2, "a failed from-conversation must not leave a todo behind");
    }

    #[test]
    fn todo_from_conversation_creates_both() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute(
            "INSERT INTO projects (id, name, section, folder) VALUES ('p-sp', 'site', 'Sp', '~/site')",
            [],
        )
        .unwrap();
        let new = NewTodo {
            section: Section::Sp,
            title: "Review PR 630",
            project_id: "p-sp",
            importance: Some(Importance::High),
            due_date: Some("2026-10-20"),
        };
        let created = todo_from_conversation_db(&conn, &new, &target("claude", "49e9880f")).unwrap();
        assert_eq!(created.todo.project_id.as_deref(), Some("p-sp"));
        assert_eq!(created.todo.importance, Importance::High);
        assert_eq!(created.todo.due_date.as_deref(), Some("2026-10-20"));
        assert_eq!(created.todo.section, Section::Sp);
        assert_eq!(created.todo.title, "Review PR 630");
        assert_eq!(created.todo.conversation_status, Some(ConversationStatus::Unknown));
        assert_eq!(created.conversation.todo_id, created.todo.id);
        assert_eq!(created.conversation.session_id, "49e9880f");
        assert!(created.conversation.tmux_name.starts_with("ai/claude/todo-"));
    }

    #[test]
    fn todo_from_conversation_without_a_project_inserts_nothing() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let before: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert!(matches!(
            todo_from_conversation_db(&conn, &new_todo(Section::I, "from a chat", ""), &target("claude", "from-none")),
            Err(LinkError::ProjectRequired)
        ));
        assert!(matches!(
            todo_from_conversation_db(&conn, &new_todo(Section::I, "from a chat", "missing"), &target("claude", "from-missing")),
            Err(LinkError::ProjectNotFound)
        ));
        let after: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(before, after, "a from-conversation without a project inserts nothing");
        let conversations: i64 = conn.query_row("SELECT COUNT(*) FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(conversations, 0);
    }

    #[test]
    fn open_codex_stores_a_null_session_id() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "codex", None).unwrap();
        assert_eq!(conv.tool, "codex");
        assert!(conv.session_id.is_empty());
        assert_eq!(conv.cwd, "~/programming");
        assert!(Uuid::parse_str(&conv.session_id).is_err());
        let stored: Option<String> = conn
            .query_row("SELECT session_id FROM conversations WHERE todo_id = ?1", [TODO], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, None);
    }

    #[test]
    fn open_claude_stores_a_server_uuid() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert!(Uuid::parse_str(&conv.session_id).is_ok());
    }

    #[test]
    fn set_session_id_then_reopen_keeps_it() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        open_conversation_db(&conn, TODO, "codex", None).unwrap();
        let set = set_conversation_session_db(&conn, TODO, "019f8b4e").unwrap();
        assert_eq!(set.session_id, "019f8b4e");
        let again = open_conversation_db(&conn, TODO, "claude", None).unwrap();
        assert_eq!(again.session_id, "019f8b4e");
        assert_eq!(again.tool, "codex");
        let rows: i64 = conn.query_row("SELECT COUNT(*) FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(rows, 1);
    }

    #[test]
    fn open_rejects_an_unknown_tool() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        seed(&conn);
        assert!(matches!(open_conversation_db(&conn, TODO, "vim", None), Err(OpenError::UnsupportedTool)));
        assert!(matches!(open_conversation_db(&conn, TODO, "", None), Err(OpenError::UnsupportedTool)));
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
