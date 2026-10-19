//! Memories: short facts extracted from AI conversations (or added in the app), kept per
//! project and, when the conversation is linked to one, per todo.
//!
//! Extracted memories are deduplicated across the whole project, so a conversation that
//! read the project's digest doesn't store the same gotchas again.

use unicode_normalization::UnicodeNormalization;
use std::collections::HashSet;

use actix_web::{web, HttpResponse};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use todo_shared::{
    BulkMemoriesRequest, BulkMemoriesResponse, CreateMemoryRequest, DeleteResponse, Memory, MemoryKind,
    UpdateMemoryRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{
    bad_request, conflict, get_computer, is_constraint_violation, not_found, server_error, SUPPORTED_TOOLS,
};
use crate::db::DbPool;
use crate::projects::project_exists;
use crate::sessions::ensure_session_db;

const MAX_TEXT_CHARS: usize = 400;
const MAX_FILES: usize = 20;
/// Fuzzy duplicates: token-set Jaccard at or above this, same kind, within the window.
const FUZZY_THRESHOLD: f64 = 0.8;
const FUZZY_WINDOW: &str = "-90 days";
const DEFAULT_LIMIT: usize = 200;
const MAX_LIMIT: usize = 1000;

const MEMORY_COLS: &str = "id, project_id, todo_id, computer_id, tool, session_id, kind, text, files, confidence,
    source, pinned, archived, created_at, updated_at";

/// Normalized text for duplicate detection: Unicode NFC, lowercase, every run of characters that are
/// not alphanumeric (Unicode-aware, so Cyrillic letters stay) becomes one space, trimmed.
pub(crate) fn text_key(text: &str) -> String {
    let mut key = String::with_capacity(text.len());
    let mut gap = false;
    // NFC first: a decomposed "é" (e + combining accent) would otherwise lose its accent,
    // since combining marks are not alphanumeric.
    for c in text.nfc().flat_map(char::to_lowercase) {
        if c.is_alphanumeric() {
            if gap && !key.is_empty() {
                key.push(' ');
            }
            gap = false;
            key.push(c);
        } else {
            gap = true;
        }
    }
    key
}

fn tokens(key: &str) -> HashSet<&str> {
    key.split(' ').filter(|t| !t.is_empty()).collect()
}

fn jaccard_tokens(a: &HashSet<&str>, b: &HashSet<&str>) -> f64 {
    let union = a.union(b).count();
    if union == 0 {
        return 0.0;
    }
    #[allow(clippy::cast_precision_loss)] // token counts are tiny
    let ratio = a.intersection(b).count() as f64 / union as f64;
    ratio
}

/// Token-set Jaccard similarity of two texts (over their `text_key`s). Dedup itself
/// compares precomputed keys with `jaccard_tokens`.
#[cfg(test)]
pub(crate) fn jaccard(a: &str, b: &str) -> f64 {
    let (a, b) = (text_key(a), text_key(b));
    jaccard_tokens(&tokens(&a), &tokens(&b))
}

fn row_to_memory(row: &Row) -> rusqlite::Result<Memory> {
    let kind: String = row.get(6)?;
    let files: String = row.get(8)?;
    Ok(Memory {
        id: row.get(0)?,
        project_id: row.get(1)?,
        todo_id: row.get(2)?,
        computer_id: row.get(3)?,
        tool: row.get(4)?,
        session_id: row.get(5)?,
        kind: MemoryKind::parse(&kind).unwrap_or(MemoryKind::Gotcha),
        text: row.get(7)?,
        files: serde_json::from_str(&files).unwrap_or_default(),
        confidence: row.get(9)?,
        source: row.get(10)?,
        pinned: row.get::<_, i64>(11)? != 0,
        archived: row.get::<_, i64>(12)? != 0,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

pub(crate) fn load_memory(conn: &Connection, id: &str) -> rusqlite::Result<Option<Memory>> {
    conn.query_row(&format!("SELECT {MEMORY_COLS} FROM memories WHERE id = ?1"), params![id], row_to_memory)
        .optional()
}

#[derive(Debug)]
pub(crate) enum MemoryError {
    BadRequest(String),
    NotFound(&'static str),
    Conflict(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for MemoryError {
    fn from(e: rusqlite::Error) -> Self {
        MemoryError::Db(e)
    }
}

fn memory_error_response(e: MemoryError) -> HttpResponse {
    match e {
        MemoryError::BadRequest(msg) => bad_request(&msg),
        MemoryError::NotFound(msg) => not_found(msg),
        MemoryError::Conflict(msg) => conflict(msg),
        MemoryError::Db(e) => server_error(e),
    }
}

/// Trimmed text of 1–400 characters (not bytes).
fn checked_text(text: &str) -> Result<String, MemoryError> {
    let text = text.trim();
    let chars = text.chars().count();
    if chars == 0 || chars > MAX_TEXT_CHARS {
        return Err(MemoryError::BadRequest(format!("text must be 1-{MAX_TEXT_CHARS} characters")));
    }
    Ok(text.to_string())
}

/// At most 20 file paths, trimmed, empty ones dropped; stored as a JSON array.
fn checked_files(files: &[String]) -> Result<String, MemoryError> {
    if files.len() > MAX_FILES {
        return Err(MemoryError::BadRequest(format!("files may list at most {MAX_FILES} paths")));
    }
    let files: Vec<&str> = files.iter().map(|f| f.trim()).filter(|f| !f.is_empty()).collect();
    Ok(serde_json::to_string(&files).unwrap_or_else(|_| "[]".into()))
}

fn checked_confidence(confidence: Option<f64>) -> Result<Option<f64>, MemoryError> {
    match confidence {
        Some(c) if !(0.0..=1.0).contains(&c) => Err(MemoryError::BadRequest("confidence must be between 0 and 1".into())),
        c => Ok(c),
    }
}

/// An existing memory as far as duplicate detection needs it.
struct Known {
    id: String,
    kind: MemoryKind,
    key: String,
    /// Inside the fuzzy window (the last 90 days)
    recent: bool,
}

/// The memories a new one is compared with: the project's (all of them, archived
/// included), or, for a session without a project, that session's.
fn known_memories(conn: &Connection, project_id: Option<&str>, tool: &str, session_id: &str) -> rusqlite::Result<Vec<Known>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT id, kind, text_key, created_at >= datetime('now', '{FUZZY_WINDOW}') FROM memories
         WHERE CASE WHEN ?1 IS NOT NULL THEN project_id = ?1 ELSE tool = ?2 AND session_id = ?3 END"
    ))?;
    let rows = stmt.query_map(params![project_id, tool, session_id], |r| {
        let kind: String = r.get(1)?;
        Ok(Known {
            id: r.get(0)?,
            kind: MemoryKind::parse(&kind).unwrap_or(MemoryKind::Gotcha),
            key: r.get(2)?,
            recent: r.get::<_, i64>(3)? != 0,
        })
    })?;
    rows.collect()
}

/// The memory a new one duplicates: equal `text_key` (any kind, any age), or a Jaccard of
/// at least 0.8 with a recent memory of the same kind.
fn find_duplicate<'a>(known: &'a [Known], kind: MemoryKind, key: &str) -> Option<&'a Known> {
    if let Some(exact) = known.iter().find(|k| k.key == key) {
        return Some(exact);
    }
    let new_tokens = tokens(key);
    known
        .iter()
        .filter(|k| k.recent && k.kind == kind)
        .find(|k| jaccard_tokens(&tokens(&k.key), &new_tokens) >= FUZZY_THRESHOLD)
}

/// Store the memories extracted from one conversation, in one IMMEDIATE transaction.
///
/// The session row is created if missing (so the memories get its project), the todo comes
/// from the conversation link, duplicates are counted instead of inserted, and `supersedes`
/// archives unpinned memories of the same project.
pub(crate) fn insert_bulk_db(conn: &Connection, req: &BulkMemoriesRequest) -> Result<BulkMemoriesResponse, MemoryError> {
    let tool = req.tool.trim();
    if !SUPPORTED_TOOLS.contains(&tool) {
        return Err(MemoryError::BadRequest("Unsupported tool".into()));
    }
    let session_id = req.session_id.trim();
    if session_id.is_empty() || session_id.chars().any(char::is_whitespace) {
        return Err(MemoryError::BadRequest("session_id is required (no spaces)".into()));
    }
    if req.cwd.trim().is_empty() {
        return Err(MemoryError::BadRequest("cwd is required".into()));
    }
    let mut checked = Vec::with_capacity(req.memories.len());
    for m in &req.memories {
        checked.push((checked_text(&m.text)?, checked_files(&m.files)?, checked_confidence(m.confidence)?));
    }

    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let computer_id = req.computer_id.trim();
    if get_computer(&tx, computer_id)?.is_none() {
        return Err(MemoryError::NotFound("Computer not found"));
    }
    let project_id = ensure_session_db(&tx, computer_id, tool, session_id, req.cwd.trim())?;
    let todo_id: Option<String> = tx
        .query_row(
            "SELECT todo_id FROM conversations WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get(0),
        )
        .optional()?;
    let mut known = known_memories(&tx, project_id.as_deref(), tool, session_id)?;

    let mut inserted_ids = Vec::new();
    let mut archived: Vec<String> = Vec::new();
    let mut duplicates = 0;
    for (m, (text, files, confidence)) in req.memories.iter().zip(checked) {
        let key = text_key(&text);
        let duplicate_of = find_duplicate(&known, m.kind, &key).map(|k| k.id.clone());
        if duplicate_of.is_some() {
            duplicates += 1;
        } else {
            let id = Uuid::new_v4().to_string();
            // The unique (tool, session_id, kind, text_key) index is a backstop: a clash is a duplicate.
            let added = tx.execute(
                "INSERT OR IGNORE INTO memories (id, project_id, todo_id, computer_id, tool, session_id, kind, text,
                                                 text_key, files, confidence, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'extracted')",
                params![id, project_id, todo_id, computer_id, tool, session_id, m.kind.as_str(), text, key, files, confidence],
            )?;
            if added == 0 {
                duplicates += 1;
            } else {
                known.push(Known { id: id.clone(), kind: m.kind, key, recent: true });
                inserted_ids.push(id);
            }
        }
        // Applied even when the memory itself was a duplicate (it still resolves the
        // threads it names), but never to the memory it duplicates.
        if let Some(project_id) = project_id.as_deref() {
            for target in &m.supersedes {
                if duplicate_of.as_deref() == Some(target.as_str()) || archived.contains(target) {
                    continue;
                }
                let changed = tx.execute(
                    "UPDATE memories SET archived = 1, updated_at = datetime('now')
                     WHERE id = ?1 AND project_id = ?2 AND pinned = 0 AND archived = 0",
                    params![target, project_id],
                )?;
                if changed > 0 {
                    archived.push(target.clone());
                }
            }
        }
    }
    let inserted = inserted_ids
        .iter()
        .map(|id| load_memory(&tx, id)?.ok_or(rusqlite::Error::QueryReturnedNoRows))
        .collect::<rusqlite::Result<Vec<_>>>()?;
    tx.commit()?;
    Ok(BulkMemoriesResponse { inserted, duplicates, archived, project_id, todo_id })
}

/// A manual memory from the app. It needs a project or a todo; a todo without an
/// explicit project gives the memory the todo's project.
pub(crate) fn create_memory_db(conn: &Connection, req: &CreateMemoryRequest) -> Result<Memory, MemoryError> {
    let text = checked_text(&req.text)?;
    let files = checked_files(req.files.as_deref().unwrap_or_default())?;
    let project_id = req.project_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let todo_id = req.todo_id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    if project_id.is_none() && todo_id.is_none() {
        return Err(MemoryError::BadRequest("project_id or todo_id is required".into()));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let todo_project = match todo_id {
        Some(todo_id) => tx
            .query_row("SELECT project_id FROM todos WHERE id = ?1", params![todo_id], |r| r.get::<_, Option<String>>(0))
            .optional()?
            .ok_or(MemoryError::NotFound("Todo not found"))?,
        None => None,
    };
    if let Some(project_id) = project_id {
        if !project_exists(&tx, project_id)? {
            return Err(MemoryError::NotFound("Project not found"));
        }
    }
    let project_id = project_id.map(str::to_string).or(todo_project);
    let id = Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO memories (id, project_id, todo_id, kind, text, text_key, files, source, pinned)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'manual', ?8)",
        params![id, project_id, todo_id, req.kind.as_str(), text, text_key(&text), files, req.pinned.unwrap_or(false)],
    )?;
    let memory = load_memory(&tx, &id)?.ok_or(MemoryError::NotFound("Memory not found"))?;
    tx.commit()?;
    Ok(memory)
}

