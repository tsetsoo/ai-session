//! Watchers: a Mac's runner posts each check's problems here. The hub keeps one issue per
//! watcher and key, pushes new ones, and queues debugging conversations (runs of the
//! "Debug · <watcher>" job, at most 2 at work) that take untaken issues when they start.

use std::collections::HashSet;

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use todo_shared::{CreateJobRequest, Job, JobAction, JobTrigger, LimitSetting, Priority, WatchReport};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, conflict, not_found, server_error};
use crate::db::DbPool;
use crate::jobs::{load_job, load_run};
use crate::push::apns::{Alert, PushKind};
use crate::push::PushNotifier;
use crate::scheduler::{local_date, sql_time};

/// Debugging conversations of one watcher at work at once.
pub(crate) const MAX_AT_WORK: usize = 2;
/// A conversation not yet reporting a status counts as at work this long.
const UNKNOWN_GRACE_MINUTES: i64 = 30;
/// A key resolved this recently is ignored by checks (Sentry's API can lag).
const RESOLVE_GRACE_MINUTES: i64 = 15;
/// "Overwhelmed": more untaken open issues than this, or one waiting longer than a day.
const OVERWHELMED_COUNT: i64 = 20;
const OVERWHELMED_HOURS: i64 = 24;
/// The Debug job's prompt when the watch job has no extra instructions.
pub(crate) const DEBUG_DEFAULT_PROMPT: &str = "Fix the open problems this run lists.";

