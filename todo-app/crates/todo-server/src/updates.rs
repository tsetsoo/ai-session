//! Daily updates per project. Each Mac's runner summarizes its own conversations for a day
//! (08:00 to 08:00 Sofia) and posts the summaries here; the project's computer then writes the
//! project's update from them. The hub makes no model calls.

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use todo_shared::{ProjectUpdate, UpdateSummary};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, server_error};
use crate::cron::TZ;
use crate::db::DbPool;

/// Longest stored conversation summary and title, in characters (longer ones are cut).
pub(crate) const MAX_SUMMARY: usize = 2000;
const MAX_TITLE: usize = 200;
const MAX_ITEMS: usize = 500;
/// Longest project update, in characters.
pub(crate) const MAX_UPDATE: usize = 20_000;
/// Days back a Mac catches up, and how long a silent computer is still waited for.
const CATCH_UP_DAYS: i64 = 3;
/// Sofia hour on the morning after a window when the update is written without late computers.
const FALLBACK_HOUR: u32 = 10;
/// The window starts and ends at this Sofia hour.
const DAY_START_HOUR: u32 = 8;

pub(crate) enum UpdateError {
    BadRequest(String),
    NotFound(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for UpdateError {
    fn from(e: rusqlite::Error) -> Self {
        UpdateError::Db(e)
    }
}

fn respond(e: UpdateError) -> HttpResponse {
    match e {
        UpdateError::BadRequest(m) => bad_request(&m),
        UpdateError::NotFound(m) => crate::conversations::not_found(m),
        UpdateError::Db(e) => server_error(e),
    }
}

fn parse_day(day: &str) -> Option<NaiveDate> {
    if day.len() != 10 {
        return None;
    }
    NaiveDate::parse_from_str(day, "%Y-%m-%d").ok()
}

/// Sofia 08:00 on `date`, as UTC (08:00 always exists: DST changes happen at night).
fn sofia_eight(date: NaiveDate) -> Option<DateTime<Utc>> {
    let local = date.and_time(NaiveTime::from_hms_opt(DAY_START_HOUR, 0, 0)?);
    TZ.from_local_datetime(&local).single().map(|t| t.with_timezone(&Utc))
}

/// The window of `day`: Sofia 08:00 on that date to Sofia 08:00 the next date.
pub(crate) fn day_window(day: &str) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    let date = parse_day(day)?;
    Some((sofia_eight(date)?, sofia_eight(date.succ_opt()?)?))
}

/// The newest day whose window has ended at `now`.
pub(crate) fn last_closed_day(now: DateTime<Utc>) -> String {
    let local = now.with_timezone(&TZ);
    let today = local.date_naive();
    let back = if local.time() >= NaiveTime::from_hms_opt(DAY_START_HOUR, 0, 0).unwrap() { 1 } else { 2 };
    (today - Duration::days(back)).format("%Y-%m-%d").to_string()
}

fn checked_day(day: &str) -> Result<(), UpdateError> {
    if parse_day(day).is_none() {
        return Err(UpdateError::BadRequest("day must be YYYY-MM-DD".into()));
    }
    Ok(())
}

fn cut(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

// --- Matching a conversation to a switched-on project --------------------------------

/// The conversation's project, if daily updates are on for it: its todo's project, else its
/// session's stored project (scheduled worktrees live outside the project folder), else the
/// project whose folder holds `cwd` on that computer.
fn project_of(conn: &Connection, computer_id: &str, tool: &str, session_id: &str, cwd: &str) -> rusqlite::Result<Option<String>> {
    let from_todo: Option<String> = conn
        .query_row(
            "SELECT t.project_id FROM conversations c JOIN todos t ON t.id = c.todo_id
             WHERE c.tool = ?1 AND c.session_id = ?2 AND t.project_id IS NOT NULL",
            params![tool, session_id],
            |r| r.get(0),
        )
        .optional()?;
    let from_session: Option<String> = match from_todo {
        Some(p) => Some(p),
        None => conn
            .query_row(
                "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2 AND project_id IS NOT NULL",
                params![tool, session_id],
                |r| r.get(0),
            )
            .optional()?,
    };
    let project = match from_session {
        Some(p) => Some(p),
        None => crate::projects::project_for(conn, computer_id, cwd)?,
    };
    let Some(project) = project else { return Ok(None) };
    let on: bool = conn
        .query_row("SELECT daily_updates FROM projects WHERE id = ?1", params![project], |r| r.get::<_, i64>(0))
        .optional()?
        .is_some_and(|v| v != 0);
    Ok(on.then_some(project))
}

#[derive(Debug, Deserialize)]
pub struct SessionRef {
    pub tool: String,
    pub session_id: String,
    #[serde(default)]
    pub cwd: String,
}

#[derive(Debug, Deserialize)]
pub struct MatchRequest {
    pub computer_id: String,
    pub sessions: Vec<SessionRef>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct MatchedSession {
    pub tool: String,
    pub session_id: String,
    pub project_id: String,
}

pub(crate) fn match_db(conn: &Connection, req: &MatchRequest) -> Result<Vec<MatchedSession>, UpdateError> {
    if req.sessions.len() > 5000 {
        return Err(UpdateError::BadRequest("at most 5000 sessions".into()));
    }
    let mut out = Vec::new();
    for s in &req.sessions {
        if let Some(project_id) = project_of(conn, &req.computer_id, &s.tool, &s.session_id, &s.cwd)? {
            out.push(MatchedSession { tool: s.tool.clone(), session_id: s.session_id.clone(), project_id });
        }
    }
    Ok(out)
}

pub async fn match_sessions(pool: web::Data<DbPool>, req: web::Json<MatchRequest>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => match match_db(&conn, &req) {
            Ok(v) => HttpResponse::Ok().json(v),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

// --- Summaries and reports from the runners --------------------------------------------

#[derive(Debug, Deserialize)]
pub struct SummaryItem {
    pub tool: String,
    pub session_id: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub title: String,
    pub summary: String,
    #[serde(default)]
    pub jira_keys: Vec<String>,
    #[serde(default)]
    pub model: String,
}

#[derive(Debug, Deserialize)]
pub struct SummariesRequest {
    pub computer_id: String,
    pub day: String,
    pub items: Vec<SummaryItem>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct SummariesResponse {
    pub stored: u32,
    pub skipped: u32,
}

pub(crate) fn summaries_db(conn: &Connection, req: &SummariesRequest) -> Result<SummariesResponse, UpdateError> {
    checked_day(&req.day)?;
    if req.items.len() > MAX_ITEMS {
        return Err(UpdateError::BadRequest(format!("at most {MAX_ITEMS} items")));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let (mut stored, mut skipped) = (0, 0);
    for item in &req.items {
        let Some(project_id) = project_of(&tx, &req.computer_id, &item.tool, &item.session_id, &item.cwd)? else {
            skipped += 1;
            continue;
        };
        let todo_id: Option<String> = tx
            .query_row(
                "SELECT todo_id FROM conversations WHERE tool = ?1 AND session_id = ?2 AND todo_id IS NOT NULL LIMIT 1",
                params![item.tool, item.session_id],
                |r| r.get(0),
            )
            .optional()?;
        let keys: Vec<String> = item.jira_keys.iter().take(20).map(|k| cut(k, 40)).collect();
        // `seq` grows with every stored summary, so a write can tell which ones it included.
        let seq: i64 = tx.query_row("SELECT COALESCE(MAX(seq), 0) + 1 FROM update_summaries", [], |r| r.get(0))?;
        tx.execute(
            "INSERT INTO update_summaries (id, project_id, day, computer_id, tool, session_id, todo_id, title, summary, jira_keys, model, seq)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT (project_id, day, tool, session_id) DO UPDATE SET
                computer_id = excluded.computer_id, todo_id = excluded.todo_id, title = excluded.title,
                summary = excluded.summary, jira_keys = excluded.jira_keys, model = excluded.model,
                seq = excluded.seq, created_at = datetime('now')",
            params![
                Uuid::new_v4().to_string(),
                project_id,
                req.day,
                req.computer_id,
                item.tool,
                item.session_id,
                todo_id,
                cut(item.title.trim(), MAX_TITLE),
                cut(item.summary.trim(), MAX_SUMMARY),
                serde_json::to_string(&keys).unwrap_or_else(|_| "[]".into()),
                cut(&item.model, 80),
                seq,
            ],
        )?;
        // An update already written for that day is rewritten with this summary in it.
        tx.execute("UPDATE project_updates SET stale = 1 WHERE project_id = ?1 AND day = ?2", params![project_id, req.day])?;
        stored += 1;
    }
    tx.commit()?;
    Ok(SummariesResponse { stored, skipped })
}

pub async fn post_summaries(pool: web::Data<DbPool>, broadcaster: web::Data<Broadcaster>, req: web::Json<SummariesRequest>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => match summaries_db(&conn, &req) {
            Ok(v) => {
                if v.stored > 0 {
                    broadcaster.send();
                }
                HttpResponse::Ok().json(v)
            }
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

#[derive(Debug, Deserialize)]
pub struct ReportRequest {
    pub computer_id: String,
    pub day: String,
}

pub(crate) fn report_db(conn: &Connection, req: &ReportRequest) -> Result<(), UpdateError> {
    checked_day(&req.day)?;
    conn.execute(
        "INSERT INTO update_reports (computer_id, day) VALUES (?1, ?2)
         ON CONFLICT (computer_id, day) DO UPDATE SET reported_at = datetime('now')",
        params![req.computer_id, req.day],
    )?;
    // Updates written while waiting on this computer are written again without the note.
    conn.execute(
        "UPDATE project_updates SET stale = 1 WHERE day = ?1 AND EXISTS (
             SELECT 1 FROM json_each(project_updates.waiting_on), computers c
             WHERE c.id = ?2 AND json_each.value = c.name)",
        params![req.day, req.computer_id],
    )?;
    Ok(())
}

pub async fn post_report(pool: web::Data<DbPool>, req: web::Json<ReportRequest>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => match report_db(&conn, &req) {
            Ok(()) => HttpResponse::Ok().json(serde_json::json!({"ok": true})),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}


// --- What each runner should do ------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct RunnerSettings {
    pub five_hour: u8,
    pub weekly: u8,
    pub claude_model: String,
    pub codex_model: String,
}

#[derive(Debug, Serialize)]
pub struct RunnerProject {
    pub id: String,
    pub name: String,
    pub folder: String,
}

#[derive(Debug, Serialize)]
pub struct WriteSummary {
    pub title: String,
    pub summary: String,
    pub jira_keys: Vec<String>,
    pub computer: String,
}

#[derive(Debug, Serialize)]
pub struct CompletedTodo {
    pub title: String,
    pub completed_at: String,
}

#[derive(Debug, Serialize)]
pub struct WriteItem {
    pub project_id: String,
    pub project_name: String,
    pub folder: String,
    pub day: String,
    pub style: String,
    pub summaries: Vec<WriteSummary>,
    pub completed_todos: Vec<CompletedTodo>,
    pub todo_titles: Vec<String>,
    /// The newest summary's `seq`; sent back with the PUT.
    pub generation: i64,
}

#[derive(Debug, Serialize)]
pub struct RunnerWork {
    pub settings: RunnerSettings,
    /// Closed days (oldest first) this computer still has to summarize.
    pub days: Vec<String>,
    /// Switched-on projects on this computer (their commits are read here).
    pub projects: Vec<RunnerProject>,
    /// Project updates this computer should write now.
    pub write: Vec<WriteItem>,
}

/// The last `CATCH_UP_DAYS` closed days, oldest first.
fn recent_days(now: DateTime<Utc>) -> Vec<String> {
    let last = parse_day(&last_closed_day(now)).expect("last_closed_day is a date");
    (0..CATCH_UP_DAYS).rev().map(|back| (last - Duration::days(back)).format("%Y-%m-%d").to_string()).collect()
}

/// Computers whose runner checked in within the last `CATCH_UP_DAYS` days: (id, name).
pub(crate) fn expected_computers(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<Vec<(String, String)>> {
    let since = crate::scheduler::sql_time(now - Duration::days(CATCH_UP_DAYS));
    let mut stmt = conn.prepare("SELECT id, name FROM computers WHERE runner_seen_at >= ?1 ORDER BY name")?;
    let rows = stmt.query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?;
    rows.collect()
}

/// Names of expected computers that haven't reported `day`.
fn waiting_on(conn: &Connection, day: &str, now: DateTime<Utc>) -> rusqlite::Result<Vec<String>> {
    let mut out = Vec::new();
    for (id, name) in expected_computers(conn, now)? {
        let reported: bool = conn
            .query_row("SELECT 1 FROM update_reports WHERE computer_id = ?1 AND day = ?2", params![id, day], |_| Ok(()))
            .optional()?
            .is_some();
        if !reported {
            out.push(name);
        }
    }
    Ok(out)
}

/// Every expected computer reported, or it's past 10:00 Sofia the morning after the window.
fn ready(conn: &Connection, day: &str, now: DateTime<Utc>) -> rusqlite::Result<bool> {
    let fallback = parse_day(day)
        .and_then(|d| d.succ_opt())
        .and_then(|d| TZ.from_local_datetime(&d.and_time(NaiveTime::from_hms_opt(FALLBACK_HOUR, 0, 0)?)).single())
        .map(|t| t.with_timezone(&Utc));
    if fallback.is_some_and(|f| now >= f) {
        return Ok(true);
    }
    Ok(waiting_on(conn, day, now)?.is_empty())
}

fn needs_writing(conn: &Connection, project_id: &str, day: &str) -> rusqlite::Result<bool> {
    let row: Option<(i64, i64)> = conn
        .query_row(
            "SELECT rewrite_requested, stale FROM project_updates WHERE project_id = ?1 AND day = ?2",
            params![project_id, day],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    Ok(row.is_none_or(|(rewrite, stale)| rewrite != 0 || stale != 0))
}

fn write_item(conn: &Connection, p: &OnProject, day: &str) -> rusqlite::Result<WriteItem> {
    let (start, end) = day_window(day).expect("a recent day has a window");
    let mut stmt = conn.prepare(
        "SELECT u.title, u.summary, u.jira_keys, COALESCE(c.name, u.computer_id) FROM update_summaries u
         LEFT JOIN computers c ON c.id = u.computer_id
         WHERE u.project_id = ?1 AND u.day = ?2 ORDER BY u.created_at, u.rowid",
    )?;
    let summaries = stmt
        .query_map(params![p.id, day], |r| {
            let keys: String = r.get(2)?;
            Ok(WriteSummary {
                title: r.get(0)?,
                summary: r.get(1)?,
                jira_keys: serde_json::from_str(&keys).unwrap_or_default(),
                computer: r.get(3)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt = conn.prepare(
        "SELECT title, completed_at FROM todos WHERE project_id = ?1 AND completed = 1
         AND completed_at >= ?2 AND completed_at < ?3 ORDER BY completed_at",
    )?;
    let completed_todos = stmt
        .query_map(params![p.id, crate::scheduler::sql_time(start), crate::scheduler::sql_time(end)], |r| {
            Ok(CompletedTodo { title: r.get(0)?, completed_at: r.get(1)? })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt = conn.prepare(
        "SELECT title FROM todos WHERE project_id = ?1 AND (completed = 0 OR completed_at >= ?2)
         ORDER BY updated_at DESC LIMIT 200",
    )?;
    let todo_titles = stmt
        .query_map(params![p.id, crate::scheduler::sql_time(start)], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    let generation: i64 = conn.query_row(
        "SELECT COALESCE(MAX(seq), 0) FROM update_summaries WHERE project_id = ?1 AND day = ?2",
        params![p.id, day],
        |r| r.get(0),
    )?;
    Ok(WriteItem {
        generation,
        project_id: p.id.clone(),
        project_name: p.name.clone(),
        folder: p.folder.clone(),
        day: day.to_string(),
        style: p.style.clone(),
        summaries,
        completed_todos,
        todo_titles,
    })
}

struct OnProject {
    id: String,
    name: String,
    folder: String,
    style: String,
    since: String,
    computer_id: String,
}

fn on_projects(conn: &Connection) -> rusqlite::Result<Vec<OnProject>> {
    let mut stmt = conn.prepare(
        "SELECT p.id, p.name, p.folder, p.update_style, COALESCE(p.daily_updates_since, ''), sc.computer_id
         FROM projects p JOIN section_computers sc ON sc.section = p.section
         WHERE p.daily_updates = 1 ORDER BY p.name",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(OnProject {
            id: r.get(0)?,
            name: r.get(1)?,
            folder: r.get(2)?,
            style: r.get(3)?,
            since: r.get(4)?,
            computer_id: r.get(5)?,
        })
    })?;
    rows.collect()
}

pub(crate) fn runner_db(conn: &Connection, computer_id: &str, now: DateTime<Utc>) -> Result<RunnerWork, UpdateError> {
    let scheduler = crate::jobs::settings_db(conn)?;
    let today = crate::today::settings_db(conn)?;
    let settings = RunnerSettings {
        five_hour: scheduler.five_hour,
        weekly: scheduler.weekly,
        claude_model: today.claude_model,
        codex_model: today.codex_model,
    };
    let projects = on_projects(conn)?;
    let recent = recent_days(now);
    let mut days = Vec::new();
    if let Some(earliest) = projects.iter().map(|p| p.since.as_str()).min() {
        for day in &recent {
            let reported = conn
                .query_row("SELECT 1 FROM update_reports WHERE computer_id = ?1 AND day = ?2", params![computer_id, day], |_| Ok(()))
                .optional()?
                .is_some();
            if day.as_str() >= earliest && !reported {
                days.push(day.clone());
            }
        }
    }
    let mut write = Vec::new();
    let mine: Vec<&OnProject> = projects.iter().filter(|p| p.computer_id == computer_id).collect();
    for day in &recent {
        // This computer's own summaries come first, even past the 10:00 fallback.
        if days.contains(day) {
            continue;
        }
        let candidates: Vec<&&OnProject> = mine.iter().filter(|p| day.as_str() >= p.since.as_str()).collect();
        if candidates.is_empty() || !ready(conn, day, now)? {
            continue;
        }
        for p in candidates {
            if needs_writing(conn, &p.id, day)? {
                write.push(write_item(conn, p, day)?);
            }
        }
    }
    // Rewrites asked for on older days (still kept): those days are long past the fallback.
    let oldest_recent = recent.first().cloned().unwrap_or_default();
    let cutoff = (now.with_timezone(&TZ).date_naive() - Duration::days(KEEP_DAYS)).format("%Y-%m-%d").to_string();
    for p in &mine {
        let mut stmt = conn.prepare(
            "SELECT day FROM project_updates WHERE project_id = ?1 AND (rewrite_requested = 1 OR stale = 1)
             AND day < ?2 AND day >= ?3 ORDER BY day",
        )?;
        let older = stmt.query_map(params![p.id, oldest_recent, cutoff], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        for day in older {
            write.push(write_item(conn, p, &day)?);
        }
    }
    let projects = mine.iter().map(|p| RunnerProject { id: p.id.clone(), name: p.name.clone(), folder: p.folder.clone() }).collect();
    Ok(RunnerWork { settings, days, projects, write })
}

pub async fn runner_work(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let Some(computer_id) = query.get("computer_id").filter(|c| !c.trim().is_empty()) else {
        return bad_request("computer_id is required");
    };
    match pool.get() {
        Ok(conn) => match runner_db(&conn, computer_id, Utc::now()) {
            Ok(v) => HttpResponse::Ok().json(v),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

#[derive(Debug, Deserialize)]
pub struct PutUpdateRequest {
    /// Markdown; empty: nothing happened that day (stored so it isn't offered again, not shown).
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub commits: u32,
    /// The work item's `generation`: summaries stored after it keep the update stale.
    #[serde(default)]
    pub generation: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct StoredUpdate {
    pub day: String,
    pub waiting_on: Vec<String>,
}

pub(crate) fn put_update_db(
    conn: &Connection,
    project_id: &str,
    day: &str,
    req: &PutUpdateRequest,
    now: DateTime<Utc>,
) -> Result<StoredUpdate, UpdateError> {
    checked_day(day)?;
    if req.text.chars().count() > MAX_UPDATE {
        return Err(UpdateError::BadRequest(format!("text is limited to {MAX_UPDATE} characters")));
    }
    if !crate::projects::project_exists(conn, project_id)? {
        return Err(UpdateError::NotFound("Project not found"));
    }
    let waiting = waiting_on(conn, day, now)?;
    let newer: bool = match req.generation {
        Some(generation) => conn
            .query_row(
                "SELECT 1 FROM update_summaries WHERE project_id = ?1 AND day = ?2 AND seq > ?3 LIMIT 1",
                params![project_id, day, generation],
                |_| Ok(()),
            )
            .optional()?
            .is_some(),
        None => false,
    };
    conn.execute(
        "INSERT INTO project_updates (project_id, day, text, commits, waiting_on, written_at, rewrite_requested, stale)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)
         ON CONFLICT (project_id, day) DO UPDATE SET text = excluded.text, commits = excluded.commits,
            waiting_on = excluded.waiting_on, written_at = excluded.written_at, rewrite_requested = 0, stale = excluded.stale",
        params![
            project_id,
            day,
            req.text.trim(),
            req.commits,
            serde_json::to_string(&waiting).unwrap_or_else(|_| "[]".into()),
            crate::scheduler::sql_time(now),
            newer as i64,
        ],
    )?;
    Ok(StoredUpdate { day: day.to_string(), waiting_on: waiting })
}

pub async fn put_update(
    pool: web::Data<DbPool>,
    broadcaster: web::Data<Broadcaster>,
    path: web::Path<(String, String)>,
    req: web::Json<PutUpdateRequest>,
) -> HttpResponse {
    let (project_id, day) = path.into_inner();
    match pool.get() {
        Ok(conn) => match put_update_db(&conn, &project_id, &day, &req, Utc::now()) {
            Ok(v) => {
                broadcaster.send();
                HttpResponse::Ok().json(v)
            }
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}


// --- For the apps ---------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub before: Option<String>,
    pub limit: Option<u32>,
}

const LIST_DEFAULT: u32 = 14;
const LIST_MAX: u32 = 30;
/// Days kept, counted back from today's Sofia date.
const KEEP_DAYS: i64 = 90;

pub(crate) fn list_updates_db(conn: &Connection, project_id: &str, q: &ListQuery) -> Result<Vec<ProjectUpdate>, UpdateError> {
    if let Some(before) = &q.before {
        checked_day(before)?;
    }
    if !crate::projects::project_exists(conn, project_id)? {
        return Err(UpdateError::NotFound("Project not found"));
    }
    let limit = q.limit.unwrap_or(LIST_DEFAULT).clamp(1, LIST_MAX);
    let mut stmt = conn.prepare(
        "SELECT u.day, u.text, u.commits, u.waiting_on, u.written_at, u.rewrite_requested, u.stale,
                (SELECT COUNT(*) FROM update_summaries s WHERE s.project_id = u.project_id AND s.day = u.day)
         FROM project_updates u
         WHERE u.project_id = ?1 AND u.text != '' AND (?2 IS NULL OR u.day < ?2)
         ORDER BY u.day DESC LIMIT ?3",
    )?;
    let rows = stmt.query_map(params![project_id, q.before, limit], |r| {
        let waiting: String = r.get(3)?;
        Ok(ProjectUpdate {
            day: r.get(0)?,
            text: r.get(1)?,
            commits: r.get(2)?,
            waiting_on: serde_json::from_str(&waiting).unwrap_or_default(),
            written_at: r.get(4)?,
            rewriting: r.get::<_, i64>(5)? != 0 || r.get::<_, i64>(6)? != 0,
            conversations: r.get(7)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub async fn list_updates(pool: web::Data<DbPool>, path: web::Path<String>, q: web::Query<ListQuery>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => match list_updates_db(&conn, &path, &q) {
            Ok(v) => HttpResponse::Ok().json(v),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

pub(crate) fn day_summaries_db(conn: &Connection, project_id: &str, day: &str) -> Result<Vec<UpdateSummary>, UpdateError> {
    checked_day(day)?;
    let mut stmt = conn.prepare(
        "SELECT u.tool, u.session_id, u.todo_id, u.title, u.summary, u.jira_keys, COALESCE(c.name, u.computer_id)
         FROM update_summaries u LEFT JOIN computers c ON c.id = u.computer_id
         WHERE u.project_id = ?1 AND u.day = ?2 ORDER BY u.created_at, u.rowid",
    )?;
    let rows = stmt.query_map(params![project_id, day], |r| {
        let keys: String = r.get(5)?;
        Ok(UpdateSummary {
            tool: r.get(0)?,
            session_id: r.get(1)?,
            todo_id: r.get(2)?,
            title: r.get(3)?,
            summary: r.get(4)?,
            jira_keys: serde_json::from_str(&keys).unwrap_or_default(),
            computer: r.get(6)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub async fn day_summaries(pool: web::Data<DbPool>, path: web::Path<(String, String)>) -> HttpResponse {
    let (project_id, day) = path.into_inner();
    match pool.get() {
        Ok(conn) => match day_summaries_db(&conn, &project_id, &day) {
            Ok(v) => HttpResponse::Ok().json(v),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

pub(crate) fn rewrite_db(conn: &Connection, project_id: &str, day: &str) -> Result<(), UpdateError> {
    checked_day(day)?;
    let n = conn.execute(
        "UPDATE project_updates SET rewrite_requested = 1 WHERE project_id = ?1 AND day = ?2",
        params![project_id, day],
    )?;
    if n == 0 {
        return Err(UpdateError::NotFound("No update for that day"));
    }
    Ok(())
}

pub async fn rewrite(pool: web::Data<DbPool>, broadcaster: web::Data<Broadcaster>, path: web::Path<(String, String)>) -> HttpResponse {
    let (project_id, day) = path.into_inner();
    match pool.get() {
        Ok(conn) => match rewrite_db(&conn, &project_id, &day) {
            Ok(()) => {
                broadcaster.send();
                HttpResponse::Ok().json(serde_json::json!({"ok": true}))
            }
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

/// Deletes summaries, reports and updates of days more than 90 days before today (Sofia).
pub(crate) fn cleanup_db(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize> {
    let today = now.with_timezone(&TZ).date_naive();
    let cutoff = (today - Duration::days(KEEP_DAYS)).format("%Y-%m-%d").to_string();
    let mut n = 0;
    for table in ["update_summaries", "update_reports", "project_updates"] {
        n += conn.execute(&format!("DELETE FROM {table} WHERE day < ?1"), params![cutoff])?;
    }
    Ok(n)
}

/// `cleanup_db` once per Sofia date, from the scheduler tick.
pub(crate) fn daily_cleanup(pool: &DbPool, now: DateTime<Utc>) {
    static LAST: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    let today = crate::scheduler::local_date(now);
    let Ok(mut last) = LAST.lock() else { return };
    if last.as_deref() == Some(today.as_str()) {
        return;
    }
    match pool.get().map_err(|e| e.to_string()).and_then(|c| cleanup_db(&c, now).map_err(|e| e.to_string())) {
        Ok(_) => *last = Some(today),
        Err(e) => println!("updates: cleanup failed: {e}"),
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::http::StatusCode;
    use serde_json::json;

    use crate::test_support::{insert_session, pool, post, seed_computers};

    fn utc(s: &str) -> DateTime<Utc> {
        crate::scheduler::parse_sql_time(s).unwrap()
    }

    /// `pa` (Si, this Mac, ~/w/a) has daily updates on; `pb` (Si, ~/w/b) has them off.
    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder, daily_updates, daily_updates_since) VALUES
                 ('pa', 'a', 'Si', '~/w/a', 1, '2026-01-01'),
                 ('pb', 'b', 'Si', '~/w/b', 0, NULL);",
        )
        .unwrap();
    }

    #[test]
    fn day_window_is_sofia_eight_to_eight() {
        let (start, end) = day_window("2026-11-02").unwrap();
        assert_eq!((start, end), (utc("2026-11-02 06:00:00"), utc("2026-11-03 06:00:00")));
    }

    #[test]
    fn day_window_across_dst() {
        let (start, end) = day_window("2026-10-24").unwrap();
        assert_eq!((start, end), (utc("2026-10-24 05:00:00"), utc("2026-10-25 06:00:00")));
    }

    #[test]
    fn last_closed_day_edges() {
        assert_eq!(last_closed_day(Utc.with_ymd_and_hms(2026, 11, 3, 5, 59, 59).unwrap()), "2026-11-01");
        assert_eq!(last_closed_day(Utc.with_ymd_and_hms(2026, 11, 3, 6, 0, 0).unwrap()), "2026-11-02");
    }

    #[test]
    fn day_window_rejects_garbage() {
        assert!(day_window("2026-13-01").is_none());
        assert!(day_window("yesterday").is_none());
    }

    #[actix_web::test]
    async fn match_returns_only_switched_on() {
        let (_db, pool) = pool("updates");
        seed(&pool.get().unwrap());
        let (status, body) = post(
            &pool,
            "/api/updates/match",
            json!({"computer_id": "mac", "sessions": [
                {"tool": "claude", "session_id": "s1", "cwd": "~/w/a/sub"},
                {"tool": "codex", "session_id": "s2", "cwd": "~/w/b"},
                {"tool": "claude", "session_id": "s3", "cwd": "~/elsewhere"}
            ]}),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body, json!([{"tool": "claude", "session_id": "s1", "project_id": "pa"}]));
    }

    #[actix_web::test]
    async fn match_uses_the_sessions_project_for_worktrees() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        insert_session(&conn, "mac", "claude", "s9", "~/.ai-remote/worktrees/a/r1");
        conn.execute("UPDATE sessions SET project_id = 'pa' WHERE session_id = 's9'", []).unwrap();
        let (_, body) = post(
            &pool,
            "/api/updates/match",
            json!({"computer_id": "mac", "sessions": [{"tool": "claude", "session_id": "s9", "cwd": "~/.ai-remote/worktrees/a/r1"}]}),
        )
        .await;
        assert_eq!(body, json!([{"tool": "claude", "session_id": "s9", "project_id": "pa"}]));
    }

    fn item(sid: &str, cwd: &str, summary: &str) -> serde_json::Value {
        json!({"tool": "claude", "session_id": sid, "cwd": cwd, "title": "T", "summary": summary,
               "jira_keys": ["EIN-1"], "model": "haiku"})
    }

    #[actix_web::test]
    async fn summaries_upsert_and_link_todo() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, title, section, project_id) VALUES ('t1', 'Todo', 'Si', 'pa');
             INSERT INTO conversations (id, todo_id, computer_id, tool, session_id, tmux_name, cwd)
                 VALUES ('c1', 't1', 'mac', 'claude', 's1', 'tm', '~/w/a');",
        )
        .unwrap();
        let body = |summary: &str| json!({"computer_id": "mac", "day": "2026-11-02", "items": [item("s1", "~/w/a", summary)]});
        let (status, resp) = post(&pool, "/api/updates/summaries", body("first")).await;
        assert_eq!(status, StatusCode::OK, "{resp}");
        assert_eq!(resp, json!({"stored": 1, "skipped": 0}));
        post(&pool, "/api/updates/summaries", body("second")).await;
        let rows: Vec<(String, Option<String>, String)> = conn
            .prepare("SELECT summary, todo_id, jira_keys FROM update_summaries")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(rows, vec![("second".to_string(), Some("t1".to_string()), "[\"EIN-1\"]".to_string())]);
    }

    #[actix_web::test]
    async fn summaries_skip_off_projects() {
        let (_db, pool) = pool("updates");
        seed(&pool.get().unwrap());
        let (_, resp) = post(
            &pool,
            "/api/updates/summaries",
            json!({"computer_id": "mac", "day": "2026-11-02", "items": [item("s2", "~/w/b", "x")]}),
        )
        .await;
        assert_eq!(resp, json!({"stored": 0, "skipped": 1}));
    }

    #[actix_web::test]
    async fn summaries_validate_day_and_cut_long_text() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (status, _) = post(&pool, "/api/updates/summaries", json!({"computer_id": "mac", "day": "nope", "items": []})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        post(
            &pool,
            "/api/updates/summaries",
            json!({"computer_id": "mac", "day": "2026-11-02", "items": [item("s1", "~/w/a", &"x".repeat(5000))]}),
        )
        .await;
        let len: i64 = conn.query_row("SELECT length(summary) FROM update_summaries", [], |r| r.get(0)).unwrap();
        assert_eq!(len, MAX_SUMMARY as i64);
    }

    #[actix_web::test]
    async fn late_summary_marks_update_stale() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO project_updates (project_id, day, text) VALUES ('pa', '2026-11-02', 'old')", []).unwrap();
        post(
            &pool,
            "/api/updates/summaries",
            json!({"computer_id": "mac", "day": "2026-11-02", "items": [item("s1", "~/w/a", "late")]}),
        )
        .await;
        let stale: i64 = conn.query_row("SELECT stale FROM project_updates", [], |r| r.get(0)).unwrap();
        assert_eq!(stale, 1);
    }

    #[actix_web::test]
    async fn reports_upsert() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        for _ in 0..2 {
            let (status, _) = post(&pool, "/api/updates/reports", json!({"computer_id": "mac", "day": "2026-11-02"})).await;
            assert_eq!(status, StatusCode::OK);
        }
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM update_reports", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
    }
    // --- Task 3: what each runner should do -------------------------------------------

    fn seen(conn: &Connection, computer: &str, at: &str) {
        conn.execute("UPDATE computers SET runner_seen_at = ?2 WHERE id = ?1", params![computer, at]).unwrap();
    }

    fn report(conn: &Connection, computer: &str, day: &str) {
        report_db(conn, &ReportRequest { computer_id: computer.into(), day: day.into() }).ok().unwrap();
    }

    fn write_days(work: &RunnerWork) -> Vec<(String, String)> {
        work.write.iter().map(|w| (w.project_id.clone(), w.day.clone())).collect()
    }

    #[actix_web::test]
    async fn days_lists_unreported_closed_days_max_three() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        let now = utc("2026-11-06 07:00:00");
        // 09:00 Sofia on the 6th: the 5th's window has closed.
        assert_eq!(runner_db(&conn, "mac", now).ok().unwrap().days, vec!["2026-11-03", "2026-11-04", "2026-11-05"]);
        report(&conn, "mac", "2026-11-04");
        assert_eq!(runner_db(&conn, "mac", now).ok().unwrap().days, vec!["2026-11-03", "2026-11-05"]);
    }

    #[actix_web::test]
    async fn days_empty_when_no_project_on() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates = 0", []).unwrap();
        let work = runner_db(&conn, "mac", utc("2026-11-06 07:00:00")).ok().unwrap();
        assert!(work.days.is_empty() && work.write.is_empty() && work.projects.is_empty());
    }

    #[actix_web::test]
    async fn days_start_at_switch_on() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-04' WHERE id = 'pa'", []).unwrap();
        assert_eq!(runner_db(&conn, "mac", utc("2026-11-06 07:00:00")).ok().unwrap().days, vec!["2026-11-04", "2026-11-05"]);
    }

    #[actix_web::test]
    async fn write_waits_for_expected_computers() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        let now = utc("2026-11-04 07:00:00"); // 09:00 Sofia: before the 10:00 fallback
        seen(&conn, "mac", "2026-11-04 06:59:00");
        seen(&conn, "spread", "2026-11-04 06:00:00");
        report(&conn, "mac", "2026-11-03");
        assert!(runner_db(&conn, "mac", now).ok().unwrap().write.is_empty());
        report(&conn, "spread", "2026-11-03");
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        assert_eq!(write_days(&work), vec![("pa".to_string(), "2026-11-03".to_string())]);
        assert_eq!(work.write[0].folder, "~/w/a");
    }

    #[actix_web::test]
    async fn write_ignores_computer_unseen_for_three_days() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        seen(&conn, "mac", "2026-11-04 06:59:00");
        seen(&conn, "spread", "2026-10-31 06:00:00");
        report(&conn, "mac", "2026-11-03");
        assert_eq!(write_days(&runner_db(&conn, "mac", utc("2026-11-04 07:00:00")).ok().unwrap()).len(), 1);
    }

    #[actix_web::test]
    async fn write_after_ten_without_reports() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        seen(&conn, "mac", "2026-11-04 08:00:00");
        seen(&conn, "spread", "2026-11-04 06:00:00");
        report(&conn, "mac", "2026-11-03");
        let now = utc("2026-11-04 08:01:00"); // 10:01 Sofia
        assert_eq!(write_days(&runner_db(&conn, "mac", now).ok().unwrap()), vec![("pa".to_string(), "2026-11-03".to_string())]);
        let update = put_update_db(&conn, "pa", "2026-11-03", &PutUpdateRequest { text: "done".into(), commits: 2, generation: None }, now).ok().unwrap();
        assert_eq!(update.waiting_on, vec!["spreads-macbook-pro".to_string()]);
    }

    #[actix_web::test]
    async fn put_clears_stale_and_rewrite() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        seen(&conn, "mac", "2026-11-04 06:59:00");
        report(&conn, "mac", "2026-11-03");
        let now = utc("2026-11-04 07:00:00");
        let body = PutUpdateRequest { text: "v1".into(), commits: 0, generation: None };
        put_update_db(&conn, "pa", "2026-11-03", &body, now).ok().unwrap();
        assert!(runner_db(&conn, "mac", now).ok().unwrap().write.is_empty(), "written");
        summaries_db(
            &conn,
            &SummariesRequest {
                computer_id: "mac".into(),
                day: "2026-11-03".into(),
                items: vec![SummaryItem {
                    tool: "claude".into(),
                    session_id: "s1".into(),
                    cwd: "~/w/a".into(),
                    title: "T".into(),
                    summary: "late".into(),
                    jira_keys: vec![],
                    model: "haiku".into(),
                }],
            },
        )
        .ok()
        .unwrap();
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        assert_eq!(write_days(&work).len(), 1, "stale: written again");
        assert_eq!(work.write[0].summaries[0].summary, "late");
        put_update_db(&conn, "pa", "2026-11-03", &body, now).ok().unwrap();
        assert!(runner_db(&conn, "mac", now).ok().unwrap().write.is_empty());
        conn.execute("UPDATE project_updates SET rewrite_requested = 1", []).unwrap();
        assert_eq!(write_days(&runner_db(&conn, "mac", now).ok().unwrap()).len(), 1, "rewrite asked");
    }

    #[actix_web::test]
    async fn write_only_for_project_computer() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        let work = runner_db(&conn, "codbex", utc("2026-11-06 09:00:00")).ok().unwrap();
        assert!(work.write.is_empty() && work.projects.is_empty());
        assert!(!work.days.is_empty(), "codbex still summarizes its own conversations");
    }

    #[actix_web::test]
    async fn write_includes_completed_todos_in_window() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        conn.execute_batch(
            "INSERT INTO todos (id, title, section, project_id, completed, completed_at) VALUES
                 ('t1', 'EIN-5 in window', 'Si', 'pa', 1, '2026-11-03 10:00:00'),
                 ('t2', 'before window', 'Si', 'pa', 1, '2026-11-03 05:59:59'),
                 ('t3', 'open EIN-7', 'Si', 'pa', 0, NULL);",
        )
        .unwrap();
        report(&conn, "mac", "2026-11-03");
        let work = runner_db(&conn, "mac", utc("2026-11-04 08:01:00")).ok().unwrap();
        let w = &work.write[0];
        assert_eq!(w.completed_todos.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), vec!["EIN-5 in window"]);
        assert!(w.todo_titles.contains(&"open EIN-7".to_string()));
    }

    #[actix_web::test]
    async fn put_update_validates() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        let now = utc("2026-11-04 08:01:00");
        let long = PutUpdateRequest { text: "x".repeat(MAX_UPDATE + 1), commits: 0, generation: None };
        assert!(matches!(put_update_db(&conn, "pa", "2026-11-03", &long, now), Err(UpdateError::BadRequest(_))));
        let ok = PutUpdateRequest { text: "x".into(), commits: 0, generation: None };
        assert!(matches!(put_update_db(&conn, "nope", "2026-11-03", &ok, now), Err(UpdateError::NotFound(_))));
        assert!(matches!(put_update_db(&conn, "pa", "bad", &ok, now), Err(UpdateError::BadRequest(_))));
    }
    // --- Task 4: for the apps -----------------------------------------------------------

    fn put(conn: &Connection, day: &str, text: &str) {
        put_update_db(conn, "pa", day, &PutUpdateRequest { text: text.into(), commits: 1, generation: None }, utc("2026-11-04 08:01:00")).ok().unwrap();
    }

    #[actix_web::test]
    async fn list_updates_newest_first_hides_empty() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        put(&conn, "2026-11-01", "one");
        put(&conn, "2026-11-02", "");
        put(&conn, "2026-11-03", "three");
        let (status, body) = crate::test_support::get(&pool, "/api/projects/pa/updates").await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let days: Vec<&str> = body.as_array().unwrap().iter().map(|u| u["day"].as_str().unwrap()).collect();
        assert_eq!(days, vec!["2026-11-03", "2026-11-01"]);
        assert_eq!((&body[0]["commits"], &body[0]["rewriting"]), (&json!(1), &json!(false)));
    }

    #[actix_web::test]
    async fn list_updates_pages_with_before() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        for d in ["2026-11-01", "2026-11-02", "2026-11-03"] {
            put(&conn, d, "x");
        }
        let (_, body) = crate::test_support::get(&pool, "/api/projects/pa/updates?before=2026-11-03&limit=1").await;
        assert_eq!(body.as_array().unwrap().len(), 1);
        assert_eq!(body[0]["day"], "2026-11-02");
        let (status, _) = crate::test_support::get(&pool, "/api/projects/pa/updates?before=bad").await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn list_updates_counts_conversations() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        post(
            &pool,
            "/api/updates/summaries",
            json!({"computer_id": "mac", "day": "2026-11-03", "items": [item("s1", "~/w/a", "a"), item("s2", "~/w/a", "b")]}),
        )
        .await;
        put(&conn, "2026-11-03", "x");
        let (_, body) = crate::test_support::get(&pool, "/api/projects/pa/updates").await;
        assert_eq!(body[0]["conversations"], 2);
    }

    #[actix_web::test]
    async fn summaries_for_day() {
        let (_db, pool) = pool("updates");
        seed(&pool.get().unwrap());
        post(
            &pool,
            "/api/updates/summaries",
            json!({"computer_id": "mac", "day": "2026-11-03", "items": [item("s1", "~/w/a", "first"), item("s2", "~/w/a", "second")]}),
        )
        .await;
        let (status, body) = crate::test_support::get(&pool, "/api/projects/pa/updates/2026-11-03/summaries").await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body.as_array().unwrap().len(), 2);
        assert_eq!(
            (&body[0]["summary"], &body[0]["computer"], &body[0]["jira_keys"], &body[0]["todo_id"]),
            (&json!("first"), &json!("tsvetelins-macbook-pro"), &json!(["EIN-1"]), &json!(null))
        );
    }

    #[actix_web::test]
    async fn rewrite_flags_and_404() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (status, _) = post(&pool, "/api/projects/pa/updates/2026-11-03/rewrite", json!({})).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        put(&conn, "2026-11-03", "x");
        let (status, _) = post(&pool, "/api/projects/pa/updates/2026-11-03/rewrite", json!({})).await;
        assert_eq!(status, StatusCode::OK);
        let (_, body) = crate::test_support::get(&pool, "/api/projects/pa/updates").await;
        assert_eq!(body[0]["rewriting"], true);
    }

    #[actix_web::test]
    async fn cleanup_keeps_ninety_days() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        for d in ["2026-08-05", "2026-08-06"] {
            put(&conn, d, "x");
            report(&conn, "mac", d);
            summaries_db(
                &conn,
                &SummariesRequest {
                    computer_id: "mac".into(),
                    day: d.into(),
                    items: vec![SummaryItem {
                        tool: "claude".into(),
                        session_id: format!("s-{d}"),
                        cwd: "~/w/a".into(),
                        title: String::new(),
                        summary: "x".into(),
                        jira_keys: vec![],
                        model: String::new(),
                    }],
                },
            )
            .ok()
            .unwrap();
        }
        cleanup_db(&conn, utc("2026-11-04 10:00:00")).unwrap();
        for table in ["project_updates", "update_reports", "update_summaries"] {
            let days: Vec<String> = conn
                .prepare(&format!("SELECT day FROM {table}"))
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            assert_eq!(days, vec!["2026-08-06".to_string()], "{table}");
        }
    }
    // --- Final review fixes -------------------------------------------------------------

    #[actix_web::test]
    async fn write_waits_for_own_report_even_past_ten() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        let now = utc("2026-11-04 08:30:00"); // 10:30 Sofia: the Mac wakes with the 3rd unreported
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        assert_eq!(work.days, vec!["2026-11-03"]);
        assert!(work.write.is_empty(), "its own summaries come first");
        report(&conn, "mac", "2026-11-03");
        assert_eq!(write_days(&runner_db(&conn, "mac", now).ok().unwrap()).len(), 1);
    }

    fn late_summary(conn: &Connection, sid: &str) {
        summaries_db(
            conn,
            &SummariesRequest {
                computer_id: "mac".into(),
                day: "2026-11-03".into(),
                items: vec![SummaryItem {
                    tool: "claude".into(),
                    session_id: sid.into(),
                    cwd: "~/w/a".into(),
                    title: "T".into(),
                    summary: "late".into(),
                    jira_keys: vec![],
                    model: "haiku".into(),
                }],
            },
        )
        .ok()
        .unwrap();
    }

    #[actix_web::test]
    async fn summary_during_write_keeps_stale() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        seen(&conn, "mac", "2026-11-04 06:59:00");
        late_summary(&conn, "s1");
        report(&conn, "mac", "2026-11-03");
        let now = utc("2026-11-04 07:00:00");
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        let generation = work.write[0].generation;
        late_summary(&conn, "s2"); // arrives while the model writes
        put_update_db(&conn, "pa", "2026-11-03", &PutUpdateRequest { text: "v1".into(), commits: 0, generation: Some(generation) }, now)
            .ok()
            .unwrap();
        assert_eq!(write_days(&runner_db(&conn, "mac", now).ok().unwrap()).len(), 1, "written again with s2");
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        put_update_db(&conn, "pa", "2026-11-03", &PutUpdateRequest { text: "v2".into(), commits: 0, generation: Some(work.write[0].generation) }, now)
            .ok()
            .unwrap();
        assert!(runner_db(&conn, "mac", now).ok().unwrap().write.is_empty());
    }

    #[actix_web::test]
    async fn late_report_clears_waiting_on() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE projects SET daily_updates_since = '2026-11-03'", []).unwrap();
        seen(&conn, "mac", "2026-11-04 08:00:00");
        seen(&conn, "spread", "2026-11-04 06:00:00");
        report(&conn, "mac", "2026-11-03");
        let now = utc("2026-11-04 08:01:00");
        put(&conn, "2026-11-03", "x");
        report(&conn, "spread", "2026-11-03"); // nothing for pa, but no longer waited on
        let work = runner_db(&conn, "mac", now).ok().unwrap();
        assert_eq!(write_days(&work).len(), 1, "rewritten without the waiting note");
        put_update_db(&conn, "pa", "2026-11-03", &PutUpdateRequest { text: "y".into(), commits: 0, generation: Some(work.write[0].generation) }, now)
            .ok()
            .unwrap();
        let (_, body) = crate::test_support::get(&pool, "/api/projects/pa/updates").await;
        assert_eq!(body[0]["waiting_on"], json!([]));
    }

    #[actix_web::test]
    async fn rewrite_of_older_day_is_picked_up() {
        let (_db, pool) = pool("updates");
        let conn = pool.get().unwrap();
        seed(&conn);
        put(&conn, "2026-10-28", "old");
        rewrite_db(&conn, "pa", "2026-10-28").ok().unwrap();
        let work = runner_db(&conn, "mac", utc("2026-11-04 08:01:00")).ok().unwrap();
        assert!(write_days(&work).contains(&("pa".to_string(), "2026-10-28".to_string())));
    }
}