pub(crate) fn update_memory_db(conn: &Connection, id: &str, req: &UpdateMemoryRequest) -> Result<Memory, MemoryError> {
    let text = req.text.as_deref().map(checked_text).transpose()?;
    let files = req.files.as_deref().map(checked_files).transpose()?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if load_memory(&tx, id)?.is_none() {
        return Err(MemoryError::NotFound("Memory not found"));
    }
    if let Some(Some(project_id)) = &req.project_id {
        if !project_exists(&tx, project_id)? {
            return Err(MemoryError::NotFound("Project not found"));
        }
    }
    if let Some(Some(todo_id)) = &req.todo_id {
        if !tx.prepare("SELECT 1 FROM todos WHERE id = ?1")?.exists(params![todo_id])? {
            return Err(MemoryError::NotFound("Todo not found"));
        }
    }
    let result = tx.execute(
        "UPDATE memories SET
            text = COALESCE(?1, text),
            text_key = COALESCE(?2, text_key),
            kind = COALESCE(?3, kind),
            files = COALESCE(?4, files),
            pinned = COALESCE(?5, pinned),
            archived = COALESCE(?6, archived),
            project_id = CASE WHEN ?7 THEN ?8 ELSE project_id END,
            todo_id = CASE WHEN ?9 THEN ?10 ELSE todo_id END,
            updated_at = datetime('now')
         WHERE id = ?11",
        params![
            text,
            text.as_deref().map(text_key),
            req.kind.map(|k| k.as_str()),
            files,
            req.pinned,
            req.archived,
            req.project_id.is_some(),
            req.project_id.clone().flatten(),
            req.todo_id.is_some(),
            req.todo_id.clone().flatten(),
            id
        ],
    );
    match result {
        Ok(_) => {}
        Err(e) if is_constraint_violation(&e) => {
            return Err(MemoryError::Conflict("Another memory of this conversation already says this"));
        }
        Err(e) => return Err(e.into()),
    }
    let memory = load_memory(&tx, id)?.ok_or(MemoryError::NotFound("Memory not found"))?;
    tx.commit()?;
    Ok(memory)
}