pub(crate) enum WatchError {
    BadRequest(&'static str),
    NotFound(&'static str),
    Conflict(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for WatchError {
    fn from(e: rusqlite::Error) -> Self {
        WatchError::Db(e)
    }
}

pub(crate) fn respond(e: WatchError) -> HttpResponse {
    match e {
        WatchError::BadRequest(m) => bad_request(m),
        WatchError::NotFound(m) => not_found(m),
        WatchError::Conflict(m) => conflict(m),
        WatchError::Db(e) => server_error(e),
    }
}

/// A watch job's settings.
pub(crate) struct WatchParts<'a> {
    pub project_id: &'a str,
    pub computer_id: &'a str,
    pub watcher: &'a str,
    pub debug_tool: Option<&'a str>,
    pub prompt: &'a str,
}

pub(crate) fn watch_parts(job: &Job) -> Option<WatchParts<'_>> {
    match &job.action {
        JobAction::Watch { project_id, computer_id, watcher, debug_tool, prompt } => Some(WatchParts {
            project_id,
            computer_id,
            watcher,
            debug_tool: debug_tool.as_deref(),
            prompt,
        }),
        _ => None,
    }
}

pub(crate) fn debug_job_name(watcher: &str) -> String {
    format!("Debug · {watcher}")
}

/// The watcher's Debug job, if it exists.
pub(crate) fn debug_job_id(conn: &Connection, watcher: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row("SELECT id FROM jobs WHERE name = ?1 ORDER BY created_at LIMIT 1", params![debug_job_name(watcher)], |r| r.get(0))
        .optional()
}

/// The watcher's Debug job, created or brought in line with the watch job (tool, project,
/// computer, extra instructions).
fn ensure_debug_job(conn: &Connection, watch: &WatchParts, tool: &str) -> Result<String, WatchError> {
    let prompt = if watch.prompt.trim().is_empty() { DEBUG_DEFAULT_PROMPT } else { watch.prompt };
    let action = JobAction::Conversation {
        project_id: watch.project_id.to_string(),
        computer_id: Some(watch.computer_id.to_string()),
        tool: tool.to_string(),
        folder: None,
        prompt: prompt.to_string(),
        priority: Priority::Urgent,
        limit: LimitSetting::Always,
    };
    if let Some(id) = debug_job_id(conn, watch.watcher)? {
        conn.execute(
            "UPDATE jobs SET action = ?2, updated_at = datetime('now') WHERE id = ?1 AND action != ?2",
            params![id, serde_json::to_string(&action).unwrap_or_default()],
        )?;
        return Ok(id);
    }
    let request = CreateJobRequest {
        name: debug_job_name(watch.watcher),
        enabled: Some(true),
        trigger: JobTrigger::Manual,
        action,
        max_runs_per_day: Some(96),
    };
    match crate::jobs::create_job_db(conn, &request) {
        Ok(job) => Ok(job.id),
        Err(crate::jobs::JobError::Db(e)) => Err(WatchError::Db(e)),
        Err(_) => Err(WatchError::BadRequest("could not create the debug job")),
    }
}

/// Debug runs at work: queued, being started, or with a conversation busy, waiting on the
/// user, or just started (no status yet). `except` leaves one run out.
pub(crate) fn at_work_count(conn: &Connection, debug_job_id: &str, now: DateTime<Utc>, except: Option<&str>) -> rusqlite::Result<usize> {
    let n: i64 = conn.query_row(
        "SELECT COUNT(*) FROM job_runs r WHERE r.job_id = ?1 AND (?2 IS NULL OR r.id != ?2) AND (
             r.state IN ('due','waiting')
             OR (r.state = 'running' AND r.todo_id IS NULL)
             OR (r.todo_id IS NOT NULL AND EXISTS (SELECT 1 FROM conversations c WHERE c.todo_id = r.todo_id
                   AND (c.status IN ('busy','waiting') OR (c.status = 'unknown' AND c.created_at >= ?3)))))",
        params![debug_job_id, except, sql_time(now - Duration::minutes(UNKNOWN_GRACE_MINUTES))],
        |r| r.get(0),
    )?;
    Ok(n.max(0) as usize)
}

/// Queue debug runs while untaken open issues exist and fewer than 2 are at work: one per
/// folder (most untaken issues first, then the oldest), never two queued for one folder.
pub(crate) fn queue_debug_runs(conn: &Connection, job: &Job, now: DateTime<Utc>) -> Result<Vec<String>, WatchError> {
    let Some(watch) = watch_parts(job) else { return Ok(Vec::new()) };
    let Some(tool) = watch.debug_tool else { return Ok(Vec::new()) };
    let folders: Vec<String> = {
        let mut stmt = conn.prepare(
            "SELECT COALESCE(folder, '') AS f FROM watch_issues WHERE watcher = ?1 AND state = 'open' AND taken_run_id IS NULL
             GROUP BY f ORDER BY COUNT(*) DESC, MIN(first_seen) ASC",
        )?;
        let rows = stmt.query_map(params![watch.watcher], |r| r.get(0))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    if folders.is_empty() {
        return Ok(Vec::new());
    }
    let debug_id = ensure_debug_job(conn, &watch, tool)?;
    let mut free = MAX_AT_WORK.saturating_sub(at_work_count(conn, &debug_id, now, None)?);
    let queued: HashSet<String> = {
        let mut stmt = conn.prepare(
            "SELECT note FROM job_runs WHERE job_id = ?1 AND note IS NOT NULL
               AND (state IN ('due','waiting') OR (state = 'running' AND todo_id IS NULL))",
        )?;
        let rows = stmt.query_map(params![debug_id], |r| r.get::<_, String>(0))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    let mut created = Vec::new();
    for folder in folders {
        if free == 0 {
            break;
        }
        let note = format!("watch:{folder}");
        if queued.contains(&note) {
            continue;
        }
        let id = Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, note) VALUES (?1, ?2, ?3, 'due', ?4)",
            params![id, debug_id, sql_time(now), note],
        )?;
        created.push(id);
        free -= 1;
    }
    Ok(created)
}

#[derive(Debug, Default)]
pub(crate) struct ReportOutcome {
    pub watcher: String,
    pub new_titles: Vec<String>,
    pub queued_runs: Vec<String>,
    /// The "overwhelmed" push body, at most once a day per job.
    pub overwhelmed: Option<String>,
    pub job_name: String,
}

/// A check's problems: record them, clear what's gone, finish the run, queue debug runs.
pub(crate) fn report_db(conn: &Connection, run_id: &str, report: &WatchReport, now: DateTime<Utc>) -> Result<ReportOutcome, WatchError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let run = load_run(&tx, run_id)?.ok_or(WatchError::NotFound("Run not found"))?;
    let job = load_job(&tx, &run.job_id)?.ok_or(WatchError::NotFound("Job not found"))?;
    let Some(watch) = watch_parts(&job) else { return Err(WatchError::Conflict("Not a watch run")) };
    if run.state != "running" {
        return Err(WatchError::Conflict("Run is not running"));
    }
    let stamp = sql_time(now);
    let first: bool = tx.query_row(
        "SELECT NOT EXISTS (SELECT 1 FROM job_runs WHERE job_id = ?1 AND state = 'done' AND id != ?2)
            AND NOT EXISTS (SELECT 1 FROM watch_issues WHERE watcher = ?3)",
        params![job.id, run.id, watch.watcher],
        |r| r.get(0),
    )?;
    let grace = sql_time(now - Duration::minutes(RESOLVE_GRACE_MINUTES));
    let mut out = ReportOutcome { watcher: watch.watcher.to_string(), job_name: job.name.clone(), ..Default::default() };
    let mut seen = HashSet::new();
    for p in &report.problems {
        let key = p.key.trim();
        if key.is_empty() || !seen.insert(key.to_string()) {
            continue;
        }
        let title: String = p.title.trim().chars().take(300).collect();
        let details: String = p.details.chars().take(4000).collect();
        let url: String = p.url.chars().take(1000).collect();
        let folder = p.folder.as_deref().map(str::trim).filter(|f| !f.is_empty());
        let existing: Option<(String, String, Option<String>, Option<String>)> = tx
            .query_row(
                "SELECT id, state, outcome, resolved_at FROM watch_issues WHERE watcher = ?1 AND key = ?2",
                params![watch.watcher, key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        match existing {
            None => {
                tx.execute(
                    "INSERT INTO watch_issues (id, watcher, key, job_id, project_id, title, details, url, folder, first_seen, last_seen, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, ?10)",
                    params![Uuid::new_v4().to_string(), watch.watcher, key, job.id, watch.project_id, title, details, url, folder, stamp],
                )?;
                if !first {
                    out.new_titles.push(title);
                }
            }
            Some((_, state, _, resolved_at)) if state == "cleared" && resolved_at.as_deref().is_some_and(|t| t >= grace.as_str()) => {}
            Some((id, state, outcome, _)) if state == "cleared" => {
                let keep = outcome.as_deref() == Some("cant_fix");
                tx.execute(
                    "UPDATE watch_issues SET state = 'open', title = ?2, details = ?3, url = ?4, folder = ?5, job_id = ?6, last_seen = ?7,
                         cleared_at = NULL, resolve_error = NULL, updated_at = ?7,
                         taken_run_id = CASE WHEN ?8 THEN taken_run_id END, outcome = CASE WHEN ?8 THEN outcome END,
                         outcome_note = CASE WHEN ?8 THEN outcome_note END
                     WHERE id = ?1",
                    params![id, title, details, url, folder, job.id, stamp, keep],
                )?;
                if !first {
                    out.new_titles.push(title);
                }
            }
            Some((id, ..)) => {
                tx.execute(
                    "UPDATE watch_issues SET title = ?2, details = ?3, url = ?4, folder = ?5, job_id = ?6, last_seen = ?7,
                         updated_at = CASE WHEN title != ?2 OR details != ?3 THEN ?7 ELSE updated_at END WHERE id = ?1",
                    params![id, title, details, url, folder, job.id, stamp],
                )?;
            }
        }
    }
    if !report.partial {
        let open: Vec<(String, String)> = {
            let mut stmt = tx.prepare("SELECT id, key FROM watch_issues WHERE watcher = ?1 AND state IN ('open','resolving')")?;
            let rows = stmt.query_map(params![watch.watcher], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for (id, key) in open {
            if !seen.contains(&key) {
                tx.execute(
                    "UPDATE watch_issues SET state = 'cleared', cleared_at = ?2, updated_at = ?2 WHERE id = ?1",
                    params![id, stamp],
                )?;
            }
        }
    }
    let result = if out.new_titles.is_empty() { "quiet".to_string() } else { format!("{} new", out.new_titles.len()) };
    tx.execute(
        "UPDATE job_runs SET state = 'done', result = ?2, started_at = COALESCE(started_at, ?3), updated_at = ?3 WHERE id = ?1",
        params![run.id, result, stamp],
    )?;
    out.queued_runs = queue_debug_runs(&tx, &job, now)?;
    if watch.debug_tool.is_some() {
        out.overwhelmed = overwhelmed(&tx, &job, watch.watcher, now)?;
    }
    tx.commit()?;
    Ok(out)
}

/// The once-a-day "overwhelmed" body when too many issues wait, or one waits too long.
fn overwhelmed(conn: &Connection, job: &Job, watcher: &str, now: DateTime<Utc>) -> rusqlite::Result<Option<String>> {
    let (waiting, oldest): (i64, Option<String>) = conn.query_row(
        "SELECT COUNT(*), MIN(first_seen) FROM watch_issues WHERE watcher = ?1 AND state = 'open' AND taken_run_id IS NULL",
        params![watcher],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let stale = oldest.is_some_and(|t| t < sql_time(now - Duration::hours(OVERWHELMED_HOURS)));
    if waiting <= OVERWHELMED_COUNT && !stale {
        return Ok(None);
    }
    let added = conn.execute("INSERT OR IGNORE INTO watch_alerts (job_id, day) VALUES (?1, ?2)", params![job.id, local_date(now)])?;
    if added == 0 {
        return Ok(None);
    }
    Ok(Some(if stale && waiting <= OVERWHELMED_COUNT {
        format!("{waiting} issues waiting; one for over a day")
    } else {
        format!("{waiting} issues waiting for a conversation")
    }))
}

/// "Sentry" from "sentry".
pub(crate) fn display_name(watcher: &str) -> String {
    let mut chars = watcher.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A push now: silent during quiet hours.
pub(crate) async fn push_now(pool: &DbPool, notifier: &PushNotifier, title: String, body: String, todo_id: Option<String>) {
    let passive = pool
        .get()
        .ok()
        .and_then(|c| crate::push::store::load_settings(&c).ok())
        .and_then(|s| s.quiet_hours)
        .is_some_and(|q| crate::push::policy::in_quiet_hours(&q, Utc::now()));
    let alert = Alert { todo_id, session_id: None, title, subtitle: body, kind: PushKind::Scheduled, passive };
    notifier.send_to_devices(pool, &alert, None).await;
}

fn new_issues_push(out: &ReportOutcome) -> Option<(String, String)> {
    let name = display_name(&out.watcher);
    match out.new_titles.as_slice() {
        [] => None,
        [one] => Some((format!("{name} · {one}"), String::new())),
        many => Some((format!("{} new {name} issues", many.len()), many.join("\n").chars().take(300).collect())),
    }
}

// --- Handlers ---------------------------------------------------------------------

pub async fn report(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<WatchReport>,
    broadcaster: web::Data<Broadcaster>,
    notifier: web::Data<PushNotifier>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let out = match report_db(&conn, &path, &body, Utc::now()) {
        Ok(out) => out,
        Err(e) => return respond(e),
    };
    drop(conn);
    broadcaster.send();
    if let Some((title, body)) = new_issues_push(&out) {
        push_now(&pool, &notifier, title, body, None).await;
    }
    if let Some(why) = &out.overwhelmed {
        push_now(&pool, &notifier, format!("{} needs you", out.job_name), why.clone(), None).await;
    }
    HttpResponse::Ok().json(serde_json::json!({"new": out.new_titles.len(), "queued": out.queued_runs.len()}))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use chrono::TimeZone;
    use todo_shared::WatchProblem;

    use crate::test_support::{pool, seed_computers};

    pub(crate) fn seed_watch(conn: &Connection, debug_tool: Option<&str>) -> String {
        seed_computers(conn);
        conn.execute_batch("INSERT INTO projects (id, name, section, folder) VALUES ('ps', 'sigma', 'Si', '~/sigma');").unwrap();
        let action = JobAction::Watch {
            project_id: "ps".into(),
            computer_id: "mac".into(),
            watcher: "sentry".into(),
            debug_tool: debug_tool.map(str::to_string),
            prompt: String::new(),
        };
        conn.execute(
            "INSERT INTO jobs (id, name, enabled, trigger, action, max_runs_per_day) VALUES ('w', 'Sigma Sentry', 1, '{\"kind\":\"manual\"}', ?1, 4)",
            params![serde_json::to_string(&action).unwrap()],
        )
        .unwrap();
        "w".into()
    }

    pub(crate) fn running_check(conn: &Connection, id: &str) -> String {
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, computer_id) VALUES (?1, 'w', datetime('now'), 'running', 'mac')",
            params![id],
        )
        .unwrap();
        id.into()
    }

    pub(crate) fn problem(key: &str, title: &str, folder: Option<&str>) -> WatchProblem {
        WatchProblem { key: key.into(), title: title.into(), details: format!("details of {key}"), url: format!("https://s/{key}"), folder: folder.map(str::to_string) }
    }

    pub(crate) fn report_of(problems: Vec<WatchProblem>) -> WatchReport {
        WatchReport { problems, partial: false }
    }

    pub(crate) fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 3, 10, 0, 0).unwrap()
    }

    pub(crate) fn issue(conn: &Connection, key: &str) -> (String, Option<String>, Option<String>) {
        conn.query_row("SELECT state, taken_run_id, outcome FROM watch_issues WHERE key = ?1", params![key], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
    }

    fn run_state(conn: &Connection, id: &str) -> (String, Option<String>) {
        conn.query_row("SELECT state, result FROM job_runs WHERE id = ?1", params![id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap()
    }

    #[test]
    fn first_report_records_backlog_without_new() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        let run = running_check(&conn, "c1");
        let out = report_db(&conn, &run, &report_of(vec![problem("a", "A", None), problem("b", "B", None)]), now()).ok().unwrap();
        assert!(out.new_titles.is_empty());
        assert_eq!(issue(&conn, "a").0, "open");
        assert_eq!(run_state(&conn, "c1"), ("done".into(), Some("quiet".into())));
    }

    #[test]
    fn later_report_flags_new_keys() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        report_db(&conn, &running_check(&conn, "c1"), &report_of(vec![problem("a", "A", None)]), now()).ok().unwrap();
        let out = report_db(&conn, &running_check(&conn, "c2"), &report_of(vec![problem("a", "A", None), problem("c", "T3", None)]), now())
            .ok()
            .unwrap();
        assert_eq!(out.new_titles, vec!["T3".to_string()]);
        assert_eq!(run_state(&conn, "c2").1, Some("1 new".into()));
    }

    #[test]
    fn missing_key_clears_unless_partial() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        report_db(&conn, &running_check(&conn, "c1"), &report_of(vec![problem("a", "A", None), problem("b", "B", None)]), now()).ok().unwrap();
        let partial = WatchReport { problems: vec![problem("a", "A", None)], partial: true };
        report_db(&conn, &running_check(&conn, "c2"), &partial, now()).ok().unwrap();
        assert_eq!(issue(&conn, "b").0, "open");
        report_db(&conn, &running_check(&conn, "c3"), &report_of(vec![problem("a", "A", None)]), now()).ok().unwrap();
        assert_eq!(issue(&conn, "b").0, "cleared");
    }

    #[test]
    fn comeback_after_clear_untakes_unless_cant_fix() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        report_db(&conn, &running_check(&conn, "c1"), &report_of(vec![]), now()).ok().unwrap();
        conn.execute_batch(
            "INSERT INTO watch_issues (id, watcher, key, project_id, title, state, taken_run_id, outcome) VALUES
               ('i1', 'sentry', 'f', 'ps', 'F', 'cleared', 'r1', 'fixed'),
               ('i2', 'sentry', 'x', 'ps', 'X', 'cleared', 'r2', 'cant_fix');",
        )
        .unwrap();
        let out = report_db(&conn, &running_check(&conn, "c2"), &report_of(vec![problem("f", "F", None), problem("x", "X", None)]), now())
            .ok()
            .unwrap();
        assert_eq!(out.new_titles.len(), 2);
        assert_eq!(issue(&conn, "f"), ("open".into(), None, None));
        assert_eq!(issue(&conn, "x"), ("open".into(), Some("r2".into()), Some("cant_fix".into())));
    }

    #[test]
    fn recently_resolved_key_is_ignored() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        report_db(&conn, &running_check(&conn, "c1"), &report_of(vec![]), now()).ok().unwrap();
        conn.execute(
            "INSERT INTO watch_issues (id, watcher, key, project_id, title, state, resolved_at) VALUES ('i1', 'sentry', 'r', 'ps', 'R', 'cleared', ?1)",
            params![sql_time(now() - Duration::minutes(5))],
        )
        .unwrap();
        let out = report_db(&conn, &running_check(&conn, "c2"), &report_of(vec![problem("r", "R", None)]), now()).ok().unwrap();
        assert!(out.new_titles.is_empty());
        assert_eq!(issue(&conn, "r").0, "cleared");
    }

