//! The weekly recap: weeks run Monday to Sunday in daily-update days (Sofia 08:00 to 08:00).

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use todo_shared::{WeeklyDayState, WeeklyJob, WeeklyJobs, WeeklyRecap, WeeklyRunLine, WeeklySection, WeeklyTotals};

use crate::broadcast::Broadcaster;
use crate::conversations::server_error;
use crate::cron::TZ;
use crate::db::DbPool;
use crate::scheduler::{parse_sql_time, sql_time};
use crate::updates::{day_window, on_projects, parse_day, respond, UpdateError, KEEP_DAYS, MAX_UPDATE};

const FALLBACK_HOUR: u32 = 10;

fn fmt(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

fn monday(d: NaiveDate) -> NaiveDate {
    d - Duration::days(i64::from(d.weekday().num_days_from_monday()))
}

/// The Monday of the week that `day` (YYYY-MM-DD) belongs to.
pub(crate) fn week_of_day(day: &str) -> Option<String> {
    Some(fmt(monday(parse_day(day)?)))
}

/// The seven days of the week starting on `week` (which must be a Monday).
pub(crate) fn week_days(week: &str) -> Option<Vec<String>> {
    let start = parse_day(week)?;
    if start.weekday().num_days_from_monday() != 0 {
        return None;
    }
    Some((0..7).map(|i| fmt(start + Duration::days(i))).collect())
}

/// The week of the daily-update day that contains `t`.
pub(crate) fn week_of_time(t: DateTime<Utc>) -> String {
    let local = t.with_timezone(&TZ).naive_local() - Duration::hours(8);
    fmt(monday(local.date()))
}

/// The most recent week that has ended at `now` (its end is `week + 7` 08:00 Sofia).
pub(crate) fn last_finished_week(now: DateTime<Utc>) -> Option<String> {
    let current = parse_day(&week_of_time(now))?;
    Some(fmt(current - Duration::days(7)))
}

/// When a week's recap is written anyway if its projects' updates are not all in: `week + 7` 10:00 Sofia.
pub(crate) fn week_fallback(week: &str) -> Option<DateTime<Utc>> {
    let next = parse_day(week)? + Duration::days(7);
    let local = next.and_time(NaiveTime::from_hms_opt(FALLBACK_HOUR, 0, 0)?);
    TZ.from_local_datetime(&local).single().map(|t| t.with_timezone(&Utc))
}

/// The start of a week: Sofia 08:00 on its Monday.
pub(crate) fn week_start(week: &str) -> Option<DateTime<Utc>> {
    Some(day_window(week)?.0)
}

/// The leading number of a watch result like "2 new issues", else 0.
fn new_findings(result: &str) -> u32 {
    let digits: String = result.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() || !result[digits.len()..].starts_with(" new") {
        return 0;
    }
    digits.parse().unwrap_or(0)
}

type RunRow = (String, String, String, String, Option<String>, Option<String>, Option<String>, String, String);

/// Adds every settled run not yet counted to its week's per-job tally, so the numbers outlive
/// the runs (watch upkeep deletes old ones and deleting a job cascades). Returns runs counted.
pub(crate) fn tally_settled_runs(conn: &Connection) -> rusqlite::Result<usize> {
    atomically(conn, "weekly_tally", tally_runs)
}

/// Runs `f` in a savepoint (nests inside any open transaction): its writes all land or none do.
fn atomically<T>(conn: &Connection, name: &str, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> rusqlite::Result<T> {
    conn.execute_batch(&format!("SAVEPOINT {name}"))?;
    match f(conn) {
        Ok(v) => {
            conn.execute_batch(&format!("RELEASE {name}"))?;
            Ok(v)
        }
        Err(e) => {
            let _ = conn.execute_batch(&format!("ROLLBACK TO {name}; RELEASE {name}"));
            Err(e)
        }
    }
}

/// The tick's weekly bookkeeping: a failure is logged and rolled back, never blocks scheduling.
pub(crate) fn weekly_upkeep_logged(conn: &Connection, now: DateTime<Utc>, snapshot: bool) {
    let result = if snapshot { snapshot_finished_weeks(conn, now).map(|_| ()) } else { tally_settled_runs(conn).map(|_| ()) };
    if let Err(e) = result {
        println!("weekly recap upkeep failed: {e}");
    }
}

fn tally_runs(conn: &Connection) -> rusqlite::Result<usize> {
    let rows: Vec<RunRow> = {
        let mut stmt = conn.prepare(
            "SELECT r.id, r.job_id, r.due_at, r.state, r.result, r.todo_id,
                    json_extract(j.action, '$.kind'), j.name,
                    COALESCE((SELECT p.name FROM projects p WHERE p.id = json_extract(j.action, '$.project_id')), '')
             FROM job_runs r JOIN jobs j ON j.id = r.job_id
             WHERE r.state IN ('done','failed','skipped','missed') AND r.tallied = 0
             ORDER BY r.due_at",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?))
        })?;
        mapped.collect::<rusqlite::Result<_>>()?
    };
    let mut counted = 0;
    for (id, job_id, due_at, state, result, todo_id, kind, name, project_name) in &rows {
        let Some(due) = parse_sql_time(due_at) else { continue };
        let week = week_of_time(due);
        let result = result.as_deref().unwrap_or("");
        let is_watch = kind.as_deref() == Some("watch");
        let (mut runs, mut done, mut failed, mut skipped, mut checks, mut findings) = (0, 0, 0, 0, 0, 0);
        if is_watch && (result == "quiet" || state == "skipped") {
            checks = 1;
        } else {
            runs = 1;
            match state.as_str() {
                "done" => done = 1,
                "skipped" => skipped = 1,
                _ => failed = 1,
            }
            if is_watch {
                findings = new_findings(result);
            }
        }
        let started = i64::from(result.starts_with("started "));
        conn.execute(
            "INSERT INTO weekly_job_tallies (week, job_id, job_name, project_name, is_watch, runs, done, failed, skipped,
                                             checks, findings, todos_created, conversations_started)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(week, job_id) DO UPDATE SET
                job_name = excluded.job_name, project_name = excluded.project_name, is_watch = excluded.is_watch,
                runs = runs + excluded.runs, done = done + excluded.done, failed = failed + excluded.failed,
                skipped = skipped + excluded.skipped, checks = checks + excluded.checks,
                findings = findings + excluded.findings, todos_created = todos_created + excluded.todos_created,
                conversations_started = conversations_started + excluded.conversations_started",
            params![
                week, job_id, name, project_name, i64::from(is_watch), runs, done, failed, skipped, checks, findings,
                i64::from(todo_id.is_some()), started
            ],
        )?;
        conn.execute("UPDATE job_runs SET tallied = 1 WHERE id = ?1", params![id])?;
        counted += 1;
    }
    Ok(counted)
}