/// Filters of `GET /api/memories`, parsed from the raw pairs so `kind` can repeat.
#[derive(Debug, Default)]
pub(crate) struct MemoryQuery {
    project_id: Option<String>,
    todo_id: Option<String>,
    kinds: Vec<MemoryKind>,
    since: Option<String>,
    tool: Option<String>,
    session_id: Option<String>,
    pinned: Option<bool>,
    include_archived: bool,
    limit: usize,
}

fn parse_bool(name: &str, value: &str) -> Result<bool, String> {
    match value {
        "true" | "1" => Ok(true),
        "false" | "0" => Ok(false),
        _ => Err(format!("{name} must be true or false")),
    }
}

impl MemoryQuery {
    pub(crate) fn parse(pairs: &[(String, String)]) -> Result<Self, String> {
        let mut q = MemoryQuery { limit: DEFAULT_LIMIT, ..Default::default() };
        for (name, value) in pairs {
            let value = value.trim();
            match name.as_str() {
                "project_id" => q.project_id = Some(value.to_string()),
                "todo_id" => q.todo_id = Some(value.to_string()),
                "tool" => q.tool = Some(value.to_string()),
                "session_id" => q.session_id = Some(value.to_string()),
                "since" => q.since = Some(value.to_string()),
                "kind" => {
                    for kind in value.split(',').map(str::trim).filter(|k| !k.is_empty()) {
                        q.kinds.push(MemoryKind::parse(kind).ok_or_else(|| format!("Invalid kind: {kind}"))?);
                    }
                }
                "pinned" => q.pinned = Some(parse_bool(name, value)?),
                "include_archived" => q.include_archived = parse_bool(name, value)?,
                "limit" => {
                    let limit: usize = value.parse().map_err(|_| "limit must be a number".to_string())?;
                    q.limit = limit.min(MAX_LIMIT);
                }
                _ => {}
            }
        }
        Ok(q)
    }
}

