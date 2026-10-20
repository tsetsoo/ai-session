//! Sessions: Claude/Codex conversations known from a computer's transcripts, whether or
//! not a todo links them, with their usage stats (per conversation and per local day),
//! the app's project overrides, and the weekly rollup.
//!
//! Computers compute the numbers; the server only stores and sums them.

use std::collections::BTreeMap;

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use todo_shared::{
    ComputerRollup, ConversationStatus, ProjectRollup, Section, SectionRollup, Session, SessionProjectRef,
    SessionStatsResponse, SessionStatsUpload, SetSessionProjectRequest, StatsCounters, WeeklyStats,
};

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, conflict, get_computer, not_found, server_error, SUPPORTED_TOOLS};
use crate::daily::valid_date;
use crate::db::DbPool;
use crate::paths;
use crate::projects::{assign_session_project, project_for};

const MAX_FILES_TOUCHED: usize = 200;
const MAX_TITLE_CHARS: usize = 120;
const DEFAULT_LIMIT: usize = 200;
const MAX_LIMIT: usize = 1000;

/// Session columns (0..=21), then the linked todo's id and conversation status (22, 23).
const SESSION_SELECT: &str = "SELECT s.tool, s.session_id, s.computer_id, s.cwd, s.title, s.repo_root, s.repo_url,
        s.project_id, s.project_override, s.prompts, s.assistant_turns, s.input_tokens, s.output_tokens,
        s.cache_read_tokens, s.cache_creation_tokens, s.active_seconds, s.first_activity, s.last_activity,
        s.files_touched, s.models, s.stats_updated_at, s.created_at, c.todo_id, c.status
     FROM sessions s LEFT JOIN conversations c ON c.tool = s.tool AND c.session_id = s.session_id";

fn json_list(text: &str) -> Vec<String> {
    serde_json::from_str(text).unwrap_or_default()
}

fn row_to_session(row: &Row) -> rusqlite::Result<Session> {
    let status: Option<String> = row.get(23)?;
    Ok(Session {
        tool: row.get(0)?,
        session_id: row.get(1)?,
        computer_id: row.get(2)?,
        cwd: row.get(3)?,
        title: row.get(4)?,
        repo_root: row.get(5)?,
        repo_url: row.get(6)?,
        project_id: row.get(7)?,
        project_override: row.get::<_, i64>(8)? != 0,
        prompts: row.get(9)?,
        assistant_turns: row.get(10)?,
        input_tokens: row.get(11)?,
        output_tokens: row.get(12)?,
        cache_read_tokens: row.get(13)?,
        cache_creation_tokens: row.get(14)?,
        active_seconds: row.get(15)?,
        first_activity: row.get(16)?,
        last_activity: row.get(17)?,
        files_touched: json_list(&row.get::<_, String>(18)?),
        models: json_list(&row.get::<_, String>(19)?),
        stats_updated_at: row.get(20)?,
        created_at: row.get(21)?,
        todo_id: row.get(22)?,
        status: status.as_deref().and_then(ConversationStatus::parse),
    })
}

pub(crate) fn load_session(conn: &Connection, tool: &str, session_id: &str) -> rusqlite::Result<Option<Session>> {
    conn.query_row(
        &format!("{SESSION_SELECT} WHERE s.tool = ?1 AND s.session_id = ?2"),
        params![tool, session_id],
        row_to_session,
    )
    .optional()
}