/// A week's jobs from the tallies plus the runs still present (quiet watch checks are not lines).
pub(crate) fn live_jobs(conn: &Connection, week: &str) -> rusqlite::Result<WeeklyJobs> {
    let mut jobs: Vec<WeeklyJob> = {
        let mut stmt = conn.prepare(
            "SELECT job_id, job_name, project_name, is_watch, runs, done, failed, skipped, checks, findings
             FROM weekly_job_tallies WHERE week = ?1 ORDER BY project_name, job_name, job_id",
        )?;
        let mapped = stmt.query_map(params![week], |r| {
            Ok(WeeklyJob {
                job_id: r.get(0)?,
                name: r.get(1)?,
                project_name: r.get(2)?,
                is_watch: r.get::<_, i64>(3)? != 0,
                runs: r.get(4)?,
                done: r.get(5)?,
                failed: r.get(6)?,
                skipped: r.get(7)?,
                checks: r.get(8)?,
                findings: r.get(9)?,
                lines: Vec::new(),
            })
        })?;
        mapped.collect::<rusqlite::Result<_>>()?
    };
    let (mut todos_created, mut conversations_started) = (0, 0);
    conn.query_row(
        "SELECT COALESCE(SUM(todos_created), 0), COALESCE(SUM(conversations_started), 0) FROM weekly_job_tallies WHERE week = ?1",
        params![week],
        |r| {
            todos_created = r.get(0)?;
            conversations_started = r.get(1)?;
            Ok(())
        },
    )?;
    if let Some(start) = week_start(week) {
        let mut stmt = conn.prepare(
            "SELECT r.job_id, r.id, r.due_at, r.state, COALESCE(t.title, r.result, ''), r.todo_id
             FROM job_runs r JOIN jobs j ON j.id = r.job_id LEFT JOIN todos t ON t.id = r.todo_id
             WHERE r.state IN ('done','failed','skipped','missed') AND r.due_at >= ?1 AND r.due_at < ?2
               AND NOT (COALESCE(json_extract(j.action, '$.kind'), '') = 'watch'
                        AND (r.state = 'skipped' OR COALESCE(r.result, '') = 'quiet'))
             ORDER BY (r.state IN ('failed','missed')) DESC, COALESCE(t.completed, 1) ASC, r.due_at DESC, r.id",
        )?;
        let mapped = stmt.query_map(params![sql_time(start), sql_time(start + Duration::days(7))], |r| {
            Ok((
                r.get::<_, String>(0)?,
                WeeklyRunLine { run_id: r.get(1)?, due_at: r.get(2)?, state: r.get(3)?, outcome: r.get(4)?, todo_id: r.get(5)? },
            ))
        })?;
        for line in mapped {
            let (job_id, line) = line?;
            if let Some(job) = jobs.iter_mut().find(|j| j.job_id == job_id) {
                job.lines.push(line);
            }
        }
    }
    Ok(WeeklyJobs {
        runs: jobs.iter().map(|j| j.runs).sum(),
        done: jobs.iter().map(|j| j.done).sum(),
        failed: jobs.iter().map(|j| j.failed).sum(),
        skipped: jobs.iter().map(|j| j.skipped).sum(),
        findings: jobs.iter().map(|j| j.findings).sum(),
        todos_created,
        conversations_started,
        jobs,
    })
}

/// Stores the jobs snapshot of the last finished week once, when its recap is due.
/// Returns how many snapshots were taken.
pub(crate) fn snapshot_finished_weeks(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize> {
    atomically(conn, "weekly_snapshot", |c| snapshot_week(c, now))
}

fn snapshot_week(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize> {
    let Some(week) = last_finished_week(now) else { return Ok(0) };
    if week_fallback(&week).is_none_or(|t| now < t) {
        return Ok(0);
    }
    let have: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM weekly_jobs WHERE week = ?1)", params![week], |r| r.get(0))?;
    if have {
        return Ok(0);
    }
    tally_settled_runs(conn)?;
    let snapshot = live_jobs(conn, &week)?;
    let json = serde_json::to_string(&snapshot).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    conn.execute(
        "INSERT OR IGNORE INTO weekly_jobs (week, snapshot, taken_at) VALUES (?1, ?2, ?3)",
        params![week, json, sql_time(now)],
    )
}

/// A daily update the runner stores when the model failed three times starts with this.
pub(crate) const WRITE_FAILED_PREFIX: &str = "_This update couldn't be written";
const MAX_HEADLINE: usize = 200;

#[derive(Debug, Serialize)]
pub struct WeeklyDaySummary {
    pub title: String,
    pub summary: String,
}

#[derive(Debug, Serialize)]
pub struct WeeklyDay {
    pub day: String,
    /// "update", "quiet", "failed", "missing" or "untracked".
    pub state: String,
    /// The daily update; only for "update".
    pub text: String,
    /// Conversation summaries; only for "failed" and "missing" days.
    pub summaries: Vec<WeeklyDaySummary>,
}

#[derive(Debug, Serialize)]
pub struct WeeklyItem {
    pub project_id: String,
    pub project_name: String,
    pub week: String,
    pub style: String,
    pub days: Vec<WeeklyDay>,
}

fn week_day_states(
    conn: &Connection,
    project_id: &str,
    since: &str,
    week: &str,
) -> rusqlite::Result<Vec<WeeklyDay>> {
    let mut out = Vec::new();
    for day in week_days(week).unwrap_or_default() {
        let mut item = WeeklyDay {
            day: day.clone(),
            state: String::new(),
            text: String::new(),
            summaries: Vec::new(),
        };
        if day.as_str() < since {
            item.state = "untracked".into();
            out.push(item);
            continue;
        }
        let row: Option<String> = conn
            .query_row(
                "SELECT text FROM project_updates WHERE project_id = ?1 AND day = ?2",
                params![project_id, day],
                |r| r.get(0),
            )
            .optional()?;
        match row {
            Some(t) if t.is_empty() => item.state = "quiet".into(),
            Some(t) if t.starts_with(WRITE_FAILED_PREFIX) => item.state = "failed".into(),
            Some(t) => {
                item.state = "update".into();
                item.text = t;
            }
            None => item.state = "missing".into(),
        }
        if item.state == "failed" || item.state == "missing" {
            let mut stmt = conn.prepare(
                "SELECT title, summary FROM update_summaries WHERE project_id = ?1 AND day = ?2 AND failed = 0 ORDER BY created_at, rowid",
            )?;
            item.summaries = stmt
                .query_map(params![project_id, day], |r| {
                    Ok(WeeklyDaySummary {
                        title: r.get(0)?,
                        summary: r.get(1)?,
                    })
                })?
                .collect::<rusqlite::Result<_>>()?;
        }
        out.push(item);
    }
    Ok(out)
}

/// Sunday's daily update is in and settled, or the week's fallback time has passed.
fn week_ready(
    conn: &Connection,
    project_id: &str,
    week: &str,
    now: DateTime<Utc>,
) -> rusqlite::Result<bool> {
    if week_fallback(week).is_some_and(|f| now >= f) {
        return Ok(true);
    }
    let Some(sunday) = week_days(week).and_then(|d| d.last().cloned()) else {
        return Ok(false);
    };
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM project_updates WHERE project_id = ?1 AND day = ?2 AND rewrite_requested = 0 AND stale = 0)",
        params![project_id, sunday],
        |r| r.get(0),
    )
}

/// The recaps `computer_id` should write now: the last finished week of its projects once
/// ready (when it has work to recap and no recap yet), and any week asked to be rewritten
/// or gone stale.
pub(crate) fn weekly_items(
    conn: &Connection,
    computer_id: &str,
    now: DateTime<Utc>,
) -> rusqlite::Result<Vec<WeeklyItem>> {
    let last = last_finished_week(now);
    let mut out = Vec::new();
    for p in on_projects(conn)?
        .iter()
        .filter(|p| p.computer_id == computer_id)
    {
        let mut stmt =
            conn.prepare("SELECT week FROM weekly_recaps WHERE project_id = ?1 AND (rewrite_requested = 1 OR stale = 1) ORDER BY week")?;
        let flagged = stmt
            .query_map(params![p.id], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut weeks: Vec<(String, bool)> = flagged.into_iter().map(|w| (w, false)).collect();
        if let Some(week) = &last {
            let have: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM weekly_recaps WHERE week = ?1 AND project_id = ?2)",
                params![week, p.id],
                |r| r.get(0),
            )?;
            if !have && week_ready(conn, &p.id, week, now)? {
                weeks.push((week.clone(), true));
            }
        }
        for (week, fresh) in weeks {
            let days = week_day_states(conn, &p.id, &p.since, &week)?;
            // Material: an update, or summaries on a day without one. Without it the model would invent a recap.
            let material = days.iter().any(|d| d.state == "update" || !d.summaries.is_empty());
            if fresh {
                // A fresh week with nothing to recap is not offered (no row is written).
                if !material || !days.iter().any(|d| d.state == "update" || d.state == "failed") {
                    continue;
                }
            } else if !material {
                // A flagged week whose daily updates are gone keeps its text: clear the flags.
                conn.execute(
                    "UPDATE weekly_recaps SET rewrite_requested = 0, stale = 0 WHERE project_id = ?1 AND week = ?2",
                    params![p.id, week],
                )?;
                continue;
            }
            out.push(WeeklyItem {
                project_id: p.id.clone(),
                project_name: p.name.clone(),
                week,
                style: p.style.clone(),
                days,
            });
        }
    }
    Ok(out)
}