pub(crate) fn list_memories_db(conn: &Connection, q: &MemoryQuery) -> Result<Vec<Memory>, MemoryError> {
    let mut sql = format!("SELECT {MEMORY_COLS} FROM memories WHERE 1 = 1");
    let mut args: Vec<SqlValue> = Vec::new();
    let mut add = |clause: &str, value: SqlValue| {
        args.push(value);
        sql.push_str(&clause.replace('?', &format!("?{}", args.len())));
    };
    for (column, value) in [("project_id", &q.project_id), ("todo_id", &q.todo_id), ("tool", &q.tool), ("session_id", &q.session_id)] {
        if let Some(value) = value {
            add(&format!(" AND {column} = ?"), SqlValue::Text(value.clone()));
        }
    }
    if let Some(since) = &q.since {
        let valid: bool = conn.query_row("SELECT datetime(?1) IS NOT NULL", params![since], |r| r.get(0))?;
        if !valid {
            return Err(MemoryError::BadRequest("since must be a date (YYYY-MM-DD) or ISO 8601 time".into()));
        }
        add(" AND created_at >= datetime(?)", SqlValue::Text(since.clone()));
    }
    if let Some(pinned) = q.pinned {
        add(" AND pinned = ?", SqlValue::Integer(i64::from(pinned)));
    }
    if !q.kinds.is_empty() {
        let list = q.kinds.iter().map(|k| format!("'{}'", k.as_str())).collect::<Vec<_>>().join(",");
        sql.push_str(&format!(" AND kind IN ({list})"));
    }
    if !q.include_archived {
        sql.push_str(" AND archived = 0");
    }
    sql.push_str(&format!(
        " ORDER BY pinned DESC, created_at DESC, rowid DESC LIMIT {}",
        i64::try_from(q.limit).unwrap_or(i64::MAX)
    ));
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(args), row_to_memory)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn list_memories(pool: web::Data<DbPool>, query: web::Query<Vec<(String, String)>>) -> HttpResponse {
    let q = match MemoryQuery::parse(&query) {
        Ok(q) => q,
        Err(msg) => return bad_request(&msg),
    };
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match list_memories_db(&conn, &q) {
        Ok(memories) => HttpResponse::Ok().json(memories),
        Err(e) => memory_error_response(e),
    }
}

pub async fn create_memory(
    pool: web::Data<DbPool>,
    body: web::Json<CreateMemoryRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match create_memory_db(&conn, &body) {
        Ok(m) => {
            broadcaster.send();
            HttpResponse::Created().json(m)
        }
        Err(e) => memory_error_response(e),
    }
}

pub async fn bulk_memories(
    pool: web::Data<DbPool>,
    body: web::Json<BulkMemoriesRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match insert_bulk_db(&conn, &body) {
        Ok(resp) => {
            broadcaster.send();
            HttpResponse::Created().json(resp)
        }
        Err(e) => memory_error_response(e),
    }
}

pub async fn update_memory(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateMemoryRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match update_memory_db(&conn, &path.into_inner(), &body) {
        Ok(m) => {
            broadcaster.send();
            HttpResponse::Ok().json(m)
        }
        Err(e) => memory_error_response(e),
    }
}