#[derive(Debug)]
pub(crate) enum SessionError {
    BadRequest(String),
    NotFound(&'static str),
    Conflict(String),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for SessionError {
    fn from(e: rusqlite::Error) -> Self {
        SessionError::Db(e)
    }
}

fn session_error_response(e: SessionError) -> HttpResponse {
    match e {
        SessionError::BadRequest(msg) => bad_request(&msg),
        SessionError::NotFound(msg) => not_found(msg),
        SessionError::Conflict(msg) => conflict(msg),
        SessionError::Db(e) => server_error(e),
    }
}

/// The computer's username, for normalizing paths to their `~` form.
pub(crate) fn username_of(conn: &Connection, computer_id: &str) -> rusqlite::Result<String> {
    Ok(conn
        .query_row("SELECT username FROM computers WHERE id = ?1", params![computer_id], |r| r.get(0))
        .optional()?
        .unwrap_or_default())
}

/// Make sure a session row exists (a minimal one: cwd only, matched to a project) and
/// return its project. An existing row is left as it is.
pub(crate) fn ensure_session_db(
    conn: &Connection,
    computer_id: &str,
    tool: &str,
    session_id: &str,
    cwd: &str,
) -> rusqlite::Result<Option<String>> {
    let existing: Option<Option<String>> = conn
        .query_row(
            "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(project_id) = existing {
        return Ok(project_id);
    }
    let cwd = paths::normalize(cwd, &username_of(conn, computer_id)?);
    let project_id = project_for(conn, computer_id, &cwd)?;
    conn.execute(
        "INSERT INTO sessions (tool, session_id, computer_id, cwd, project_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![tool, session_id, computer_id, cwd, project_id],
    )?;
    Ok(project_id)
}

/// Upsert the stats of a computer's sessions, in one IMMEDIATE transaction. The numbers
/// are a full recompute per transcript, so uploading the same thing twice changes nothing;
/// `days` replaces all of a session's day rows. Sessions without a project override are
/// matched again (their cwd may have moved); an override is kept.
pub(crate) fn upload_stats_db(conn: &Connection, upload: &SessionStatsUpload) -> Result<Vec<SessionProjectRef>, SessionError> {
    for s in &upload.sessions {
        if !SUPPORTED_TOOLS.contains(&s.tool.trim()) {
            return Err(SessionError::BadRequest(format!("Unsupported tool: {}", s.tool)));
        }
        if s.session_id.trim().is_empty() || s.session_id.trim().chars().any(char::is_whitespace) {
            return Err(SessionError::BadRequest("session_id is required (no spaces)".into()));
        }
        if s.cwd.trim().is_empty() {
            return Err(SessionError::BadRequest("cwd is required".into()));
        }
        if let Some(d) = s.days.iter().find(|d| !valid_date(&d.day)) {
            return Err(SessionError::BadRequest(format!("Invalid day: {} (YYYY-MM-DD)", d.day)));
        }
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let computer_id = upload.computer_id.trim();
    let Some(computer) = get_computer(&tx, computer_id)? else {
        return Err(SessionError::NotFound("Computer not found"));
    };
    let mut result = Vec::with_capacity(upload.sessions.len());
    for s in &upload.sessions {
        let (tool, session_id) = (s.tool.trim(), s.session_id.trim());
        let cwd = paths::normalize(&s.cwd, &computer.username);
        let repo_root = s.repo_root.as_deref().map(|r| paths::normalize(r, &computer.username));
        let title = s.title.as_deref().map(|t| t.trim().chars().take(MAX_TITLE_CHARS).collect::<String>());
        let files: Vec<&String> = s.stats.files_touched.iter().take(MAX_FILES_TOUCHED).collect();
        let st = &s.stats;
        tx.execute(
            "INSERT INTO sessions (tool, session_id, computer_id, cwd, title, repo_root, repo_url, prompts, assistant_turns,
                                   input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, active_seconds,
                                   first_activity, last_activity, files_touched, models, stats_updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, datetime('now'))
             ON CONFLICT(tool, session_id) DO UPDATE SET
                computer_id = excluded.computer_id, cwd = excluded.cwd,
                title = COALESCE(excluded.title, title), repo_root = COALESCE(excluded.repo_root, repo_root),
                repo_url = COALESCE(excluded.repo_url, repo_url),
                prompts = excluded.prompts, assistant_turns = excluded.assistant_turns,
                input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens,
                cache_read_tokens = excluded.cache_read_tokens, cache_creation_tokens = excluded.cache_creation_tokens,
                active_seconds = excluded.active_seconds, first_activity = excluded.first_activity,
                last_activity = excluded.last_activity, files_touched = excluded.files_touched,
                models = excluded.models, stats_updated_at = excluded.stats_updated_at",
            params![
                tool,
                session_id,
                computer_id,
                cwd,
                title,
                repo_root,
                s.repo_url.as_deref().map(str::trim).filter(|u| !u.is_empty()),
                st.prompts,
                st.assistant_turns,
                st.input_tokens,
                st.output_tokens,
                st.cache_read_tokens,
                st.cache_creation_tokens,
                st.active_seconds,
                st.first_activity,
                st.last_activity,
                serde_json::to_string(&files).unwrap_or_else(|_| "[]".into()),
                serde_json::to_string(&st.models).unwrap_or_else(|_| "[]".into()),
            ],
        )?;
        let overridden: bool = tx.query_row(
            "SELECT project_override FROM sessions WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get::<_, i64>(0).map(|o| o != 0),
        )?;
        if !overridden {
            let project_id = project_for(&tx, computer_id, &cwd)?;
            assign_session_project(&tx, tool, session_id, project_id.as_deref(), false)?;
        }
        tx.execute("DELETE FROM session_days WHERE tool = ?1 AND session_id = ?2", params![tool, session_id])?;
        for d in &s.days {
            tx.execute(
                "INSERT INTO session_days (tool, session_id, day, prompts, assistant_turns, input_tokens, output_tokens,
                                           cache_read_tokens, cache_creation_tokens, active_seconds, files_touched)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(tool, session_id, day) DO UPDATE SET
                    prompts = excluded.prompts, assistant_turns = excluded.assistant_turns,
                    input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens,
                    cache_read_tokens = excluded.cache_read_tokens, cache_creation_tokens = excluded.cache_creation_tokens,
                    active_seconds = excluded.active_seconds, files_touched = excluded.files_touched",
                params![
                    tool,
                    session_id,
                    d.day,
                    d.prompts,
                    d.assistant_turns,
                    d.input_tokens,
                    d.output_tokens,
                    d.cache_read_tokens,
                    d.cache_creation_tokens,
                    d.active_seconds,
                    d.files_touched
                ],
            )?;
        }
        let project_id: Option<String> = tx.query_row(
            "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get(0),
        )?;
        result.push(SessionProjectRef { tool: tool.to_string(), session_id: session_id.to_string(), project_id });
    }
    tx.commit()?;
    Ok(result)
}

/// Set (`project_id`), clear to none (`project_id: null`) or remove (`auto`) a session's
/// project override. Memories of the session move with it.
pub(crate) fn set_session_project_db(
    conn: &Connection,
    tool: &str,
    session_id: &str,
    req: &SetSessionProjectRequest,
) -> Result<Session, SessionError> {
    let auto = req.auto == Some(true);
    if auto == req.project_id.is_some() {
        return Err(SessionError::BadRequest(r#"Send either {"project_id": "<id>" or null} or {"auto": true}"#.into()));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let session = load_session(&tx, tool, session_id)?.ok_or(SessionError::NotFound("Session not found"))?;
    match &req.project_id {
        None => {
            let project_id = project_for(&tx, &session.computer_id, &session.cwd)?;
            assign_session_project(&tx, tool, session_id, project_id.as_deref(), false)?;
        }
        Some(None) => assign_session_project(&tx, tool, session_id, None, true)?,
        Some(Some(project_id)) => {
            let (computer_id, name): (String, String) = tx
                .query_row(
                    "SELECT sc.computer_id, p.name FROM projects p
                     JOIN section_computers sc ON sc.section = p.section
                     WHERE p.id = ?1",
                    params![project_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?
                .ok_or(SessionError::NotFound("Project not found"))?;
            if computer_id != session.computer_id {
                return Err(SessionError::Conflict(format!(
                    "Project {name} is on another computer than this conversation"
                )));
            }
            assign_session_project(&tx, tool, session_id, Some(project_id), true)?;
        }
    }
    let session = load_session(&tx, tool, session_id)?.ok_or(SessionError::NotFound("Session not found"))?;
    tx.commit()?;
    Ok(session)
}

#[derive(Debug, serde::Deserialize)]
pub struct SessionsQuery {
    pub project_id: Option<String>,
    pub computer_id: Option<String>,
    /// `last_activity` at or after this date / ISO 8601 time
    pub since: Option<String>,
    pub limit: Option<usize>,
}

pub(crate) fn list_sessions_db(conn: &Connection, q: &SessionsQuery) -> Result<Vec<Session>, SessionError> {
    if let Some(since) = &q.since {
        let valid: bool = conn.query_row("SELECT datetime(?1) IS NOT NULL", params![since], |r| r.get(0))?;
        if !valid {
            return Err(SessionError::BadRequest("since must be a date (YYYY-MM-DD) or ISO 8601 time".into()));
        }
    }
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).min(MAX_LIMIT);
    let mut stmt = conn.prepare(&format!(
        "{SESSION_SELECT}
         WHERE (?1 IS NULL OR s.project_id = ?1) AND (?2 IS NULL OR s.computer_id = ?2)
           AND (?3 IS NULL OR datetime(s.last_activity) >= datetime(?3))
         ORDER BY s.last_activity IS NULL, datetime(s.last_activity) DESC, s.created_at DESC
         LIMIT ?4"
    ))?;
    let rows = stmt.query_map(
        params![q.project_id, q.computer_id, q.since, i64::try_from(limit).unwrap_or(i64::MAX)],
        row_to_session,
    )?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn add_opt(total: &mut Option<i64>, value: Option<i64>) {
    if let Some(value) = value {
        *total = Some(total.unwrap_or(0) + value);
    }
}

impl SessionWeek {
    fn add_to(&self, c: &mut StatsCounters) {
        c.sessions += self.counters.sessions;
        c.prompts += self.counters.prompts;
        c.assistant_turns += self.counters.assistant_turns;
        add_opt(&mut c.input_tokens, self.counters.input_tokens);
        add_opt(&mut c.output_tokens, self.counters.output_tokens);
        add_opt(&mut c.cache_read_tokens, self.counters.cache_read_tokens);
        add_opt(&mut c.cache_creation_tokens, self.counters.cache_creation_tokens);
        c.active_seconds += self.counters.active_seconds;
        c.files_touched += self.counters.files_touched;
    }
}

/// One session's sums over the week's days, with what it is grouped by.
struct SessionWeek {
    project: Option<(String, String)>,
    computer: (String, String),
    section: Option<Section>,
    counters: StatsCounters,
}

/// The week's Monday and Sunday: `week_start` when it is a valid Monday, else a 400;
/// without one, the Monday of the server's local today.
fn week_bounds(conn: &Connection, week_start: Option<&str>) -> Result<(String, String), SessionError> {
    let start: String = match week_start {
        Some(start) => {
            let monday: Option<bool> = conn.query_row(
                "SELECT date(?1) = ?1 AND strftime('%w', ?1) = '1'",
                params![start],
                |r| r.get(0),
            )?;
            if monday != Some(true) {
                return Err(SessionError::BadRequest("week_start must be a Monday (YYYY-MM-DD)".into()));
            }
            start.to_string()
        }
        None => conn.query_row("SELECT date('now', 'localtime', 'weekday 0', '-6 days')", [], |r| r.get(0))?,
    };
    let end: String = conn.query_row("SELECT date(?1, '+6 days')", params![start], |r| r.get(0))?;
    Ok((start, end))
}

/// Usage of one week, summed from the day rows, overall and by project, section and computer.
///
/// A session's section is its linked todo's section; otherwise the single section mapped to
/// its computer; otherwise none (a computer serving several sections is ambiguous).
pub(crate) fn weekly_db(conn: &Connection, week_start: Option<&str>, project_id: Option<&str>) -> Result<WeeklyStats, SessionError> {
    let (start, end) = week_bounds(conn, week_start)?;

    let mut computer_sections: BTreeMap<String, Vec<Section>> = BTreeMap::new();
    {
        let mut stmt = conn.prepare("SELECT computer_id, section FROM section_computers")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (computer_id, section) = row?;
            if let Some(section) = Section::parse(&section) {
                computer_sections.entry(computer_id).or_default().push(section);
            }
        }
    }

    let mut stmt = conn.prepare(
        "SELECT s.project_id, p.name, s.computer_id, m.name,
                (SELECT t.section FROM conversations c JOIN todos t ON t.id = c.todo_id
                 WHERE c.tool = s.tool AND c.session_id = s.session_id),
                SUM(d.prompts), SUM(d.assistant_turns), SUM(d.input_tokens), SUM(d.output_tokens),
                SUM(d.cache_read_tokens), SUM(d.cache_creation_tokens), SUM(d.active_seconds), SUM(d.files_touched)
         FROM session_days d
         JOIN sessions s ON s.tool = d.tool AND s.session_id = d.session_id
         JOIN computers m ON m.id = s.computer_id
         LEFT JOIN projects p ON p.id = s.project_id
         WHERE d.day >= ?1 AND d.day <= ?2 AND (?3 IS NULL OR s.project_id = ?3)
         GROUP BY s.tool, s.session_id",
    )?;
    let weeks = stmt.query_map(params![start, end, project_id], |r| {
        let project_id: Option<String> = r.get(0)?;
        let project_name: Option<String> = r.get(1)?;
        let computer_id: String = r.get(2)?;
        let linked_section: Option<String> = r.get(4)?;
        let section = match linked_section.as_deref().and_then(Section::parse) {
            Some(section) => Some(section),
            None => match computer_sections.get(&computer_id).map(Vec::as_slice) {
                Some([only]) => Some(*only),
                _ => None,
            },
        };
        Ok(SessionWeek {
            project: project_id.map(|id| (id, project_name.unwrap_or_default())),
            computer: (computer_id, r.get(3)?),
            section,
            counters: StatsCounters {
                sessions: 1,
                prompts: r.get(5)?,
                assistant_turns: r.get(6)?,
                input_tokens: r.get(7)?,
                output_tokens: r.get(8)?,
                cache_read_tokens: r.get(9)?,
                cache_creation_tokens: r.get(10)?,
                active_seconds: r.get(11)?,
                files_touched: r.get(12)?,
            },
        })
    })?;

    let mut totals = StatsCounters::default();
    // Keys sort the groups: projects by name (no project last), sections in code order
    // (none last), computers by name.
    let mut by_project: BTreeMap<(bool, String, String), ProjectRollup> = BTreeMap::new();
    let mut by_section: BTreeMap<usize, SectionRollup> = BTreeMap::new();
    let mut by_computer: BTreeMap<(String, String), ComputerRollup> = BTreeMap::new();
    for week in weeks {
        let week = week?;
        week.add_to(&mut totals);
        let (pid, pname) = week.project.clone().map_or((None, None), |(id, name)| (Some(id), Some(name)));
        let key = (pid.is_none(), pname.clone().unwrap_or_default().to_lowercase(), pid.clone().unwrap_or_default());
        let project = by_project
            .entry(key)
            .or_insert_with(|| ProjectRollup { project_id: pid, name: pname, counters: StatsCounters::default() });
        week.add_to(&mut project.counters);
        let order = week.section.map_or(Section::all().len(), |s| Section::all().iter().position(|x| *x == s).unwrap_or(0));
        let section = by_section
            .entry(order)
            .or_insert_with(|| SectionRollup { section: week.section, counters: StatsCounters::default() });
        week.add_to(&mut section.counters);
        let (cid, cname) = week.computer.clone();
        let computer = by_computer.entry((cname.to_lowercase(), cid.clone())).or_insert_with(|| ComputerRollup {
            computer_id: cid,
            name: cname,
            counters: StatsCounters::default(),
        });
        week.add_to(&mut computer.counters);
    }
    Ok(WeeklyStats {
        week_start: start,
        week_end: end,
        totals,
        by_project: by_project.into_values().collect(),
        by_section: by_section.into_values().collect(),
        by_computer: by_computer.into_values().collect(),
    })
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn upload_stats(
    pool: web::Data<DbPool>,
    body: web::Json<SessionStatsUpload>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match upload_stats_db(&conn, &body) {
        Ok(sessions) => {
            broadcaster.send();
            HttpResponse::Ok().json(SessionStatsResponse { upserted: sessions.len(), sessions })
        }
        Err(e) => session_error_response(e),
    }
}

pub async fn list_sessions(pool: web::Data<DbPool>, query: web::Query<SessionsQuery>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match list_sessions_db(&conn, &query) {
        Ok(sessions) => HttpResponse::Ok().json(sessions),
        Err(e) => session_error_response(e),
    }
}

pub async fn set_session_project(
    pool: web::Data<DbPool>,
    path: web::Path<(String, String)>,
    body: web::Json<SetSessionProjectRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let (tool, session_id) = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match set_session_project_db(&conn, &tool, &session_id, &body) {
        Ok(session) => {
            broadcaster.send();
            HttpResponse::Ok().json(session)
        }
        Err(e) => session_error_response(e),
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct WeeklyQuery {
    pub week_start: Option<String>,
    pub project_id: Option<String>,
}

pub async fn weekly_stats(pool: web::Data<DbPool>, query: web::Query<WeeklyQuery>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match weekly_db(&conn, query.week_start.as_deref(), query.project_id.as_deref()) {
        Ok(stats) => HttpResponse::Ok().json(stats),
        Err(e) => session_error_response(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};

    use crate::db::DbPool;
    use crate::test_support::{get, pool, post, put, seed_computers, session_project};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES
                 ('pa', 'a', 'Si', '~/a'), ('pb', 'b', 'Si', '~/b'), ('ps', 'spread-a', 'Sp', '~/a');",
        )
        .unwrap();
    }

    fn day(day: &str, prompts: i64, input: Option<i64>, active: i64, files: i64) -> Value {
        json!({"day": day, "prompts": prompts, "assistant_turns": prompts, "input_tokens": input, "output_tokens": input,
               "cache_read_tokens": input, "cache_creation_tokens": null, "active_seconds": active, "files_touched": files})
    }

    fn upload_body(computer: &str, session: &str, cwd: &str, days: Vec<Value>) -> Value {
        json!({"computer_id": computer, "sessions": [{
            "tool": "claude", "session_id": session, "cwd": cwd, "title": "Add projects",
            "repo_root": "/Users/me/a", "repo_url": "git@github.com:tsetsoo/todo-app.git",
            "stats": {"prompts": 12, "assistant_turns": 11, "input_tokens": 4021, "output_tokens": 51234,
                      "cache_read_tokens": 9_123_456, "cache_creation_tokens": 402_311, "active_seconds": 5400,
                      "first_activity": "2026-10-16T07:01:12Z", "last_activity": "2026-10-16T09:12:03Z",
                      "files_touched": ["crates/todo-server/src/db.rs"], "models": ["claude-opus-5-5"]},
            "days": days}]})
    }

    async fn upload(pool: &DbPool, body: Value) -> Value {
        let (status, resp) = post(pool, "/api/sessions/stats", body).await;
        assert_eq!(status, StatusCode::OK, "{resp}");
        resp
    }

    fn snapshot(conn: &Connection) -> Vec<String> {
        let mut stmt = conn
            .prepare(
                "SELECT s.tool || s.session_id || s.cwd || IFNULL(s.title, '') || IFNULL(s.repo_root, '') || IFNULL(s.project_id, '')
                        || s.prompts || s.assistant_turns || IFNULL(s.input_tokens, 'n') || IFNULL(s.cache_creation_tokens, 'n')
                        || s.active_seconds || IFNULL(s.last_activity, '') || s.files_touched || s.models
                 FROM sessions s
                 UNION ALL
                 SELECT d.session_id || d.day || d.prompts || IFNULL(d.input_tokens, 'n') || d.active_seconds || d.files_touched
                 FROM session_days d ORDER BY 1",
            )
            .unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    #[actix_web::test]
    async fn upload_is_idempotent_and_replaces_days() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        let days = vec![day("2026-10-15", 5, Some(10), 100, 1), day("2026-10-16", 7, None, 200, 2)];
        let resp = upload(&pool, upload_body("mac", "s1", "/Users/me/a/x/", days.clone())).await;
        assert_eq!(resp, json!({"upserted": 1, "sessions": [{"tool": "claude", "session_id": "s1", "project_id": "pa"}]}));
        let first = snapshot(&conn);
        assert_eq!(first.len(), 3);
        upload(&pool, upload_body("mac", "s1", "/Users/me/a/x/", days)).await;
        assert_eq!(snapshot(&conn), first, "the same upload twice gives the same rows");

        let (cwd, root, files, models): (String, String, String, String) = conn
            .query_row("SELECT cwd, repo_root, files_touched, models FROM sessions", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .unwrap();
        assert_eq!((cwd.as_str(), root.as_str()), ("~/a/x", "~/a"), "paths are stored in their ~ form");
        assert_eq!(serde_json::from_str::<Vec<String>>(&files).unwrap(), vec!["crates/todo-server/src/db.rs"]);
        assert_eq!(serde_json::from_str::<Vec<String>>(&models).unwrap(), vec!["claude-opus-5-5"]);

        // A day missing from the next upload is deleted.
        upload(&pool, upload_body("mac", "s1", "~/a/x", vec![day("2026-10-16", 8, Some(3), 250, 2)])).await;
        let days: Vec<(String, i64)> = conn
            .prepare("SELECT day, prompts FROM session_days")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(days, vec![("2026-10-16".to_string(), 8)]);

        // Moving the session's cwd re-matches it.
        let resp = upload(&pool, upload_body("mac", "s1", "~/b", vec![])).await;
        assert_eq!(resp["sessions"][0]["project_id"], "pb");

        // Files are capped at 200; a title at 120 characters.
        let mut body = upload_body("mac", "s2", "~/a", vec![]);
        body["sessions"][0]["stats"]["files_touched"] = json!((0..250).map(|i| format!("f{i}")).collect::<Vec<_>>());
        body["sessions"][0]["title"] = json!("ж".repeat(130));
        upload(&pool, body).await;
        let (files, title): (String, String) = conn
            .query_row("SELECT files_touched, title FROM sessions WHERE session_id = 's2'", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert_eq!(serde_json::from_str::<Vec<String>>(&files).unwrap().len(), 200);
        assert_eq!(title.chars().count(), 120);
    }

    #[actix_web::test]
    async fn upload_validates() {
        let (_db, pool) = pool("sess");
        seed(&pool.get().unwrap());
        let mut bad_day = upload_body("mac", "s1", "~/a", vec![day("2026-13-01", 1, None, 0, 0)]);
        assert_eq!(post(&pool, "/api/sessions/stats", bad_day.clone()).await.0, StatusCode::BAD_REQUEST);
        bad_day["sessions"][0]["days"] = json!([]);
        bad_day["sessions"][0]["tool"] = json!("vim");
        assert_eq!(post(&pool, "/api/sessions/stats", bad_day.clone()).await.0, StatusCode::BAD_REQUEST);
        bad_day["sessions"][0]["tool"] = json!("codex");
        bad_day["sessions"][0]["cwd"] = json!(" ");
        assert_eq!(post(&pool, "/api/sessions/stats", bad_day).await.0, StatusCode::BAD_REQUEST);
        let count: i64 = pool.get().unwrap().query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0)).unwrap();
        assert_eq!(count, 0);
    }

    #[actix_web::test]
    async fn unknown_computer_is_404() {
        let (_db, pool) = pool("sess");
        seed(&pool.get().unwrap());
        let (status, body) = post(&pool, "/api/sessions/stats", upload_body("nope", "s1", "~/a", vec![])).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
        assert_eq!(body["error"], "Computer not found");
    }

    #[actix_web::test]
    async fn upload_keeps_override() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        upload(&pool, upload_body("mac", "s1", "~/a", vec![])).await;
        let (status, body) = put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": "pb"})).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let resp = upload(&pool, upload_body("mac", "s1", "~/a", vec![])).await;
        assert_eq!(resp["sessions"][0]["project_id"], "pb", "the override's project is kept");
        put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": null})).await;
        let resp = upload(&pool, upload_body("mac", "s1", "~/a", vec![])).await;
        assert!(resp["sessions"][0]["project_id"].is_null(), "an override to no project is kept: {resp}");
    }

    #[actix_web::test]
    async fn override_set_null_auto() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        upload(&pool, upload_body("mac", "s1", "~/a/x", vec![])).await;
        crate::memories::insert_bulk_db(
            &conn,
            &serde_json::from_value(json!({"computer_id": "mac", "tool": "claude", "session_id": "s1", "cwd": "~/a/x",
                "memories": [{"kind": "gotcha", "text": "Moves along.", "confidence": 0.9}]}))
            .unwrap(),
        )
        .unwrap();
        let memory_project = |conn: &Connection| -> Option<String> {
            conn.query_row("SELECT project_id FROM memories", [], |r| r.get(0)).unwrap()
        };
        assert_eq!(memory_project(&conn).as_deref(), Some("pa"));

        let (status, body) = put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": "ps"})).await;
        assert_eq!(status, StatusCode::CONFLICT, "another computer's project: {body}");
        assert_eq!(put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(put(&pool, "/api/sessions/claude/missing/project", json!({"auto": true})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(put(&pool, "/api/sessions/claude/s1/project", json!({})).await.0, StatusCode::BAD_REQUEST);

        let (status, body) = put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": "pb"})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!((&body["project_id"], &body["project_override"]), (&json!("pb"), &json!(true)));
        assert_eq!(memory_project(&conn).as_deref(), Some("pb"), "memories move with the session");

        let (_, body) = put(&pool, "/api/sessions/claude/s1/project", json!({"project_id": null})).await;
        assert_eq!((&body["project_id"], &body["project_override"]), (&Value::Null, &json!(true)));
        assert_eq!(memory_project(&conn), None);
        // Re-matching on a project change leaves the override alone.
        crate::projects::rematch_sessions(&conn, "mac").unwrap();
        assert_eq!(session_project(&conn, "claude", "s1"), None);

        let (_, body) = put(&pool, "/api/sessions/claude/s1/project", json!({"auto": true})).await;
        assert_eq!((&body["project_id"], &body["project_override"]), (&json!("pa"), &json!(false)));
        assert_eq!(memory_project(&conn).as_deref(), Some("pa"));
    }

    #[actix_web::test]
    async fn list_sessions_joins_todo_status() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        let mut body = upload_body("mac", "s1", "~/a", vec![]);
        body["sessions"][0]["stats"]["last_activity"] = json!("2026-10-16T09:00:00Z");
        upload(&pool, body).await;
        let mut body = upload_body("mac", "s2", "~/elsewhere", vec![]);
        body["sessions"][0]["stats"]["last_activity"] = json!("2026-10-16T10:00:00Z");
        upload(&pool, body).await;
        let mut body = upload_body("spread", "s3", "~/a", vec![]);
        body["sessions"][0]["stats"]["last_activity"] = json!("2026-10-10T10:00:00Z");
        upload(&pool, body).await;
        conn.execute_batch(
            "INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'linked');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                 VALUES ('t1', 'mac', '~/a', 'claude', 'ai/claude/todo-t1', 's1', 'waiting');",
        )
        .unwrap();

        let (status, list) = get(&pool, "/api/sessions").await;
        assert_eq!(status, StatusCode::OK);
        let ids: Vec<&str> = list.as_array().unwrap().iter().map(|s| s["session_id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["s2", "s1", "s3"], "newest first");
        let s1 = &list[1];
        assert_eq!((&s1["todo_id"], &s1["status"], &s1["project_id"]), (&json!("t1"), &json!("waiting"), &json!("pa")));
        assert_eq!((&s1["prompts"], &s1["cache_creation_tokens"], &s1["title"]), (&json!(12), &json!(402_311), &json!("Add projects")));
        assert_eq!(s1["files_touched"], json!(["crates/todo-server/src/db.rs"]));
        assert_eq!((&s1["computer_id"], &s1["cwd"], &s1["project_override"]), (&json!("mac"), &json!("~/a"), &json!(false)));
        assert!(list[0].get("todo_id").is_none() && list[0].get("status").is_none(), "{}", list[0]);

        let ids = |list: &Value| -> Vec<String> {
            list.as_array().unwrap().iter().map(|s| s["session_id"].as_str().unwrap().to_string()).collect()
        };
        assert_eq!(ids(&get(&pool, "/api/sessions?project_id=pa").await.1), vec!["s1"]);
        assert_eq!(ids(&get(&pool, "/api/sessions?computer_id=spread").await.1), vec!["s3"]);
        assert_eq!(ids(&get(&pool, "/api/sessions?since=2026-10-16T09:30:00Z").await.1), vec!["s2"]);
        assert_eq!(ids(&get(&pool, "/api/sessions?since=2026-10-11").await.1), vec!["s2", "s1"]);
        assert_eq!(ids(&get(&pool, "/api/sessions?limit=1").await.1), vec!["s2"]);
        assert_eq!(get(&pool, "/api/sessions?since=soon").await.0, StatusCode::BAD_REQUEST);
    }

    /// A Mac with sections Si + P, spread with Sp, codbex with I. One week, 2026-10-12 – 18.
    fn weekly_fixture(conn: &Connection) {
        seed(conn);
        let session = |id: &str, computer: &str, project: Option<&str>| {
            conn.execute(
                "INSERT INTO sessions (tool, session_id, computer_id, cwd, project_id) VALUES ('claude', ?1, ?2, '~', ?3)",
                rusqlite::params![id, computer, project],
            )
            .unwrap();
        };
        session("linked", "mac", Some("pa"));
        session("sp", "spread", None);
        session("mac", "mac", None);
        session("old", "mac", Some("pa"));
        conn.execute_batch(
            "INSERT INTO todos (id, section, title) VALUES ('t1', 'I', 'linked from I');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
                 VALUES ('t1', 'mac', '~', 'claude', 'ai/claude/todo-t1', 'linked');
             INSERT INTO session_days (tool, session_id, day, prompts, assistant_turns, input_tokens, output_tokens,
                                       cache_read_tokens, cache_creation_tokens, active_seconds, files_touched) VALUES
                 ('claude', 'linked', '2026-10-12', 2, 2, 10, 20, 30, NULL, 100, 1),
                 ('claude', 'linked', '2026-10-13', 3, 3, NULL, NULL, NULL, NULL, 200, 2),
                 ('claude', 'linked', '2026-10-19', 100, 100, 1000, 1000, 1000, 1000, 9999, 99),
                 ('claude', 'sp', '2026-10-18', 1, 1, NULL, NULL, NULL, NULL, 50, 0),
                 ('claude', 'mac', '2026-10-14', 4, 3, 5, 6, 7, NULL, 300, 3),
                 ('claude', 'old', '2026-10-11', 50, 50, 50, 50, 50, 50, 500, 5);",
        )
        .unwrap();
    }

    /// sessions, prompts, input tokens, cache-creation tokens, active seconds
    type Counters = (i64, i64, Option<i64>, Option<i64>, i64);

    fn counters(v: &Value) -> Counters {
        (
            v["sessions"].as_i64().unwrap(),
            v["prompts"].as_i64().unwrap(),
            v["input_tokens"].as_i64(),
            v["cache_creation_tokens"].as_i64(),
            v["active_seconds"].as_i64().unwrap(),
        )
    }

    #[actix_web::test]
    async fn weekly_rollup_groups() {
        let (_db, pool) = pool("sess");
        weekly_fixture(&pool.get().unwrap());
        let (status, w) = get(&pool, "/api/stats/weekly?week_start=2026-10-12").await;
        assert_eq!(status, StatusCode::OK, "{w}");
        assert_eq!((&w["week_start"], &w["week_end"]), (&json!("2026-10-12"), &json!("2026-10-18")));
        assert_eq!(counters(&w["totals"]), (3, 10, Some(15), None, 650));
        assert_eq!((&w["totals"]["assistant_turns"], &w["totals"]["files_touched"]), (&json!(9), &json!(6)));
        assert_eq!((&w["totals"]["output_tokens"], &w["totals"]["cache_read_tokens"]), (&json!(26), &json!(37)));

        let sections: Vec<(Value, Counters)> =
            w["by_section"].as_array().unwrap().iter().map(|s| (s["section"].clone(), counters(s))).collect();
        assert_eq!(
            sections,
            vec![
                (json!("Sp"), (1, 1, None, None, 50)),
                (json!("I"), (1, 5, Some(10), None, 300)),
                (Value::Null, (1, 4, Some(5), None, 300)),
            ],
            "linked → its todo's section; spread → its only section; the Mac serves two → null"
        );

        let computers: Vec<(Value, Value, i64)> = w["by_computer"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| (c["computer_id"].clone(), c["name"].clone(), c["sessions"].as_i64().unwrap()))
            .collect();
        assert_eq!(
            computers,
            vec![
                (json!("spread"), json!("spreads-macbook-pro"), 1),
                (json!("mac"), json!("tsvetelins-macbook-pro"), 2),
            ]
        );

        let projects: Vec<(Value, Value, i64, i64)> = w["by_project"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| (p["project_id"].clone(), p["name"].clone(), p["sessions"].as_i64().unwrap(), p["prompts"].as_i64().unwrap()))
            .collect();
        assert_eq!(projects, vec![(json!("pa"), json!("a"), 1, 5), (Value::Null, Value::Null, 2, 5)]);

        // A week without days: zero counters, null tokens, empty groupings.
        let (_, w) = get(&pool, "/api/stats/weekly?week_start=2026-09-28").await;
        assert_eq!(counters(&w["totals"]), (0, 0, None, None, 0));
        assert_eq!((&w["by_project"], &w["by_section"], &w["by_computer"]), (&json!([]), &json!([]), &json!([])));
    }

    #[actix_web::test]
    async fn weekly_project_filter() {
        let (_db, pool) = pool("sess");
        weekly_fixture(&pool.get().unwrap());
        let (status, w) = get(&pool, "/api/stats/weekly?week_start=2026-10-12&project_id=pa").await;
        assert_eq!(status, StatusCode::OK, "{w}");
        assert_eq!(counters(&w["totals"]), (1, 5, Some(10), None, 300));
        assert_eq!(w["by_project"].as_array().unwrap().len(), 1);
        assert_eq!(w["by_section"].as_array().unwrap().iter().map(|s| s["section"].clone()).collect::<Vec<_>>(), vec![json!("I")]);
        assert_eq!(w["by_computer"].as_array().unwrap().len(), 1);
        assert_eq!(w["by_computer"][0]["computer_id"], "mac");
    }

    #[actix_web::test]
    async fn weekly_rejects_non_monday() {
        let (_db, pool) = pool("sess");
        seed(&pool.get().unwrap());
        for bad in ["2026-10-13", "2026-10-18", "2026-02-30", "monday", "2026-10-12T00:00:00"] {
            let (status, body) = get(&pool, &format!("/api/stats/weekly?week_start={bad}")).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}: {body}");
        }
    }

    #[actix_web::test]
    async fn weekly_defaults_to_this_monday() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (status, w) = get(&pool, "/api/stats/weekly").await;
        assert_eq!(status, StatusCode::OK, "{w}");
        let start = w["week_start"].as_str().unwrap();
        let (weekday, age, end): (String, f64, String) = conn
            .query_row(
                "SELECT strftime('%w', ?1), julianday(date('now', 'localtime')) - julianday(?1), date(?1, '+6 days')",
                [start],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(weekday, "1", "{start} is a Monday");
        assert!((0.0..7.0).contains(&age), "{start} is in the current week ({age} days ago)");
        assert_eq!(w["week_end"], json!(end));
    }

    #[actix_web::test]
    async fn conversation_json_has_project_id() {
        let (_db, pool) = pool("sess");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'x'), ('t2', 'Si', 'y');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id) VALUES
                 ('t1', 'mac', '/Users/me/a/x', 'claude', 'ai/claude/todo-t1', 'unknown-session'),
                 ('t2', 'mac', '~/a', 'codex', 'ai/codex/todo-t2', 'known');
             INSERT INTO sessions (tool, session_id, computer_id, cwd, project_id, project_override)
                 VALUES ('codex', 'known', 'mac', '~/a', NULL, 1);",
        )
        .unwrap();
        let (_, c1) = get(&pool, "/api/todos/t1/conversation").await;
        assert_eq!(c1["project_id"], "pa", "matched on the fly when the session isn't known: {c1}");
        let (_, c2) = get(&pool, "/api/todos/t2/conversation").await;
        assert!(c2.get("project_id").is_none(), "the session's own (overridden) project wins: {c2}");
        let (_, all) = get(&pool, "/api/conversations").await;
        let projects: Vec<Value> = all.as_array().unwrap().iter().map(|c| c["project_id"].clone()).collect();
        assert!(projects.contains(&json!("pa")) && projects.contains(&Value::Null), "{all}");
    }
}
