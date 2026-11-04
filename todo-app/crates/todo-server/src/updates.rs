//! Daily updates per project. Each Mac's runner summarizes its own conversations for a day
//! (08:00 to 08:00 Sofia) and posts the summaries here; the project's computer then writes the
//! project's update from them. The hub makes no model calls.

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, server_error};
use crate::cron::TZ;
use crate::db::DbPool;

/// Longest stored conversation summary and title, in characters (longer ones are cut).
pub(crate) const MAX_SUMMARY: usize = 2000;
const MAX_TITLE: usize = 200;
const MAX_ITEMS: usize = 500;
/// The window starts and ends at this Sofia hour.
const DAY_START_HOUR: u32 = 8;

pub(crate) enum UpdateError {
    BadRequest(String),
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
        tx.execute(
            "INSERT INTO update_summaries (id, project_id, day, computer_id, tool, session_id, todo_id, title, summary, jira_keys, model)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT (project_id, day, tool, session_id) DO UPDATE SET
                computer_id = excluded.computer_id, todo_id = excluded.todo_id, title = excluded.title,
                summary = excluded.summary, jira_keys = excluded.jira_keys, model = excluded.model,
                created_at = datetime('now')",
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
}