pub async fn delete_memory(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match conn.execute("DELETE FROM memories WHERE id = ?1", params![id]) {
        Ok(0) => not_found("Memory not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: id })
        }
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};
    use todo_shared::{BulkMemoriesRequest, MemoryKind, NewMemory};

    use super::*;
    use crate::db::DbPool;
    use crate::test_support::{delete, get, insert_session, patch, pool, post, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES
                 ('pa', 'a', 'Si', '~/a'), ('pb', 'b', 'Si', '~/b'), ('ps', 'spread', 'Sp', '~/a');
             INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'linked'), ('t2', 'P', 'other');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
                 VALUES ('t1', 'mac', '~/a', 'claude', 'ai/claude/todo-t1', 's1');",
        )
        .unwrap();
    }

    fn mem(kind: MemoryKind, text: &str) -> NewMemory {
        NewMemory { kind, text: text.into(), files: vec![], confidence: Some(0.9), supersedes: vec![] }
    }

    fn bulk(computer: &str, session: &str, cwd: &str, memories: Vec<NewMemory>) -> BulkMemoriesRequest {
        BulkMemoriesRequest {
            computer_id: computer.into(),
            tool: "claude".into(),
            session_id: session.into(),
            cwd: cwd.into(),
            memories,
        }
    }

    fn texts(conn: &Connection, sql: &str) -> Vec<String> {
        let mut stmt = conn.prepare(sql).unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    const GOTCHA: &str = "The deploy script pulls latest so it must wait for the main pipeline build to finish first";

    #[test]
    fn text_key_normalizes_unicode_aware() {
        assert_eq!(text_key("  Use WAL-mode, always!  "), "use wal mode always");
        assert_eq!(text_key("Миграцията прави резервно копие."), "миграцията прави резервно копие");
        assert_eq!(text_key("Деплойът чака билда"), "деплойът чака билда");
        assert_eq!(text_key("tests 🎉 pass"), "tests pass");
        assert_eq!(text_key("a__b"), "a b");
        assert!((jaccard("a b c d", "a b c e") - 0.6).abs() < 1e-9);
        assert!((jaccard("A, B.", "b a") - 1.0).abs() < 1e-9);
    }

    #[actix_web::test]
    async fn bulk_creates_session_and_resolves_project_and_todo() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        let body = json!({"computer_id": "mac", "tool": "claude", "session_id": "s1", "cwd": "/Users/me/a/x",
            "memories": [{"kind": "decision", "text": "  Store stats per local day.  ", "files": ["src/db.rs"], "confidence": 0.85}]});
        let (status, resp) = post(&pool, "/api/memories/bulk", body).await;
        assert_eq!(status, StatusCode::CREATED, "{resp}");
        assert_eq!((&resp["project_id"], &resp["todo_id"], &resp["duplicates"]), (&json!("pa"), &json!("t1"), &json!(0)));
        assert_eq!(resp["archived"], json!([]));
        let m = &resp["inserted"][0];
        assert_eq!(m["text"], "Store stats per local day.");
        assert_eq!((&m["project_id"], &m["todo_id"], &m["computer_id"]), (&json!("pa"), &json!("t1"), &json!("mac")));
        assert_eq!((&m["tool"], &m["session_id"], &m["kind"]), (&json!("claude"), &json!("s1"), &json!("decision")));
        assert_eq!((&m["files"], &m["confidence"], &m["source"]), (&json!(["src/db.rs"]), &json!(0.85), &json!("extracted")));
        assert_eq!((&m["pinned"], &m["archived"]), (&json!(false), &json!(false)));

        // The minimal session row exists, with the cwd in ~ form and its project.
        let (cwd, project): (String, Option<String>) = conn
            .query_row("SELECT cwd, project_id FROM sessions WHERE tool = 'claude' AND session_id = 's1'", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((cwd.as_str(), project.as_deref()), ("~/a/x", Some("pa")));

        // An unknown computer is 404; an unknown session outside every project gets no project.
        let (status, _) = post(&pool, "/api/memories/bulk", json!({"computer_id": "nope", "tool": "claude",
            "session_id": "x", "cwd": "~/a", "memories": []})).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let resp = insert_bulk_db(&conn, &bulk("mac", "s9", "~/elsewhere", vec![mem(MemoryKind::Done, "Shipped it.")])).unwrap();
        assert_eq!((resp.project_id, resp.todo_id, resp.inserted.len()), (None, None, 1));
    }

    #[test]
    fn dedup_exact_across_sessions_of_project() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        let resp = insert_bulk_db(
            &conn,
            &bulk("mac", "s2", "~/a/sub", vec![mem(MemoryKind::Decision, "use  wal-mode"), mem(MemoryKind::Done, "New one.")]),
        )
        .unwrap();
        assert_eq!(resp.duplicates, 1, "same normalized text in the project, whatever the kind");
        assert_eq!(resp.inserted.len(), 1);
        assert_eq!(resp.inserted[0].text, "New one.");
        // Within one request too.
        let resp = insert_bulk_db(
            &conn,
            &bulk("mac", "s3", "~/a", vec![mem(MemoryKind::Done, "Twice."), mem(MemoryKind::Done, "twice")]),
        )
        .unwrap();
        assert_eq!((resp.inserted.len(), resp.duplicates), (1, 1));
    }

    #[test]
    fn dedup_fuzzy_same_kind_90_days() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, GOTCHA)])).unwrap();
        // One of 16 distinct words changed: Jaccard 15/17 ≈ 0.88 → duplicate.
        let close = GOTCHA.replace("finish", "complete");
        assert!(jaccard(GOTCHA, &close) >= 0.8);
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![mem(MemoryKind::Gotcha, &close)])).unwrap();
        assert_eq!((resp.inserted.len(), resp.duplicates), (0, 1));
        // The same near-copy under another kind is new.
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![mem(MemoryKind::Decision, &close)])).unwrap();
        assert_eq!((resp.inserted.len(), resp.duplicates), (1, 0));
        // 12 shared of 20 distinct words: Jaccard 0.6 → new.
        let far = "The deploy script pulls latest so it must wait for the main build; check page, retry later";
        assert!((jaccard(GOTCHA, far) - 0.6).abs() < 1e-9, "{}", jaccard(GOTCHA, far));
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![mem(MemoryKind::Gotcha, far)])).unwrap();
        assert_eq!(resp.inserted.len(), 1);
        // Memories older than 90 days don't count for fuzzy matches (exact ones still do).
        conn.execute("UPDATE memories SET created_at = datetime('now', '-91 days')", []).unwrap();
        let other_close = GOTCHA.replace("first", "beforehand");
        assert!(jaccard(GOTCHA, &other_close) >= 0.8);
        let resp = insert_bulk_db(&conn, &bulk("mac", "s3", "~/a", vec![mem(MemoryKind::Gotcha, &other_close)])).unwrap();
        assert_eq!(resp.inserted.len(), 1);
        let resp = insert_bulk_db(&conn, &bulk("mac", "s3", "~/a", vec![mem(MemoryKind::Gotcha, GOTCHA)])).unwrap();
        assert_eq!(resp.duplicates, 1);
    }

    #[test]
    fn dedup_not_across_projects() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/b", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        assert_eq!((resp.project_id.as_deref(), resp.inserted.len()), (Some("pb"), 1));
        let resp = insert_bulk_db(&conn, &bulk("spread", "s3", "~/a", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        assert_eq!((resp.project_id.as_deref(), resp.inserted.len()), (Some("ps"), 1), "same folder on another computer");
        // Without a project, dedup is per session only.
        let resp = insert_bulk_db(&conn, &bulk("mac", "s4", "~/none", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        assert_eq!(resp.inserted.len(), 1);
        let resp = insert_bulk_db(&conn, &bulk("mac", "s4", "~/none", vec![mem(MemoryKind::Gotcha, "use wal mode")])).unwrap();
        assert_eq!(resp.duplicates, 1);
    }

    #[test]
    fn nfd_and_nfc_share_text_key() {
        assert_eq!(text_key("Use the caf\u{e9} build"), text_key("Use the cafe\u{301} build"));
        assert_eq!(text_key("Use the cafe\u{301} build"), "use the caf\u{e9} build");
    }

    #[test]
    fn cyrillic_memories_are_not_duplicates() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        let resp = insert_bulk_db(
            &conn,
            &bulk(
                "mac",
                "s1",
                "~/a",
                vec![
                    mem(MemoryKind::Gotcha, "Миграцията прави резервно копие"),
                    mem(MemoryKind::Gotcha, "Деплойът чака билда"),
                ],
            ),
        )
        .unwrap();
        assert_eq!((resp.inserted.len(), resp.duplicates), (2, 0));
        for key in texts(&conn, "SELECT text_key FROM memories") {
            assert!(!key.trim().is_empty(), "{key:?}");
        }
    }

    #[test]
    fn archived_memory_still_blocks_duplicate() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "Use WAL mode.")])).unwrap();
        conn.execute("UPDATE memories SET archived = 1", []).unwrap();
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![mem(MemoryKind::Gotcha, "Use WAL mode!")])).unwrap();
        assert_eq!(resp.duplicates, 1);
    }

    #[test]
    fn supersedes_archives_unpinned_same_project_only() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        let first = insert_bulk_db(
            &conn,
            &bulk(
                "mac",
                "s1",
                "~/a",
                vec![mem(MemoryKind::OpenThread, "Decide the digest location."), mem(MemoryKind::OpenThread, "Pinned thread.")],
            ),
        )
        .unwrap();
        let (open, pinned) = (first.inserted[0].id.clone(), first.inserted[1].id.clone());
        conn.execute("UPDATE memories SET pinned = 1 WHERE id = ?1", [&pinned]).unwrap();
        let other = insert_bulk_db(&conn, &bulk("mac", "s5", "~/b", vec![mem(MemoryKind::OpenThread, "Other project.")])).unwrap();
        let other = other.inserted[0].id.clone();

        let mut done = mem(MemoryKind::Done, "Digest goes into CLAUDE.local.md.");
        done.supersedes = vec![open.clone(), pinned.clone(), other.clone(), "unknown".into(), open.clone()];
        // From another session of the same project.
        let resp = insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![done])).unwrap();
        assert_eq!(resp.archived, vec![open.clone()]);
        let archived = texts(&conn, "SELECT id FROM memories WHERE archived = 1");
        assert_eq!(archived, vec![open]);
    }

    #[actix_web::test]
    async fn validation() {
        let (_db, pool) = pool("mem");
        seed(&pool.get().unwrap());
        let send = |memory: Value| {
            let pool: DbPool = pool.clone();
            async move {
                post(&pool, "/api/memories/bulk", json!({"computer_id": "mac", "tool": "claude", "session_id": "s1",
                    "cwd": "~/a", "memories": [memory]}))
                .await
                .0
            }
        };
        assert_eq!(send(json!({"kind": "gotcha", "text": "x".repeat(401), "confidence": 0.9})).await, StatusCode::BAD_REQUEST);
        assert_eq!(send(json!({"kind": "gotcha", "text": "   ", "confidence": 0.9})).await, StatusCode::BAD_REQUEST);
        assert_eq!(send(json!({"kind": "gotcha", "text": "ж".repeat(400), "confidence": 0.9})).await, StatusCode::CREATED);
        assert_eq!(send(json!({"kind": "gotcha", "text": format!(" {} ", "y".repeat(400)), "confidence": 0.9})).await, StatusCode::CREATED, "trimmed first");
        let files: Vec<String> = (0..21).map(|i| format!("f{i}")).collect();
        assert_eq!(send(json!({"kind": "gotcha", "text": "Files.", "files": files, "confidence": 0.9})).await, StatusCode::BAD_REQUEST);
        assert_eq!(send(json!({"kind": "gotcha", "text": "Conf.", "confidence": 1.5})).await, StatusCode::BAD_REQUEST);
        assert_eq!(send(json!({"kind": "gotcha", "text": "Conf.", "confidence": -0.1})).await, StatusCode::BAD_REQUEST);
        assert_eq!(send(json!({"kind": "idea", "text": "Kind.", "confidence": 0.9})).await, StatusCode::BAD_REQUEST);
        let (status, _) = post(&pool, "/api/memories/bulk", json!({"computer_id": "mac", "tool": "vim", "session_id": "s1",
            "cwd": "~/a", "memories": []})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        // Nothing from a rejected request was written.
        let count: i64 = pool.get().unwrap().query_row("SELECT COUNT(*) FROM memories", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 2);
    }

    #[actix_web::test]
    async fn list_filters_and_order() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "G one."), mem(MemoryKind::Decision, "D one.")]))
            .unwrap();
        insert_bulk_db(&conn, &bulk("mac", "s2", "~/a", vec![mem(MemoryKind::Done, "Done one.")])).unwrap();
        insert_bulk_db(&conn, &bulk("mac", "s3", "~/b", vec![mem(MemoryKind::Gotcha, "Other project.")])).unwrap();
        conn.execute_batch(
            "UPDATE memories SET created_at = '2026-10-01 10:00:00' WHERE text = 'G one.';
             UPDATE memories SET created_at = '2026-10-02 10:00:00' WHERE text = 'D one.';
             UPDATE memories SET created_at = '2026-10-03 10:00:00', pinned = 0 WHERE text = 'Done one.';
             UPDATE memories SET created_at = '2026-10-04 10:00:00' WHERE text = 'Other project.';
             UPDATE memories SET pinned = 1 WHERE text = 'G one.';
             INSERT INTO memories (id, project_id, kind, text, text_key, archived, created_at)
                 VALUES ('arch', 'pa', 'gotcha', 'Archived.', 'archived', 1, '2026-10-05 10:00:00');",
        )
        .unwrap();
        let list = |query: &str| {
            let pool = pool.clone();
            let uri = format!("/api/memories{query}");
            async move {
                let (status, body) = get(&pool, &uri).await;
                assert_eq!(status, StatusCode::OK, "{uri}: {body}");
                body.as_array().unwrap().iter().map(|m| m["text"].as_str().unwrap().to_string()).collect::<Vec<_>>()
            }
        };
        assert_eq!(list("").await, vec!["G one.", "Other project.", "Done one.", "D one."], "pinned first, then newest");
        assert_eq!(list("?project_id=pa").await, vec!["G one.", "Done one.", "D one."]);
        assert_eq!(list("?project_id=pa&include_archived=true").await, vec!["G one.", "Archived.", "Done one.", "D one."]);
        assert_eq!(list("?todo_id=t1").await, vec!["G one.", "D one."]);
        assert_eq!(list("?kind=gotcha,decision&project_id=pa").await, vec!["G one.", "D one."]);
        assert_eq!(list("?kind=gotcha&kind=done&project_id=pa").await, vec!["G one.", "Done one."]);
        assert_eq!(list("?since=2026-10-02").await, vec!["Other project.", "Done one.", "D one."]);
        assert_eq!(list("?since=2026-10-03T00:00:00Z").await, vec!["Other project.", "Done one."]);
        assert_eq!(list("?tool=claude&session_id=s2").await, vec!["Done one."]);
        assert_eq!(list("?pinned=true").await, vec!["G one."]);
        assert_eq!(list("?pinned=false&project_id=pa").await, vec!["Done one.", "D one."]);
        assert_eq!(list("?limit=2").await.len(), 2);
        assert_eq!(get(&pool, "/api/memories?kind=idea").await.0, StatusCode::BAD_REQUEST);
        assert_eq!(get(&pool, "/api/memories?since=yesterday").await.0, StatusCode::BAD_REQUEST);
        assert_eq!(get(&pool, "/api/memories?limit=x").await.0, StatusCode::BAD_REQUEST);
        assert_eq!(get(&pool, "/api/memories?pinned=maybe").await.0, StatusCode::BAD_REQUEST);

        // The limit is capped at 1000.
        conn.execute_batch(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1100)
             INSERT INTO memories (id, project_id, kind, text, text_key) SELECT 'bulk-' || i, 'pb', 'done', 'x' || i, 'x' || i FROM n;",
        )
        .unwrap();
        assert_eq!(list("?limit=5000").await.len(), 1000);
        assert_eq!(list("").await.len(), 200, "default limit");
    }

    #[actix_web::test]
    async fn patch_rekeys_and_conflicts() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        let resp = insert_bulk_db(
            &conn,
            &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "First."), mem(MemoryKind::Gotcha, "Second.")]),
        )
        .unwrap();
        let (first, second) = (&resp.inserted[0].id, &resp.inserted[1].id);

        let (status, body) = patch(&pool, &format!("/api/memories/{second}"), json!({"text": " FIRST! "})).await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        let (status, body) = patch(&pool, &format!("/api/memories/{second}"), json!({"text": "Second, edited."})).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["text"], "Second, edited.");
        let key: String = conn.query_row("SELECT text_key FROM memories WHERE id = ?1", [second], |r| r.get(0)).unwrap();
        assert_eq!(key, "second edited");

        let (status, body) = patch(
            &pool,
            &format!("/api/memories/{first}"),
            json!({"kind": "decision", "files": ["a.rs"], "pinned": true, "archived": true, "todo_id": null, "project_id": "pb"}),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!((&body["kind"], &body["files"], &body["pinned"], &body["archived"]),
                   (&json!("decision"), &json!(["a.rs"]), &json!(true), &json!(true)));
        assert_eq!((&body["todo_id"], &body["project_id"], &body["text"]), (&Value::Null, &json!("pb"), &json!("First.")));
        let (_, body) = patch(&pool, &format!("/api/memories/{first}"), json!({"project_id": null, "todo_id": "t2"})).await;
        assert_eq!((&body["project_id"], &body["todo_id"]), (&Value::Null, &json!("t2")));

        assert_eq!(patch(&pool, &format!("/api/memories/{first}"), json!({"project_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(patch(&pool, &format!("/api/memories/{first}"), json!({"todo_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(patch(&pool, &format!("/api/memories/{first}"), json!({"text": ""})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(patch(&pool, "/api/memories/missing", json!({"pinned": true})).await.0, StatusCode::NOT_FOUND);

        let (status, body) = delete(&pool, &format!("/api/memories/{first}")).await;
        assert_eq!((status, body), (StatusCode::OK, json!({"deleted": first})));
        assert_eq!(delete(&pool, &format!("/api/memories/{first}")).await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn manual_create_requires_scope_and_inherits_todo_project() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE todos SET project_id = 'pb' WHERE id = 't2'", []).unwrap();

        let (status, _) = post(&pool, "/api/memories", json!({"kind": "gotcha", "text": "No scope."})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, m) = post(&pool, "/api/memories", json!({"kind": "gotcha", "text": "From todo.", "todo_id": "t2"})).await;
        assert_eq!(status, StatusCode::CREATED, "{m}");
        assert_eq!((&m["project_id"], &m["todo_id"], &m["source"]), (&json!("pb"), &json!("t2"), &json!("manual")));
        assert_eq!((&m["tool"], &m["session_id"], &m["confidence"], &m["computer_id"]), (&Value::Null, &Value::Null, &Value::Null, &Value::Null));
        let (_, m) = post(&pool, "/api/memories", json!({"kind": "decision", "text": "Explicit.", "todo_id": "t2", "project_id": "pa", "pinned": true, "files": ["x"]})).await;
        assert_eq!((&m["project_id"], &m["pinned"], &m["files"]), (&json!("pa"), &json!(true), &json!(["x"])));
        let (_, m) = post(&pool, "/api/memories", json!({"kind": "done", "text": "Todo without project.", "todo_id": "t1"})).await;
        assert!(m["project_id"].is_null());
        let (status, m) = post(&pool, "/api/memories", json!({"kind": "done", "text": "Project only.", "project_id": "pa"})).await;
        assert_eq!((status, &m["todo_id"]), (StatusCode::CREATED, &Value::Null));
        assert_eq!(post(&pool, "/api/memories", json!({"kind": "done", "text": "x", "project_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(post(&pool, "/api/memories", json!({"kind": "done", "text": "x", "todo_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(post(&pool, "/api/memories", json!({"kind": "done", "text": "", "project_id": "pa"})).await.0, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn todo_delete_nulls_memory_todo_id() {
        let (_db, pool) = pool("mem");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_session(&conn, "mac", "claude", "s1", "~/a");
        conn.execute("UPDATE sessions SET project_id = 'pa'", []).unwrap();
        let resp = insert_bulk_db(&conn, &bulk("mac", "s1", "~/a", vec![mem(MemoryKind::Gotcha, "Kept.")])).unwrap();
        assert_eq!(resp.todo_id.as_deref(), Some("t1"));
        assert_eq!(delete(&pool, "/api/todos/t1").await.0, StatusCode::OK);
        let (todo, project): (Option<String>, Option<String>) =
            conn.query_row("SELECT todo_id, project_id FROM memories", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((todo, project.as_deref()), (None, Some("pa")));
    }
}
