//! Watchers: a Mac's runner posts each check's problems here. The hub keeps one issue per
//! watcher and key, pushes new ones, and queues debugging conversations (runs of the
//! "Debug · <watcher>" job, at most 2 at work) that take untaken issues when they start.

use std::collections::HashSet;

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use todo_shared::{CreateJobRequest, Job, JobAction, JobTrigger, LimitSetting, Priority, WatchIssue, WatchReport};
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
/// A resolve the watcher's Mac never answered reopens after this.
const RESOLVE_TIMEOUT_MINUTES: i64 = 30;
/// Check runs that found nothing new are deleted after this.
const QUIET_RUNS_KEPT_DAYS: i64 = 2;
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
/// SQL: run `r` is at work. `?G` is the grace cutoff for a conversation still starting
/// (no status yet, or idle before its first turn).
const AT_WORK: &str = "(r.state IN ('due','waiting')
     OR (r.state = 'running' AND r.todo_id IS NULL)
     OR (r.todo_id IS NOT NULL AND EXISTS (SELECT 1 FROM conversations c WHERE c.todo_id = r.todo_id
           AND (c.status IN ('busy','waiting')
                OR (c.status = 'unknown' AND c.created_at >= ?G)
                OR (c.status = 'idle' AND c.status_turn_ns IS NULL AND c.created_at >= ?G)))))";