#[derive(Debug, Deserialize)]
pub struct PutWeeklyRequest {
    pub headline: String,
    #[serde(default)]
    pub wins: String,
    #[serde(default)]
    pub failed: bool,
}

fn checked_week(week: &str) -> Result<Vec<String>, UpdateError> {
    week_days(week)
        .ok_or_else(|| UpdateError::BadRequest("week must be the YYYY-MM-DD of a Monday".into()))
}

pub(crate) fn put_weekly_db(
    conn: &Connection,
    project_id: &str,
    week: &str,
    req: &PutWeeklyRequest,
    now: DateTime<Utc>,
) -> Result<(), UpdateError> {
    let days = checked_week(week)?;
    if req.headline.chars().count() > MAX_HEADLINE {
        return Err(UpdateError::BadRequest(format!(
            "headline is limited to {MAX_HEADLINE} characters"
        )));
    }
    if req.wins.chars().count() > MAX_UPDATE {
        return Err(UpdateError::BadRequest(format!(
            "wins are limited to {MAX_UPDATE} characters"
        )));
    }
    let (name, since) =
        project_row(conn, project_id)?.ok_or(UpdateError::NotFound("Project not found"))?;
    // Only days daily updates tracked count: from `since` on, within the week.
    let first = if since.as_str() > days[0].as_str() { since.clone() } else { days[0].clone() };
    let (mut commits, mut with_work) = (0i64, 0i64);
    let states: Vec<serde_json::Value> = week_day_states(conn, project_id, &since, week)?
        .into_iter()
        .map(|d| {
            with_work += i64::from(d.state == "update");
            serde_json::json!({"day": d.day, "state": d.state})
        })
        .collect();
    commits += conn.query_row(
        "SELECT COALESCE(SUM(commits), 0) FROM project_updates WHERE project_id = ?1 AND day >= ?2 AND day <= ?3",
        params![project_id, first, days[6]],
        |r| r.get::<_, i64>(0),
    )?;
    let conversations: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT tool || ':' || session_id) FROM update_summaries WHERE project_id = ?1 AND day >= ?2 AND day <= ?3",
        params![project_id, first, days[6]],
        |r| r.get(0),
    )?;
    conn.execute(
        "INSERT INTO weekly_recaps (week, project_id, project_name, headline, wins, failed, days, commits, conversations,
                                    days_with_work, written_at, rewrite_requested, stale)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, 0)
         ON CONFLICT (week, project_id) DO UPDATE SET project_name = excluded.project_name, headline = excluded.headline,
            wins = excluded.wins, failed = excluded.failed, days = excluded.days, commits = excluded.commits,
            conversations = excluded.conversations, days_with_work = excluded.days_with_work,
            written_at = excluded.written_at, rewrite_requested = 0, stale = 0",
        params![
            week,
            project_id,
            name,
            req.headline.trim(),
            req.wins.trim(),
            i64::from(req.failed),
            serde_json::Value::Array(states).to_string(),
            commits,
            conversations,
            with_work,
            sql_time(now),
        ],
    )?;
    Ok(())
}