    #[test]
    fn queues_at_most_two_debug_runs_by_folder() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        let problems = vec![
            problem("w1", "W1", Some("webapp")),
            problem("b1", "B1", Some("backend")),
            problem("b2", "B2", Some("backend")),
            problem("b3", "B3", Some("backend")),
        ];
        let out = report_db(&conn, &running_check(&conn, "c1"), &report_of(problems.clone()), now()).ok().unwrap();
        assert_eq!(out.queued_runs.len(), 2);
        let notes: Vec<String> = {
            let mut stmt = conn.prepare("SELECT note FROM job_runs WHERE note LIKE 'watch:%' ORDER BY rowid").unwrap();
            stmt.query_map([], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
        };
        assert_eq!(notes, vec!["watch:backend".to_string(), "watch:webapp".to_string()]);
        let debug: (String, String) =
            conn.query_row("SELECT name, action FROM jobs WHERE name = 'Debug · sentry'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert!(debug.1.contains("\"priority\":\"urgent\"") && debug.1.contains("\"computer_id\":\"mac\""), "{}", debug.1);
        let again = report_db(&conn, &running_check(&conn, "c2"), &report_of(problems), now()).ok().unwrap();
        assert!(again.queued_runs.is_empty());
    }

    #[test]
    fn no_debug_tool_queues_nothing() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        let out = report_db(&conn, &running_check(&conn, "c1"), &report_of(vec![problem("a", "A", None)]), now()).ok().unwrap();
        assert!(out.queued_runs.is_empty());
        assert!(debug_job_id(&conn, "sentry").unwrap().is_none());
    }

    #[test]
    fn overwhelmed_once_per_day() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        let many: Vec<WatchProblem> = (0..23).map(|i| problem(&format!("k{i}"), "T", Some("backend"))).collect();
        let out = report_db(&conn, &running_check(&conn, "c1"), &report_of(many.clone()), now()).ok().unwrap();
        assert_eq!(out.overwhelmed.as_deref(), Some("23 issues waiting for a conversation"));
        let again = report_db(&conn, &running_check(&conn, "c2"), &report_of(many), now()).ok().unwrap();
        assert!(again.overwhelmed.is_none());
    }

    #[test]
    fn report_on_non_watch_run_conflicts() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        conn.execute_batch(
            "INSERT INTO jobs (id, name, enabled, trigger, action, max_runs_per_day) VALUES ('p', 'push', 1, '{\"kind\":\"manual\"}', '{\"kind\":\"push\",\"title\":\"t\",\"body\":\"\"}', 4);
             INSERT INTO job_runs (id, job_id, due_at, state) VALUES ('pr', 'p', datetime('now'), 'running');",
        )
        .unwrap();
        assert!(matches!(report_db(&conn, "pr", &report_of(vec![]), now()), Err(WatchError::Conflict(_))));
    }

    #[test]
    fn new_issue_push_wording() {
        let mut out = ReportOutcome { watcher: "sentry".into(), new_titles: vec!["GO-1: boom".into()], ..Default::default() };
        assert_eq!(new_issues_push(&out), Some(("Sentry · GO-1: boom".into(), String::new())));
        out.new_titles.push("GO-2: bang".into());
        assert_eq!(new_issues_push(&out).unwrap().0, "2 new Sentry issues");
    }
}