pub(crate) fn at_work_count(conn: &Connection, debug_job_id: &str, now: DateTime<Utc>, except: Option<&str>) -> rusqlite::Result<usize> {
    let sql = format!("SELECT COUNT(*) FROM job_runs r WHERE r.job_id = ?1 AND (?2 IS NULL OR r.id != ?2) AND {}", AT_WORK.replace("?G", "?3"));
    let n: i64 = conn.query_row(
        &sql,
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
        // A repo inside the project: never absolute, never climbing out.
        let folder = p
            .folder
            .as_deref()
            .map(|f| f.trim().trim_matches('/'))
            .filter(|f| !f.is_empty() && !f.starts_with('~') && !f.split('/').any(|part| part == ".." || part == "."));
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

/// Clock upkeep: issues held by a run that's no longer at work and gave no outcome go back
/// to the queue; resolves this Mac never answered reopen after 30 minutes; quiet checks older
/// than 2 days are deleted. True when anything changed.
pub(crate) fn watch_upkeep(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<bool> {
    let stamp = sql_time(now);
    let released = conn.execute(
        &format!(
            "UPDATE watch_issues SET taken_run_id = NULL, updated_at = ?1
             WHERE taken_run_id IS NOT NULL AND outcome IS NULL
               AND NOT EXISTS (SELECT 1 FROM job_runs r WHERE r.id = watch_issues.taken_run_id AND {})",
            AT_WORK.replace("?G", "?2")
        ),
        params![stamp, sql_time(now - Duration::minutes(UNKNOWN_GRACE_MINUTES))],
    )?;
    let reopened = conn.execute(
        "UPDATE watch_issues SET state = 'open', resolve_error = 'this Mac didn''t answer', updated_at = ?1
         WHERE state = 'resolving' AND resolve_requested_at < ?2",
        params![stamp, sql_time(now - Duration::minutes(RESOLVE_TIMEOUT_MINUTES))],
    )?;
    let pruned = conn.execute(
        "DELETE FROM job_runs WHERE state = 'done' AND result = 'quiet' AND due_at < ?1
           AND job_id IN (SELECT id FROM jobs WHERE json_extract(action, '$.kind') = 'watch')",
        params![sql_time(now - Duration::days(QUIET_RUNS_KEPT_DAYS))],
    )?;
    Ok(released + reopened + pruned > 0)
}

/// Issues for the app: `open` (open or resolving) or `recent` (cleared in the last 7 days).
pub(crate) fn list_issues_db(conn: &Connection, which: &str, now: DateTime<Utc>) -> rusqlite::Result<Vec<WatchIssue>> {
    let filter = if which == "recent" { "i.state = 'cleared' AND i.cleared_at >= ?1" } else { "i.state != 'cleared' AND ?1 IS NOT NULL" };
    let mut stmt = conn.prepare(&format!(
        "SELECT i.id, i.watcher, i.key, i.job_id, i.project_id, i.title, i.details, i.url, i.folder, i.state, i.taken_run_id,
                r.todo_id, i.outcome, i.outcome_note, i.resolve_error, i.first_seen, i.last_seen, i.cleared_at, i.updated_at
         FROM watch_issues i LEFT JOIN job_runs r ON r.id = i.taken_run_id
         WHERE {filter} ORDER BY i.last_seen DESC, i.rowid DESC LIMIT 500"
    ))?;
    let rows = stmt.query_map(params![sql_time(now - Duration::days(7))], |r| {
        Ok(WatchIssue {
            id: r.get(0)?,
            watcher: r.get(1)?,
            key: r.get(2)?,
            job_id: r.get(3)?,
            project_id: r.get(4)?,
            title: r.get(5)?,
            details: r.get(6)?,
            url: r.get(7)?,
            folder: r.get(8)?,
            state: r.get(9)?,
            taken_run_id: r.get(10)?,
            todo_id: r.get(11)?,
            outcome: r.get(12)?,
            outcome_note: r.get(13)?,
            resolve_error: r.get(14)?,
            first_seen: r.get(15)?,
            last_seen: r.get(16)?,
            cleared_at: r.get(17)?,
            updated_at: r.get(18)?,
        })
    })?;
    rows.collect()
}

/// The user's "Resolve in Sentry": the watcher's computer does it on its next tick.
pub(crate) fn request_resolve_db(conn: &Connection, id: &str, now: DateTime<Utc>) -> Result<(), WatchError> {
    let changed = conn.execute(
        "UPDATE watch_issues SET state = 'resolving', resolve_requested_at = ?2, resolve_error = NULL, updated_at = ?2
         WHERE id = ?1 AND state = 'open'",
        params![id, sql_time(now)],
    )?;
    if changed == 0 {
        return Err(missing_or(conn, id, "Only an open issue can be resolved")?);
    }
    Ok(())
}

/// "Try again" for an issue a conversation couldn't fix or left for the user: back in the
/// queue, and a conversation is queued if there's room.
pub(crate) fn retry_db(conn: &Connection, id: &str, now: DateTime<Utc>) -> Result<(), WatchError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let changed = tx.execute(
        "UPDATE watch_issues SET taken_run_id = NULL, outcome = NULL, outcome_note = NULL, updated_at = ?2
         WHERE id = ?1 AND state = 'open' AND outcome IN ('needs_you','cant_fix')",
        params![id, sql_time(now)],
    )?;
    if changed == 0 {
        return Err(missing_or(&tx, id, "Only an issue that needs you or can't be fixed can be tried again")?);
    }
    requeue_for_issue(&tx, "id = ?1", id, now)?;
    tx.commit()?;
    Ok(())
}

fn missing_or(conn: &Connection, id: &str, conflict: &'static str) -> rusqlite::Result<WatchError> {
    let exists: bool = conn.query_row("SELECT EXISTS (SELECT 1 FROM watch_issues WHERE id = ?1)", params![id], |r| r.get(0))?;
    Ok(if exists { WatchError::Conflict(conflict) } else { WatchError::NotFound("Issue not found") })
}

/// Queue debug runs for the watch job of the issue matching `filter` (one `?1` parameter).
fn requeue_for_issue(conn: &Connection, filter: &str, value: &str, now: DateTime<Utc>) -> Result<(), WatchError> {
    let job_id: Option<String> =
        conn.query_row(&format!("SELECT job_id FROM watch_issues WHERE {filter} LIMIT 1"), params![value], |r| r.get(0)).optional()?.flatten();
    if let Some(job) = job_id.map(|j| load_job(conn, &j)).transpose()?.flatten() {
        queue_debug_runs(conn, &job, now)?;
    }
    Ok(())
}

pub(crate) const OUTCOMES: [&str; 3] = ["fixed", "needs_you", "cant_fix"];

#[derive(Debug, serde::Deserialize)]
pub struct OutcomeRequest {
    pub key: String,
    pub outcome: String,
    #[serde(default)]
    pub note: String,
}

#[derive(Debug, serde::Deserialize)]
pub struct ReleaseRequest {
    pub keys: Vec<String>,
}

#[derive(Debug, serde::Deserialize)]
pub struct OverwhelmedRequest {
    #[serde(default)]
    pub why: String,
}

/// The agent's outcome for one issue its run took.
pub(crate) fn outcome_db(conn: &Connection, run_id: &str, req: &OutcomeRequest, now: DateTime<Utc>) -> Result<(), WatchError> {
    if !OUTCOMES.contains(&req.outcome.as_str()) {
        return Err(WatchError::BadRequest("outcome must be fixed, needs_you or cant_fix"));
    }
    let note: String = req.note.trim().chars().take(500).collect();
    let changed = conn.execute(
        "UPDATE watch_issues SET outcome = ?3, outcome_note = ?4, updated_at = ?5 WHERE taken_run_id = ?1 AND key = ?2",
        params![run_id, req.key.trim(), req.outcome, note, sql_time(now)],
    )?;
    if changed == 0 {
        return Err(WatchError::NotFound("Issue not taken by this run"));
    }
    Ok(())
}

/// The agent gives issues back; a conversation is queued for them if there's room.
pub(crate) fn release_db(conn: &Connection, run_id: &str, req: &ReleaseRequest, now: DateTime<Utc>) -> Result<usize, WatchError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let mut released = 0;
    for key in &req.keys {
        released += tx.execute(
            "UPDATE watch_issues SET taken_run_id = NULL, outcome = NULL, outcome_note = NULL, updated_at = ?3
             WHERE taken_run_id = ?1 AND key = ?2",
            params![run_id, key.trim(), sql_time(now)],
        )?;
    }
    if released > 0 {
        // The run still holds others or is at work: requeue from any issue of the same watcher.
        let watcher: Option<String> = tx
            .query_row("SELECT watcher FROM watch_issues WHERE key = ?1", params![req.keys.first().map(|k| k.trim()).unwrap_or_default()], |r| r.get(0))
            .optional()?;
        if let Some(watcher) = watcher {
            requeue_for_issue(&tx, "watcher = ?1 AND job_id IS NOT NULL", &watcher, now)?;
        }
    }
    tx.commit()?;
    Ok(released)
}

/// The "<watch job> needs you" push for a debugging run, with its todo.
pub(crate) fn overwhelmed_target(conn: &Connection, run_id: &str) -> Result<(String, Option<String>), WatchError> {
    let run = load_run(conn, run_id)?.ok_or(WatchError::NotFound("Run not found"))?;
    let name: Option<String> = conn
        .query_row(
            "SELECT j.name FROM watch_issues i JOIN jobs j ON j.id = i.job_id WHERE i.taken_run_id = ?1 LIMIT 1",
            params![run_id],
            |r| r.get(0),
        )
        .optional()?;
    let name = match name {
        Some(n) => n,
        None if run.note.as_deref().is_some_and(|n| n.starts_with("watch:")) => {
            load_job(conn, &run.job_id)?.map(|j| j.name).unwrap_or_else(|| "A watcher".into())
        }
        None => return Err(WatchError::NotFound("Not a debugging run")),
    };
    Ok((name, run.todo_id))
}

#[derive(Debug, serde::Deserialize)]
pub struct ResolveResult {
    pub ok: bool,
    #[serde(default)]
    pub message: String,
}

/// The runner's answer to a resolve: cleared, or back to open with the error.
pub(crate) fn resolve_result_db(conn: &Connection, id: &str, req: &ResolveResult, now: DateTime<Utc>) -> Result<(), WatchError> {
    let stamp = sql_time(now);
    let changed = if req.ok {
        conn.execute(
            "UPDATE watch_issues SET state = 'cleared', cleared_at = ?2, resolved_at = ?2, resolve_error = NULL, updated_at = ?2
             WHERE id = ?1 AND state = 'resolving'",
            params![id, stamp],
        )?
    } else {
        let message: String = req.message.trim().chars().take(200).collect();
        conn.execute(
            "UPDATE watch_issues SET state = 'open', resolve_error = ?3, updated_at = ?2 WHERE id = ?1 AND state = 'resolving'",
            params![id, stamp, if message.is_empty() { "resolve failed".to_string() } else { message }],
        )?
    };
    if changed == 0 {
        let exists: bool = conn.query_row("SELECT EXISTS (SELECT 1 FROM watch_issues WHERE id = ?1)", params![id], |r| r.get(0))?;
        return Err(if exists { WatchError::Conflict("Issue is not resolving") } else { WatchError::NotFound("Issue not found") });
    }
    Ok(())
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

pub async fn resolve_result(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<ResolveResult>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match resolve_result_db(&conn, &path, &body, Utc::now()) {
        Ok(()) => {
            broadcaster.send();
            HttpResponse::Ok().json(serde_json::json!({"ok": true}))
        }
        Err(e) => respond(e),
    }
}

macro_rules! conn {
    ($pool:expr) => {
        match $pool.get() {
            Ok(c) => c,
            Err(e) => return server_error(e),
        }
    };
}

fn done(result: Result<impl serde::Serialize, WatchError>, broadcaster: &Broadcaster) -> HttpResponse {
    match result {
        Ok(v) => {
            broadcaster.send();
            HttpResponse::Ok().json(v)
        }
        Err(e) => respond(e),
    }
}

pub async fn list_issues(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let conn = conn!(pool);
    let which = query.get("state").map(String::as_str).unwrap_or("open");
    match list_issues_db(&conn, which, Utc::now()) {
        Ok(v) => HttpResponse::Ok().json(v),
        Err(e) => server_error(e),
    }
}

pub async fn resolve_issue(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    done(request_resolve_db(&conn, &path, Utc::now()).map(|_| serde_json::json!({"ok": true})), &broadcaster)
}

pub async fn retry_issue(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    done(retry_db(&conn, &path, Utc::now()).map(|_| serde_json::json!({"ok": true})), &broadcaster)
}

pub async fn run_outcome(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<OutcomeRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    done(outcome_db(&conn, &path, &body, Utc::now()).map(|_| serde_json::json!({"ok": true})), &broadcaster)
}

pub async fn run_release(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<ReleaseRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    done(release_db(&conn, &path, &body, Utc::now()).map(|n| serde_json::json!({"released": n})), &broadcaster)
}

pub async fn run_overwhelmed(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<OverwhelmedRequest>,
    notifier: web::Data<PushNotifier>,
) -> HttpResponse {
    let target = {
        let conn = conn!(pool);
        overwhelmed_target(&conn, &path)
    };
    match target {
        Ok((name, todo_id)) => {
            let why: String = body.why.trim().chars().take(300).collect();
            push_now(&pool, &notifier, format!("{name} needs you"), why, todo_id).await;
            HttpResponse::Ok().json(serde_json::json!({"ok": true}))
        }
        Err(e) => respond(e),
    }
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

    fn debug_run_with_conversation(conn: &Connection, run: &str, status: &str, turned: bool) {
        conn.execute("INSERT INTO todos (id, section, title) VALUES (?1, 'Si', 'fix')", params![format!("t-{run}")]).unwrap();
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, todo_id, note) VALUES (?1, 'w', datetime('now'), 'done', ?2, 'watch:backend')",
            params![run, format!("t-{run}")],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, status, status_turn_ns)
             VALUES (?1, ?2, 'mac', '~/w', 'claude', ?3, ?1, ?4, ?5)",
            params![format!("c-{run}"), format!("t-{run}"), format!("ai/claude/{run}"), status, turned.then_some(1_i64)],
        )
        .unwrap();
    }

    fn taken(conn: &Connection, key: &str, run: &str, outcome: Option<&str>) {
        conn.execute(
            "INSERT INTO watch_issues (id, watcher, key, job_id, project_id, title, folder, taken_run_id, outcome)
             VALUES (?1, 'sentry', ?1, 'w', 'ps', ?1, 'backend', ?2, ?3)",
            params![key, run, outcome],
        )
        .unwrap();
    }

    #[test]
    fn finished_conversation_releases_unreported_issues() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        debug_run_with_conversation(&conn, "r1", "idle", true);
        taken(&conn, "open-one", "r1", None);
        taken(&conn, "fixed-one", "r1", Some("fixed"));
        assert!(watch_upkeep(&conn, Utc::now()).unwrap());
        assert_eq!(issue(&conn, "open-one").1, None);
        assert_eq!(issue(&conn, "fixed-one").1.as_deref(), Some("r1"));
    }

    #[test]
    fn busy_conversation_keeps_issues() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        debug_run_with_conversation(&conn, "r1", "busy", true);
        debug_run_with_conversation(&conn, "r2", "idle", false);
        taken(&conn, "a", "r1", None);
        taken(&conn, "b", "r2", None);
        watch_upkeep(&conn, Utc::now()).unwrap();
        assert_eq!(issue(&conn, "a").1.as_deref(), Some("r1"));
        assert_eq!(issue(&conn, "b").1.as_deref(), Some("r2"), "idle before its first turn is still starting");
    }

    #[test]
    fn stale_resolving_reopens_after_30_minutes() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        conn.execute(
            "INSERT INTO watch_issues (id, watcher, key, project_id, title, state, resolve_requested_at) VALUES
               ('i1', 'sentry', 'old', 'ps', 'O', 'resolving', ?1), ('i2', 'sentry', 'new', 'ps', 'N', 'resolving', ?2)",
            params![sql_time(now() - Duration::minutes(31)), sql_time(now() - Duration::minutes(5))],
        )
        .unwrap();
        watch_upkeep(&conn, now()).unwrap();
        let error: Option<String> = conn.query_row("SELECT resolve_error FROM watch_issues WHERE id = 'i1'", [], |r| r.get(0)).unwrap();
        assert_eq!((issue(&conn, "old").0.as_str(), error.as_deref()), ("open", Some("this Mac didn't answer")));
        assert_eq!(issue(&conn, "new").0, "resolving");
    }

    #[test]
    fn quiet_watch_runs_pruned_and_hidden() {
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, None);
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, result) VALUES
               ('old', 'w', ?1, 'done', 'quiet'), ('fresh', 'w', ?2, 'done', 'quiet'), ('loud', 'w', ?2, 'done', '1 new')",
            params![sql_time(now() - Duration::days(3)), sql_time(now())],
        )
        .unwrap();
        let ids: Vec<String> = crate::jobs::recent_runs_db(&conn, 50).unwrap().into_iter().map(|r| r.run.id).collect();
        assert_eq!(ids, vec!["loud".to_string()]);
        watch_upkeep(&conn, now()).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 2);
    }

    #[actix_web::test]
    async fn issue_endpoints_list_resolve_and_retry() {
        use crate::test_support::{get, post};
        use actix_web::http::StatusCode;
        use serde_json::json;
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        debug_run_with_conversation(&conn, "r1", "busy", true);
        taken(&conn, "stuck", "r1", Some("cant_fix"));
        taken(&conn, "working", "r1", None);
        conn.execute("INSERT INTO watch_issues (id, watcher, key, project_id, title, state, cleared_at) VALUES ('gone', 'sentry', 'gone', 'ps', 'G', 'cleared', datetime('now'))", []).unwrap();
        let (status, open) = get(&pool, "/api/watch/issues?state=open").await;
        assert_eq!(status, StatusCode::OK, "{open}");
        assert_eq!(open.as_array().unwrap().len(), 2);
        assert!(open.as_array().unwrap().iter().all(|i| i["todo_id"] == "t-r1"));
        assert_eq!(get(&pool, "/api/watch/issues?state=recent").await.1.as_array().unwrap().len(), 1);
        assert_eq!(post(&pool, "/api/watch/issues/working/retry", json!({})).await.0, StatusCode::CONFLICT);
        assert_eq!(post(&pool, "/api/watch/issues/stuck/retry", json!({})).await.0, StatusCode::OK);
        assert_eq!(issue(&conn, "stuck"), ("open".into(), None, None));
        assert_eq!(post(&pool, "/api/watch/issues/working/resolve", json!({})).await.0, StatusCode::OK);
        assert_eq!(issue(&conn, "working").0, "resolving");
        assert_eq!(post(&pool, "/api/watch/issues/working/resolve", json!({})).await.0, StatusCode::CONFLICT);
        assert_eq!(post(&pool, "/api/watch/issues/gone/resolve", json!({})).await.0, StatusCode::CONFLICT);
    }

    #[actix_web::test]
    async fn agent_endpoints_only_touch_their_run() {
        use crate::test_support::post;
        use actix_web::http::StatusCode;
        use serde_json::json;
        let (_db, pool) = pool("watch");
        let conn = pool.get().unwrap();
        seed_watch(&conn, Some("claude"));
        debug_run_with_conversation(&conn, "r1", "busy", true);
        debug_run_with_conversation(&conn, "r2", "busy", true);
        taken(&conn, "mine", "r1", None);
        taken(&conn, "give-back", "r1", None);
        taken(&conn, "theirs", "r2", None);
        let ok = post(&pool, "/api/watch/runs/r1/outcome", json!({"key": "mine", "outcome": "fixed", "note": "nil check"})).await;
        assert_eq!(ok.0, StatusCode::OK, "{}", ok.1);
        assert_eq!(issue(&conn, "mine").2.as_deref(), Some("fixed"));
        assert_eq!(post(&pool, "/api/watch/runs/r1/outcome", json!({"key": "theirs", "outcome": "fixed", "note": ""})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(post(&pool, "/api/watch/runs/r1/outcome", json!({"key": "mine", "outcome": "done", "note": ""})).await.0, StatusCode::BAD_REQUEST);
        let (status, v) = post(&pool, "/api/watch/runs/r1/release", json!({"keys": ["give-back", "theirs"]})).await;
        assert_eq!((status, &v["released"]), (StatusCode::OK, &json!(1)));
        assert_eq!(issue(&conn, "give-back").1, None);
        assert_eq!(issue(&conn, "theirs").1.as_deref(), Some("r2"));
        assert_eq!(post(&pool, "/api/watch/runs/r1/overwhelmed", json!({"why": "too many"})).await.0, StatusCode::OK);
        assert_eq!(post(&pool, "/api/watch/runs/nope/overwhelmed", json!({"why": "x"})).await.0, StatusCode::NOT_FOUND);
    }

    #[test]
    fn new_issue_push_wording() {
        let mut out = ReportOutcome { watcher: "sentry".into(), new_titles: vec!["GO-1: boom".into()], ..Default::default() };
        assert_eq!(new_issues_push(&out), Some(("Sentry · GO-1: boom".into(), String::new())));
        out.new_titles.push("GO-2: bang".into());
        assert_eq!(new_issues_push(&out).unwrap().0, "2 new Sentry issues");
    }
}