/// The project's name and daily-updates start day ('' when unset), if the project exists.
fn project_row(conn: &Connection, project_id: &str) -> rusqlite::Result<Option<(String, String)>> {
    conn.query_row(
        "SELECT name, COALESCE(daily_updates_since, '') FROM projects WHERE id = ?1",
        params![project_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
}

pub async fn put_weekly(
    pool: web::Data<DbPool>,
    broadcaster: web::Data<Broadcaster>,
    path: web::Path<(String, String)>,
    req: web::Json<PutWeeklyRequest>,
) -> HttpResponse {
    let (project_id, week) = path.into_inner();
    match pool.get() {
        Ok(conn) => match put_weekly_db(&conn, &project_id, &week, &req, Utc::now()) {
            Ok(()) => {
                broadcaster.send();
                HttpResponse::Ok().json(serde_json::json!({"week": week}))
            }
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

pub(crate) fn rewrite_weekly_db(
    conn: &Connection,
    project_id: &str,
    week: &str,
    now: DateTime<Utc>,
) -> Result<(), UpdateError> {
    checked_week(week)?;
    // The week's daily updates go after 90 days; a rewrite from nothing would wipe or invent the recap.
    let cutoff = fmt(now.with_timezone(&TZ).date_naive() - Duration::days(KEEP_DAYS));
    if week < cutoff.as_str() {
        return Err(UpdateError::BadRequest(
            "this week's daily updates are no longer kept, so it can't be rewritten".into(),
        ));
    }
    let on: Option<bool> = conn
        .query_row(
            "SELECT daily_updates = 1 FROM projects WHERE id = ?1",
            params![project_id],
            |r| r.get(0),
        )
        .optional()?;
    if on == Some(false) {
        return Err(UpdateError::Conflict("Daily updates are off for this project"));
    }
    let n = conn.execute(
        "UPDATE weekly_recaps SET rewrite_requested = 1 WHERE project_id = ?1 AND week = ?2",
        params![project_id, week],
    )?;
    if n == 0 {
        return Err(UpdateError::NotFound("No recap for that week"));
    }
    Ok(())
}

pub async fn rewrite_weekly(
    pool: web::Data<DbPool>,
    broadcaster: web::Data<Broadcaster>,
    path: web::Path<(String, String)>,
) -> HttpResponse {
    let (project_id, week) = path.into_inner();
    match pool.get() {
        Ok(conn) => match rewrite_weekly_db(&conn, &project_id, &week, Utc::now()) {
            Ok(()) => {
                broadcaster.send();
                HttpResponse::Ok().json(serde_json::json!({"ok": true}))
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

const LIST_DEFAULT: u32 = 4;
const LIST_MAX: u32 = 12;

pub(crate) fn list_weekly_db(conn: &Connection, q: &ListQuery) -> Result<Vec<WeeklyRecap>, UpdateError> {
    if let Some(before) = &q.before {
        checked_week(before)?;
    }
    let limit = q.limit.unwrap_or(LIST_DEFAULT).clamp(1, LIST_MAX);
    let mut weeks_stmt = conn.prepare(
        "SELECT week FROM (SELECT week FROM weekly_recaps UNION SELECT week FROM weekly_jobs)
         WHERE (?1 IS NULL OR week < ?1) ORDER BY week DESC",
    )?;
    let weeks: Vec<String> = weeks_stmt.query_map(params![q.before], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    let mut sections_stmt = conn.prepare(
        "SELECT project_id, project_name, headline, wins, failed,
                (rewrite_requested = 1 OR stale = 1)
                    AND EXISTS(SELECT 1 FROM projects p WHERE p.id = weekly_recaps.project_id AND p.daily_updates = 1),
                0, commits, conversations, days_with_work, days, written_at
         FROM weekly_recaps WHERE week = ?1 AND (failed = 1 OR wins != '')
         ORDER BY conversations DESC, project_name, project_id",
    )?;
    let mut out = Vec::new();
    for week in weeks {
        if out.len() >= limit as usize {
            break;
        }
        let sections: Vec<WeeklySection> = sections_stmt
            .query_map(params![week], |r| {
                let days: String = r.get(10)?;
                Ok(WeeklySection {
                    project_id: r.get(0)?,
                    project_name: r.get(1)?,
                    headline: r.get(2)?,
                    wins: r.get(3)?,
                    failed: r.get::<_, i64>(4)? != 0,
                    rewriting: r.get::<_, i64>(5)? != 0 || r.get::<_, i64>(6)? != 0,
                    commits: r.get(7)?,
                    conversations: r.get(8)?,
                    days_with_work: r.get(9)?,
                    days: serde_json::from_str::<Vec<WeeklyDayState>>(&days).unwrap_or_default(),
                    written_at: r.get(11)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?;
        let snapshot: Option<String> = conn
            .query_row("SELECT snapshot FROM weekly_jobs WHERE week = ?1", params![week], |r| r.get(0))
            .optional()?;
        // Until the snapshot is taken (Monday 10:00) the week's jobs come from the tallies, which every tick keeps current.
        let jobs: Option<WeeklyJobs> = match snapshot {
            Some(s) => serde_json::from_str(&s).ok(),
            None => Some(live_jobs(conn, &week)?),
        };
        let totals = WeeklyTotals {
            commits: sections.iter().map(|s| s.commits).sum(),
            conversations: sections.iter().map(|s| s.conversations).sum(),
            runs: jobs.as_ref().map_or(0, |j| j.runs),
        };
        // A week with nothing to show (e.g. a snapshot written empty by the migration) is not listed.
        let active = jobs.as_ref().is_some_and(|j| j.runs > 0 || j.jobs.iter().any(|x| x.checks > 0));
        if sections.is_empty() && !active {
            continue;
        }
        out.push(WeeklyRecap { week, totals, sections, jobs });
    }
    Ok(out)
}

pub async fn list_weekly(pool: web::Data<DbPool>, q: web::Query<ListQuery>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => match list_weekly_db(&conn, &q) {
            Ok(v) => HttpResponse::Ok().json(v),
            Err(e) => respond(e),
        },
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn week_of_day_is_the_monday() {
        assert_eq!(week_of_day("2026-11-08").as_deref(), Some("2026-11-02"));
        assert_eq!(week_of_day("2026-11-09").as_deref(), Some("2026-11-09"));
        assert_eq!(week_of_day("nope"), None);
    }

    #[test]
    fn week_days_are_seven() {
        let d = week_days("2026-11-02").unwrap();
        assert_eq!(d.len(), 7);
        assert_eq!(d[0], "2026-11-02");
        assert_eq!(d[6], "2026-11-08");
        assert_eq!(week_days("2026-11-03"), None);
    }

    #[test]
    fn week_of_time_shifts_eight_hours() {
        assert_eq!(week_of_time(utc("2026-11-09T05:59:00Z")), "2026-11-02");
        assert_eq!(week_of_time(utc("2026-11-09T06:00:00Z")), "2026-11-09");
    }

    #[test]
    fn last_finished_week_ends_monday_eight() {
        assert_eq!(last_finished_week(utc("2026-11-09T06:00:00Z")).as_deref(), Some("2026-11-02"));
        assert_eq!(last_finished_week(utc("2026-11-09T05:59:00Z")).as_deref(), Some("2026-10-26"));
    }

    #[test]
    fn dst_boundary_weeks() {
        assert_eq!(week_fallback("2026-10-19"), Some(utc("2026-10-26T08:00:00Z")));
        assert_eq!(week_of_time(utc("2026-10-26T05:59:00Z")), "2026-10-19");
        assert_eq!(week_of_time(utc("2026-10-26T06:00:00Z")), "2026-10-26");
    }

    #[test]
    fn fallback_is_monday_ten() {
        assert_eq!(week_fallback("2026-11-02"), Some(utc("2026-11-09T08:00:00Z")));
    }

    use crate::test_support::pool;
    use rusqlite::Connection;

    const TODO_JOB: &str = r#"{"kind":"conversation","project_id":"pa"}"#;
    const WATCH_JOB: &str = r#"{"kind":"watch","project_id":"pa"}"#;

    fn seed(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'Alpha', 'Si', '~/a');
             INSERT INTO todos (id, section, title, completed) VALUES ('open1', 'Si', 'Open todo', 0), ('shut1', 'Si', 'Shut todo', 1);",
        )
        .unwrap();
        for (id, name, action) in [("j", "Research", TODO_JOB), ("w", "Sentry", WATCH_JOB)] {
            conn.execute(
                "INSERT INTO jobs (id, name, trigger, action) VALUES (?1, ?2, '{\"kind\":\"manual\"}', ?3)",
                params![id, name, action],
            )
            .unwrap();
        }
    }

    fn run(conn: &Connection, job: &str, due: &str, state: &str, result: Option<&str>, todo: Option<&str>) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, result, todo_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, job, due, state, result, todo],
        )
        .unwrap();
        id
    }

    type Tally = (u32, u32, u32, u32, u32, u32, u32, u32);

    fn tally(conn: &Connection, week: &str, job: &str) -> Tally {
        conn.query_row(
            "SELECT runs, done, failed, skipped, checks, findings, todos_created, conversations_started
             FROM weekly_job_tallies WHERE week = ?1 AND job_id = ?2",
            params![week, job],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?)),
        )
        .unwrap()
    }

    #[test]
    fn tally_counts_runs_by_week() {
        let (_db, pool) = pool("tally-week");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-03 09:00:00", "done", Some("started claude"), Some("open1"));
        run(&conn, "j", "2026-11-04 09:00:00", "done", Some("ok"), None);
        run(&conn, "j", "2026-11-05 09:00:00", "failed", Some("boom"), None);
        run(&conn, "j", "2026-11-06 09:00:00", "missed", None, None);
        run(&conn, "j", "2026-11-05 09:00:00", "due", None, None);
        assert_eq!(tally_settled_runs(&conn).unwrap(), 4);
        assert_eq!(tally(&conn, "2026-11-02", "j"), (4, 2, 2, 0, 0, 0, 1, 1));
        let name: (String, String) = conn
            .query_row("SELECT job_name, project_name FROM weekly_job_tallies WHERE job_id = 'j'", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert_eq!(name, ("Research".into(), "Alpha".into()));
        assert_eq!(tally_settled_runs(&conn).unwrap(), 0);
    }

    #[test]
    fn tally_watch_checks_and_findings() {
        let (_db, pool) = pool("tally-watch");
        let conn = pool.get().unwrap();
        seed(&conn);
        for h in 1..=3 {
            run(&conn, "w", &format!("2026-11-03 0{h}:00:00"), "done", Some("quiet"), None);
        }
        run(&conn, "w", "2026-11-03 05:00:00", "done", Some("2 new"), None);
        run(&conn, "w", "2026-11-03 06:00:00", "failed", Some("x"), None);
        tally_settled_runs(&conn).unwrap();
        assert_eq!(tally(&conn, "2026-11-02", "w"), (2, 1, 1, 0, 3, 2, 0, 0));
    }

    #[test]
    fn tally_survives_watch_prune() {
        let (_db, pool) = pool("tally-prune");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "w", "2026-11-03 01:00:00", "done", Some("quiet"), None);
        run(&conn, "w", "2026-11-03 02:00:00", "failed", Some("x"), None);
        tally_settled_runs(&conn).unwrap();
        let later = utc("2026-11-03T00:00:00Z") + Duration::days(3);
        crate::watch::watch_upkeep(&conn, later).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
        assert_eq!(tally(&conn, "2026-11-02", "w"), (1, 0, 1, 0, 1, 0, 0, 0));
        assert_eq!(tally_settled_runs(&conn).unwrap(), 0);
        assert_eq!(tally(&conn, "2026-11-02", "w"), (1, 0, 1, 0, 1, 0, 0, 0));
    }

    #[actix_web::test]
    async fn delete_job_tallies_first() {
        let (_db, pool) = pool("tally-delete");
        {
            let conn = pool.get().unwrap();
            seed(&conn);
            run(&conn, "j", "2026-11-03 09:00:00", "done", Some("ok"), None);
        }
        assert_eq!(crate::test_support::delete(&pool, "/api/jobs/j").await.0, actix_web::http::StatusCode::OK);
        let conn = pool.get().unwrap();
        let name: String = conn.query_row("SELECT job_name FROM weekly_job_tallies WHERE job_id = 'j'", [], |r| r.get(0)).unwrap();
        assert_eq!(name, "Research");
        assert_eq!(tally(&conn, "2026-11-02", "j").0, 1);
    }

    #[test]
    fn snapshot_once_after_fallback() {
        let (_db, pool) = pool("snapshot");
        let conn = pool.get().unwrap();
        seed(&conn);
        let plain = run(&conn, "j", "2026-11-03 09:00:00", "done", Some("fine"), Some("shut1"));
        let opened = run(&conn, "j", "2026-11-04 09:00:00", "done", Some("fine"), Some("open1"));
        let failed = run(&conn, "j", "2026-11-02 09:00:00", "failed", Some("boom"), None);
        run(&conn, "w", "2026-11-03 09:00:00", "done", Some("quiet"), None);
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T07:59:00Z")).unwrap(), 0);
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM weekly_jobs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T08:00:00Z")).unwrap(), 1);
        let (json, taken): (String, String) =
            conn.query_row("SELECT snapshot, taken_at FROM weekly_jobs WHERE week = '2026-11-02'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        let snap: WeeklyJobs = serde_json::from_str(&json).unwrap();
        assert_eq!((snap.runs, snap.done, snap.failed, snap.todos_created), (3, 2, 1, 2));
        let job = snap.jobs.iter().find(|j| j.job_id == "j").unwrap();
        let ids: Vec<&str> = job.lines.iter().map(|l| l.run_id.as_str()).collect();
        assert_eq!(ids, [failed.as_str(), opened.as_str(), plain.as_str()]);
        assert_eq!(job.lines[1].outcome, "Open todo");
        assert_eq!(job.lines[0].outcome, "boom");
        let sentry = snap.jobs.iter().find(|j| j.job_id == "w").unwrap();
        assert_eq!((sentry.checks, sentry.lines.len()), (1, 0));
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T09:00:00Z")).unwrap(), 0);
        let again: String = conn.query_row("SELECT taken_at FROM weekly_jobs", [], |r| r.get(0)).unwrap();
        assert_eq!(again, taken);
    }

    #[test]
    fn weeks_split_at_monday_eight() {
        let (_db, pool) = pool("tally-split");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-09 05:59:00", "done", Some("a"), None);
        run(&conn, "j", "2026-11-09 06:00:00", "done", Some("b"), None);
        run(&conn, "j", "garbage", "done", Some("c"), None);
        assert_eq!(tally_settled_runs(&conn).unwrap(), 2);
        assert_eq!(tally(&conn, "2026-11-02", "j").0, 1);
        assert_eq!(tally(&conn, "2026-11-09", "j").0, 1);
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE tallied = 0", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 1);
    }

    #[test]
    fn check_runs_are_not_snapshot_lines() {
        let (_db, pool) = pool("lines-checks");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "w", "2026-11-03 01:00:00", "done", Some("quiet"), None);
        run(&conn, "w", "2026-11-03 02:00:00", "skipped", Some("busy"), None);
        let kept = run(&conn, "w", "2026-11-03 03:00:00", "done", Some("1 new"), None);
        tally_settled_runs(&conn).unwrap();
        let jobs = live_jobs(&conn, "2026-11-02").unwrap();
        assert_eq!(jobs.jobs[0].checks, 2);
        let ids: Vec<&str> = jobs.jobs[0].lines.iter().map(|l| l.run_id.as_str()).collect();
        assert_eq!(ids, [kept.as_str()]);
    }

    #[test]
    fn failed_tally_rolls_back_and_tick_continues() {
        let (_db, pool) = pool("tally-fails");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-03 09:00:00", "done", Some("ok"), None);
        run(&conn, "w", "2026-10-01 01:00:00", "done", Some("quiet"), None);
        conn.execute_batch("DROP TABLE weekly_job_tallies").unwrap();
        assert!(tally_settled_runs(&conn).is_err());
        let untallied: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE tallied = 0", [], |r| r.get(0)).unwrap();
        assert_eq!(untallied, 2);
        // The tick still runs: the old quiet check is pruned although tallying failed.
        crate::scheduler::tick_db(&conn, utc("2026-11-09T09:00:00Z")).unwrap();
        let pruned: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE job_id = 'w'", [], |r| r.get(0)).unwrap();
        assert_eq!(pruned, 0);
    }

    // --- Runner work, PUT, rewrite, stale ---------------------------------------------

    use crate::test_support::{post, put, seed_computers};

    const WEEK: &str = "2026-11-02";

    fn seed_updates(conn: &Connection, since: &str) {
        seed_computers(conn);
        conn.execute(
            "INSERT INTO projects (id, name, section, folder, daily_updates, daily_updates_since) VALUES ('pa', 'Alpha', 'Si', '~/w/a', 1, ?1)",
            params![since],
        )
        .unwrap();
    }

    fn daily(conn: &Connection, day: &str, text: &str, commits: u32) {
        conn.execute(
            "INSERT OR REPLACE INTO project_updates (project_id, day, text, commits) VALUES ('pa', ?1, ?2, ?3)",
            params![day, text, commits],
        )
        .unwrap();
    }

    fn summary(conn: &Connection, day: &str, session: &str, failed: i64) {
        conn.execute(
            "INSERT INTO update_summaries (id, project_id, day, computer_id, tool, session_id, title, summary, failed)
             VALUES (?1, 'pa', ?2, 'mac', 'claude', ?3, ?4, ?5, ?6)",
            params![uuid::Uuid::new_v4().to_string(), day, session, format!("T {session}"), format!("S {session}"), failed],
        )
        .unwrap();
    }

    fn items(conn: &Connection, now: &str) -> Vec<WeeklyItem> {
        weekly_items(conn, "mac", utc(now)).unwrap()
    }

    fn states(item: &WeeklyItem) -> Vec<&str> {
        item.days.iter().map(|d| d.state.as_str()).collect()
    }

    #[test]
    fn weekly_not_offered_before_ready() {
        let (_db, pool) = pool("wk-notready");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "did things", 1);
        assert!(items(&conn, "2026-11-09T06:05:00Z").is_empty());
    }

    #[test]
    fn weekly_ready_when_sunday_quiet() {
        let (_db, pool) = pool("wk-sunday");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "did things", 1);
        daily(&conn, "2026-11-08", "", 0);
        let got = items(&conn, "2026-11-09T06:05:00Z");
        assert_eq!(got.len(), 1);
        assert_eq!(
            (got[0].week.as_str(), got[0].project_name.as_str()),
            (WEEK, "Alpha")
        );
        assert_eq!(
            states(&got[0]),
            ["missing", "update", "missing", "missing", "missing", "missing", "quiet"]
        );
        assert_eq!(got[0].days[1].text, "did things");
    }

    #[test]
    fn weekly_ready_needs_a_settled_sunday() {
        let (_db, pool) = pool("wk-sunday-stale");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "did things", 1);
        daily(&conn, "2026-11-08", "", 0);
        conn.execute(
            "UPDATE project_updates SET stale = 1 WHERE day = '2026-11-08'",
            [],
        )
        .unwrap();
        assert!(items(&conn, "2026-11-09T06:05:00Z").is_empty());
    }

    #[test]
    fn weekly_offered_at_fallback() {
        let (_db, pool) = pool("wk-fallback");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "did things", 1);
        assert!(items(&conn, "2026-11-09T07:59:00Z").is_empty());
        assert_eq!(items(&conn, "2026-11-09T08:00:00Z").len(), 1);
    }

    #[test]
    fn days_before_since_are_untracked() {
        let (_db, pool) = pool("wk-since");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-11-04");
        daily(&conn, "2026-11-02", "old", 0);
        daily(&conn, "2026-11-03", "old", 0);
        daily(&conn, "2026-11-04", "wed", 0);
        summary(&conn, "2026-11-05", "s1", 0);
        summary(&conn, "2026-11-05", "s2", 1);
        let got = items(&conn, "2026-11-09T08:00:00Z");
        assert_eq!(
            states(&got[0]),
            [
                "untracked",
                "untracked",
                "update",
                "missing",
                "missing",
                "missing",
                "missing"
            ]
        );
        assert_eq!(got[0].days[0].text, "");
        let thu = &got[0].days[3];
        assert_eq!(thu.text, "");
        assert_eq!(thu.summaries.len(), 1);
        assert_eq!(
            (
                thu.summaries[0].title.as_str(),
                thu.summaries[0].summary.as_str()
            ),
            ("T s1", "S s1")
        );
    }

    #[test]
    fn failed_day_carries_summaries() {
        let (_db, pool) = pool("wk-failed");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "_This update couldn't be written (the model failed 3 times). Use Rewrite to try again._", 0);
        summary(&conn, "2026-11-03", "s1", 0);
        let got = items(&conn, "2026-11-09T08:00:00Z");
        assert_eq!(got.len(), 1);
        let tue = &got[0].days[1];
        assert_eq!(tue.state, "failed");
        assert_eq!(tue.text, "");
        assert_eq!(tue.summaries.len(), 1);
    }

    #[test]
    fn not_offered_to_other_computer() {
        let (_db, pool) = pool("wk-other");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "did things", 1);
        assert!(weekly_items(&conn, "spread", utc("2026-11-09T08:00:00Z"))
            .unwrap()
            .is_empty());
    }

    #[test]
    fn quiet_week_not_offered() {
        let (_db, pool) = pool("wk-quiet");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-11-05");
        daily(&conn, "2026-11-03", "before since", 0);
        daily(&conn, "2026-11-06", "", 0);
        daily(&conn, "2026-11-08", "", 0);
        assert!(items(&conn, "2026-11-09T08:00:00Z").is_empty());
    }

    #[actix_web::test]
    async fn put_weekly_computes_counts() {
        let (_db, pool) = pool("wk-put");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-01-01");
            daily(&conn, "2026-11-03", "a", 2);
            daily(&conn, "2026-11-04", "b", 3);
            daily(&conn, "2026-11-05", "", 0);
            summary(&conn, "2026-11-03", "s1", 0);
            summary(&conn, "2026-11-04", "s1", 0);
            summary(&conn, "2026-11-04", "s2", 0);
        }
        let (status, body) = put(
            &pool,
            "/api/projects/pa/weekly/2026-11-02",
            json!({"headline": "Good week", "wins": "- you shipped", "failed": false}),
        )
        .await;
        assert_eq!(status, actix_web::http::StatusCode::OK, "{body}");
        let conn = pool.get().unwrap();
        let (name, head, commits, convs, work, days): (String, String, i64, i64, i64, String) = conn
            .query_row(
                "SELECT project_name, headline, commits, conversations, days_with_work, days FROM weekly_recaps WHERE week = ?1",
                params![WEEK],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )
            .unwrap();
        assert_eq!(
            (name.as_str(), head.as_str(), commits, convs, work),
            ("Alpha", "Good week", 5, 2, 2)
        );
        let days: serde_json::Value = serde_json::from_str(&days).unwrap();
        assert_eq!(days[1], json!({"day": "2026-11-03", "state": "update"}));
        assert_eq!(days[3], json!({"day": "2026-11-05", "state": "quiet"}));
        assert_eq!(days[0]["state"], "missing");
        // Offered work is gone now.
        assert!(items(&conn, "2026-11-09T08:00:00Z").is_empty());
    }

    #[actix_web::test]
    async fn put_weekly_rejects_bad_input() {
        let (_db, pool) = pool("wk-put-bad");
        seed_updates(&pool.get().unwrap(), "2026-01-01");
        let ok = json!({"headline": "h", "wins": "w", "failed": false});
        assert_eq!(
            put(&pool, "/api/projects/pa/weekly/2026-11-03", ok.clone())
                .await
                .0,
            400
        );
        assert_eq!(
            put(&pool, "/api/projects/pa/weekly/nope", ok.clone())
                .await
                .0,
            400
        );
        assert_eq!(
            put(
                &pool,
                "/api/projects/pa/weekly/2026-11-02",
                json!({"headline": "x".repeat(201), "wins": "w", "failed": false})
            )
            .await
            .0,
            400
        );
        assert_eq!(
            put(&pool, "/api/projects/zz/weekly/2026-11-02", ok).await.0,
            404
        );
    }

    fn put_recap(conn: &Connection, written: &str) {
        conn.execute(
            "INSERT INTO weekly_recaps (week, project_id, project_name, headline, wins, written_at) VALUES (?1, 'pa', 'Alpha', 'h', 'w', ?2)",
            params![WEEK, written],
        )
        .unwrap();
    }

    fn flags(conn: &Connection) -> (i64, i64) {
        conn.query_row(
            "SELECT rewrite_requested, stale FROM weekly_recaps WHERE week = ?1",
            params![WEEK],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
    }

    #[test]
    fn late_daily_marks_recap_stale() {
        let (_db, pool) = pool("wk-stale");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        daily(&conn, "2026-11-03", "a", 0);
        put_recap(&conn, "2026-11-09 08:30:00");
        let req = crate::updates::PutUpdateRequest {
            text: "late".into(),
            commits: 1,
            generation: None,
        };
        crate::updates::put_update_db(&conn, "pa", "2026-11-04", &req, utc("2026-11-10T10:00:00Z"))
            .unwrap();
        assert_eq!(flags(&conn), (0, 1));
        let offered = items(&conn, "2026-11-10T10:05:00Z");
        assert_eq!(offered.len(), 1);
        assert_eq!(offered[0].days[2].text, "late");
    }

    #[test]
    fn old_week_not_marked_stale() {
        let (_db, pool) = pool("wk-old");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        put_recap(&conn, "2026-11-09 08:30:00");
        let req = crate::updates::PutUpdateRequest {
            text: "very late".into(),
            commits: 0,
            generation: None,
        };
        // The week ends on 11-09; 14 days after the week's Monday is 11-16 10:00 Sofia.
        crate::updates::put_update_db(&conn, "pa", "2026-11-04", &req, utc("2026-11-17T09:00:00Z"))
            .unwrap();
        assert_eq!(flags(&conn), (0, 0));
    }

    #[actix_web::test]
    async fn rewrite_offers_again() {
        let (_db, pool) = pool("wk-rewrite");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-01-01");
            daily(&conn, "2026-11-03", "a", 0);
            put_recap(&conn, "2026-11-09 08:30:00");
            assert!(items(&conn, "2026-11-09T09:00:00Z").is_empty());
            // Fixed "now" so the 90-day keep doesn't make this test expire.
            let now = utc("2026-11-09T09:00:00Z");
            assert!(rewrite_weekly_db(&conn, "pa", WEEK, now).is_ok());
            assert!(matches!(rewrite_weekly_db(&conn, "pa", "2026-10-26", now), Err(UpdateError::NotFound(_))));
        }
        assert_eq!(
            post(&pool, "/api/projects/pa/weekly/bad/rewrite", json!({}))
                .await
                .0,
            400
        );
        let conn = pool.get().unwrap();
        assert_eq!(items(&conn, "2026-11-09T09:00:00Z").len(), 1);
        assert_eq!(flags(&conn), (1, 0));
    }

    #[test]
    fn rewrite_refused_past_keep_and_when_updates_off() {
        let (_db, pool) = pool("wk-rewrite-guards");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        put_recap(&conn, "2026-11-09 08:30:00");
        // 90 days back from Sofia's 2027-01-31 is 2026-11-02: the week's first day is still kept.
        assert!(rewrite_weekly_db(&conn, "pa", WEEK, utc("2027-01-31T10:00:00Z")).is_ok());
        conn.execute("UPDATE weekly_recaps SET rewrite_requested = 0", []).unwrap();
        // A day later the Monday is gone.
        assert!(matches!(
            rewrite_weekly_db(&conn, "pa", WEEK, utc("2027-02-01T10:00:00Z")),
            Err(UpdateError::BadRequest(_))
        ));
        assert_eq!(flags(&conn), (0, 0));
        conn.execute("UPDATE projects SET daily_updates = 0", []).unwrap();
        assert!(matches!(
            rewrite_weekly_db(&conn, "pa", WEEK, utc("2026-11-10T10:00:00Z")),
            Err(UpdateError::Conflict(_))
        ));
        assert_eq!(flags(&conn), (0, 0));
    }

    #[actix_web::test]
    async fn rewrite_endpoint_409_when_updates_off() {
        let (_db, pool) = pool("wk-rewrite-409");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-01-01");
            put_recap(&conn, "2026-11-09 08:30:00");
            conn.execute("UPDATE projects SET daily_updates = 0", []).unwrap();
        }
        // A recap of a week this old would be 400 (past the keep), so use one inside it.
        let week = week_of_time(Utc::now() - Duration::days(7));
        pool.get()
            .unwrap()
            .execute(
                "INSERT INTO weekly_recaps (week, project_id, project_name, headline, wins, written_at) VALUES (?1, 'pa', 'Alpha', 'h', 'w', '')",
                params![week],
            )
            .unwrap();
        let uri = format!("/api/projects/pa/weekly/{week}/rewrite");
        assert_eq!(post(&pool, &uri, json!({})).await.0, 409);
    }

    #[test]
    fn flagged_week_without_material_cleared_not_offered() {
        let (_db, pool) = pool("wk-flag-empty");
        let conn = pool.get().unwrap();
        seed_updates(&conn, "2026-01-01");
        put_recap(&conn, "2026-11-09 08:30:00");
        conn.execute("UPDATE weekly_recaps SET rewrite_requested = 1, stale = 1", []).unwrap();
        // The week's daily updates and summaries are gone (cleaned up after 90 days).
        assert!(items(&conn, "2026-11-10T09:00:00Z").is_empty());
        assert_eq!(flags(&conn), (0, 0));
        // A flagged week with only summaries on a missing day is still offered.
        summary(&conn, "2026-11-04", "s1", 0);
        conn.execute("UPDATE weekly_recaps SET rewrite_requested = 1", []).unwrap();
        assert_eq!(items(&conn, "2026-11-10T09:00:00Z").len(), 1);
        assert_eq!(flags(&conn), (1, 0));
    }

    #[actix_web::test]
    async fn put_weekly_counts_only_tracked_days() {
        let (_db, pool) = pool("wk-put-since");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-11-04");
            daily(&conn, "2026-11-03", "before", 7);
            daily(&conn, "2026-11-04", "after", 2);
            summary(&conn, "2026-11-03", "old", 0);
            summary(&conn, "2026-11-05", "new", 0);
        }
        let ok = json!({"headline": "h", "wins": "- w", "failed": false});
        assert_eq!(put(&pool, "/api/projects/pa/weekly/2026-11-02", ok).await.0, 200);
        let conn = pool.get().unwrap();
        let (commits, convs): (i64, i64) = conn
            .query_row("SELECT commits, conversations FROM weekly_recaps WHERE week = ?1", params![WEEK], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((commits, convs), (2, 1));
    }

    #[actix_web::test]
    async fn put_weekly_caps_wins() {
        let (_db, pool) = pool("wk-put-wins");
        seed_updates(&pool.get().unwrap(), "2026-01-01");
        let uri = "/api/projects/pa/weekly/2026-11-02";
        let over = json!({"headline": "h", "wins": "x".repeat(crate::updates::MAX_UPDATE + 1), "failed": false});
        assert_eq!(put(&pool, uri, over).await.0, 400);
        let at = json!({"headline": "h", "wins": "x".repeat(crate::updates::MAX_UPDATE), "failed": false});
        assert_eq!(put(&pool, uri, at).await.0, 200);
    }

    // --- GET /api/weekly -----------------------------------------------------------------

    use crate::test_support::get;

    fn recap(conn: &Connection, week: &str, project: &str, name: &str, wins: &str, failed: i64, commits: i64, convs: i64) {
        conn.execute(
            "INSERT INTO weekly_recaps (week, project_id, project_name, headline, wins, failed, days, commits, conversations, days_with_work, written_at, stale)
             VALUES (?1, ?2, ?3, 'head', ?4, ?5, '[{\"day\":\"2026-11-02\",\"state\":\"update\"}]', ?6, ?7, 3, '2026-11-09 08:30:00', ?8)",
            params![week, project, name, wins, failed, commits, convs, i64::from(project == "stale")],
        )
        .unwrap();
    }

    fn snapshot(conn: &Connection, week: &str, runs: u32) {
        let jobs = WeeklyJobs { runs, done: runs, failed: 0, skipped: 0, todos_created: 1, conversations_started: 1, findings: 0, jobs: vec![] };
        conn.execute(
            "INSERT INTO weekly_jobs (week, snapshot, taken_at) VALUES (?1, ?2, '2026-11-09 08:00:00')",
            params![week, serde_json::to_string(&jobs).unwrap()],
        )
        .unwrap();
    }

    fn weeks(body: &serde_json::Value) -> Vec<&str> {
        body.as_array().unwrap().iter().map(|w| w["week"].as_str().unwrap()).collect()
    }

    #[actix_web::test]
    async fn list_weekly_newest_first_and_paged() {
        let (_db, pool) = crate::test_support::pool("wk-list");
        {
            let conn = pool.get().unwrap();
            for w in ["2026-10-12", "2026-10-19", "2026-10-26", "2026-11-02"] {
                recap(&conn, w, "pa", "Alpha", "- you shipped", 0, 1, 1);
            }
        }
        let (s, body) = get(&pool, "/api/weekly").await;
        assert_eq!(s, 200, "{body}");
        assert_eq!(weeks(&body), ["2026-11-02", "2026-10-26", "2026-10-19", "2026-10-12"]);
        let (_, body) = get(&pool, "/api/weekly?limit=2").await;
        assert_eq!(weeks(&body), ["2026-11-02", "2026-10-26"]);
        let (_, body) = get(&pool, "/api/weekly?before=2026-10-26&limit=1").await;
        assert_eq!(weeks(&body), ["2026-10-19"]);
        assert_eq!(get(&pool, "/api/weekly?before=nope").await.0, 400);
        let section = &body[0]["sections"][0];
        assert_eq!(section["project_name"], "Alpha");
        assert_eq!(section["rewriting"], false);
        assert_eq!(section["days"][0]["state"], "update");
        // No snapshot and no tallies: the live (empty) jobs block, not null.
        assert_eq!(body[0]["jobs"]["runs"], 0);
    }

    #[actix_web::test]
    async fn list_weekly_skips_empty_weeks() {
        let (_db, pool) = crate::test_support::pool("wk-skip-empty");
        {
            let conn = pool.get().unwrap();
            let put = |week: &str, jobs: WeeklyJobs| {
                conn.execute(
                    "INSERT INTO weekly_jobs (week, snapshot, taken_at) VALUES (?1, ?2, '2026-11-09 08:00:00')",
                    params![week, serde_json::to_string(&jobs).unwrap()],
                )
                .unwrap();
            };
            let empty = WeeklyJobs { runs: 0, done: 0, failed: 0, skipped: 0, todos_created: 0, conversations_started: 0, findings: 0, jobs: vec![] };
            let job = |checks| WeeklyJob {
                job_id: "j".into(),
                name: "Watch".into(),
                project_name: "P".into(),
                is_watch: true,
                runs: 0,
                done: 0,
                failed: 0,
                skipped: 0,
                checks,
                findings: 0,
                lines: vec![],
            };
            put("2026-10-05", empty.clone());
            put("2026-10-12", WeeklyJobs { jobs: vec![job(3)], ..empty.clone() });
            recap(&conn, "2026-10-19", "pa", "Alpha", "- you shipped", 0, 1, 1);
            put("2026-10-26", empty.clone());
            put("2026-11-02", WeeklyJobs { jobs: vec![job(0)], ..empty });
        }
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(weeks(&body), ["2026-10-19", "2026-10-12"]);
        // Paging keeps scanning past empty weeks to fill the limit.
        let (_, body) = get(&pool, "/api/weekly?limit=1").await;
        assert_eq!(weeks(&body), ["2026-10-19"]);
        let (_, body) = get(&pool, "/api/weekly?before=2026-10-19&limit=1").await;
        assert_eq!(weeks(&body), ["2026-10-12"]);
        let (_, body) = get(&pool, "/api/weekly?before=2026-10-12").await;
        assert!(weeks(&body).is_empty());
    }

    #[actix_web::test]
    async fn unsnapshotted_week_shows_live_jobs() {
        let (_db, pool) = crate::test_support::pool("wk-live-jobs");
        {
            let conn = pool.get().unwrap();
            seed(&conn);
            run(&conn, "j", "2026-11-03 09:00:00", "done", Some("ok"), None);
            run(&conn, "j", "2026-11-04 09:00:00", "failed", Some("boom"), None);
            tally_settled_runs(&conn).unwrap();
            recap(&conn, WEEK, "pa", "Alpha", "- a", 0, 1, 1);
        }
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(body[0]["totals"]["runs"], 2);
        assert_eq!(body[0]["jobs"]["runs"], 2);
        assert_eq!(body[0]["jobs"]["failed"], 1);
        assert_eq!(body[0]["jobs"]["jobs"][0]["lines"].as_array().unwrap().len(), 2);
    }

    #[actix_web::test]
    async fn rewriting_false_when_daily_updates_off() {
        let (_db, pool) = crate::test_support::pool("wk-rewriting-off");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-01-01");
            recap(&conn, WEEK, "pa", "Alpha", "- a", 0, 1, 1);
            conn.execute("UPDATE weekly_recaps SET rewrite_requested = 1", []).unwrap();
        }
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(body[0]["sections"][0]["rewriting"], true);
        pool.get().unwrap().execute("UPDATE projects SET daily_updates = 0", []).unwrap();
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(body[0]["sections"][0]["rewriting"], false);
    }

    #[actix_web::test]
    async fn sections_sorted_by_conversations() {
        let (_db, pool) = crate::test_support::pool("wk-sort");
        {
            let conn = pool.get().unwrap();
            recap(&conn, WEEK, "pa", "Alpha", "- a", 0, 1, 2);
            recap(&conn, WEEK, "pb", "Beta", "- b", 0, 1, 9);
            recap(&conn, WEEK, "pf", "Failed", "", 1, 0, 5);
            recap(&conn, WEEK, "pe", "Empty", "", 0, 0, 7);
            recap(&conn, WEEK, "stale", "Stale", "- s", 0, 0, 1);
            conn.execute(
                "INSERT INTO projects (id, name, section, folder, daily_updates) VALUES ('stale', 'Stale', 'Si', '~/s', 1)",
                [],
            )
            .unwrap();
        }
        let (_, body) = get(&pool, "/api/weekly").await;
        let names: Vec<&str> = body[0]["sections"].as_array().unwrap().iter().map(|s| s["project_name"].as_str().unwrap()).collect();
        assert_eq!(names, ["Beta", "Failed", "Alpha", "Stale"]);
        assert_eq!(body[0]["sections"][1]["failed"], true);
        assert_eq!(body[0]["sections"][3]["rewriting"], true);
    }

    #[actix_web::test]
    async fn totals_sum_sections_and_runs() {
        let (_db, pool) = crate::test_support::pool("wk-totals");
        {
            let conn = pool.get().unwrap();
            recap(&conn, WEEK, "pa", "Alpha", "- a", 0, 3, 2);
            recap(&conn, WEEK, "pb", "Beta", "- b", 0, 4, 5);
            snapshot(&conn, WEEK, 6);
            recap(&conn, "2026-10-26", "pa", "Alpha", "- a", 0, 1, 1);
        }
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(body[0]["totals"], json!({"commits": 7, "conversations": 7, "runs": 6}));
        assert_eq!(body[0]["jobs"]["runs"], 6);
        assert_eq!(body[1]["totals"], json!({"commits": 1, "conversations": 1, "runs": 0}));
    }

    #[actix_web::test]
    async fn week_with_only_jobs_listed() {
        let (_db, pool) = crate::test_support::pool("wk-jobs-only");
        snapshot(&pool.get().unwrap(), WEEK, 2);
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(weeks(&body), [WEEK]);
        assert_eq!(body[0]["sections"], json!([]));
        assert_eq!(body[0]["totals"]["runs"], 2);
    }

    #[actix_web::test]
    async fn deleted_project_section_kept_with_stored_name() {
        let (_db, pool) = crate::test_support::pool("wk-deleted");
        {
            let conn = pool.get().unwrap();
            seed_updates(&conn, "2026-01-01");
            daily(&conn, "2026-11-03", "a", 1);
        }
        let ok = json!({"headline": "h", "wins": "- you shipped", "failed": false});
        assert_eq!(put(&pool, "/api/projects/pa/weekly/2026-11-02", ok).await.0, 200);
        pool.get().unwrap().execute("DELETE FROM projects WHERE id = 'pa'", []).unwrap();
        let (_, body) = get(&pool, "/api/weekly").await;
        assert_eq!(body[0]["sections"][0]["project_name"], "Alpha");
        assert_eq!(body[0]["sections"][0]["project_id"], "pa");
    }
}
