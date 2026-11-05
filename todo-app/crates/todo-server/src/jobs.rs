//! Scheduler jobs: CRUD, "Run now", run history and the global limit-guard settings.

use actix_web::{web, HttpResponse};
use chrono::{SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension, Row};
use todo_shared::{
    CreateJobRequest, DeleteResponse, Job, JobAction, JobRun, JobTrigger, LimitSetting, SchedulerSettings,
    UpdateJobRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, conflict, get_computer, not_found, server_error};
use crate::cron;
use crate::db::DbPool;
use crate::projects::project_exists;

const RUN_COLS: &str = "id, job_id, due_at, state, computer_id, todo_id, waiting_reason, result, started_at, created_at, updated_at, note";
const DEFAULT_RUNS: usize = 20;
const MAX_RUNS: usize = 200;
const TOOLS: [&str; 2] = ["claude", "codex"];

pub(crate) enum JobError {
    BadRequest(String),
    NotFound(&'static str),
    Conflict(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for JobError {
    fn from(e: rusqlite::Error) -> Self {
        JobError::Db(e)
    }
}

fn respond(e: JobError) -> HttpResponse {
    match e {
        JobError::BadRequest(msg) => bad_request(&msg),
        JobError::NotFound(msg) => not_found(msg),
        JobError::Conflict(msg) => conflict(msg),
        JobError::Db(e) => server_error(e),
    }
}

pub(crate) fn row_to_run(row: &Row) -> rusqlite::Result<JobRun> {
    Ok(JobRun {
        id: row.get(0)?,
        job_id: row.get(1)?,
        due_at: row.get(2)?,
        state: row.get(3)?,
        computer_id: row.get(4)?,
        todo_id: row.get(5)?,
        waiting_reason: row.get(6)?,
        result: row.get(7)?,
        started_at: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
        note: row.get(11)?,
    })
}

pub(crate) fn load_run(conn: &Connection, id: &str) -> rusqlite::Result<Option<JobRun>> {
    conn.query_row(&format!("SELECT {RUN_COLS} FROM job_runs WHERE id = ?1"), params![id], row_to_run).optional()
}

fn last_run(conn: &Connection, job_id: &str) -> rusqlite::Result<Option<JobRun>> {
    conn.query_row(
        &format!("SELECT {RUN_COLS} FROM job_runs WHERE job_id = ?1 ORDER BY created_at DESC, rowid DESC LIMIT 1"),
        params![job_id],
        row_to_run,
    )
    .optional()
}

/// The next cron fire time (RFC 3339 UTC) of an enabled cron job.
fn next_fire_at(enabled: bool, trigger: &JobTrigger) -> Option<String> {
    match trigger {
        JobTrigger::Cron { cron } if enabled => cron::parse(cron)
            .ok()?
            .next_after(Utc::now(), cron::TZ)
            .map(|t| t.to_rfc3339_opts(SecondsFormat::Secs, true)),
        _ => None,
    }
}

fn row_to_job(row: &Row) -> rusqlite::Result<(Job, String)> {
    let trigger: String = row.get(3)?;
    let action: String = row.get(4)?;
    let bad = |e: serde_json::Error| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e));
    let trigger: JobTrigger = serde_json::from_str(&trigger).map_err(bad)?;
    let action: JobAction = serde_json::from_str(&action).map_err(bad)?;
    let enabled = row.get::<_, i64>(2)? != 0;
    let id: String = row.get(0)?;
    Ok((
        Job {
            id: id.clone(),
            name: row.get(1)?,
            enabled,
            next_fire_at: next_fire_at(enabled, &trigger),
            schedule_text: Some(match &trigger {
                JobTrigger::Cron { cron } => cron::describe(cron),
                JobTrigger::Manual => "Manual".to_string(),
            }),
            trigger,
            action,
            max_runs_per_day: row.get::<_, i64>(5)?.max(0) as u32,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
            last_run: None,
        },
        id,
    ))
}

const JOB_COLS: &str = "id, name, enabled, trigger, action, max_runs_per_day, created_at, updated_at";

pub(crate) fn load_job(conn: &Connection, id: &str) -> rusqlite::Result<Option<Job>> {
    let found = conn
        .query_row(&format!("SELECT {JOB_COLS} FROM jobs WHERE id = ?1"), params![id], row_to_job)
        .optional()?;
    match found {
        Some((mut job, id)) => {
            job.last_run = last_run(conn, &id)?;
            Ok(Some(job))
        }
        None => Ok(None),
    }
}

pub(crate) fn list_jobs_db(conn: &Connection) -> rusqlite::Result<Vec<Job>> {
    let mut stmt = conn.prepare(&format!("SELECT {JOB_COLS} FROM jobs ORDER BY name COLLATE NOCASE, created_at"))?;
    let rows = stmt.query_map([], row_to_job)?.collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter()
        .map(|(mut job, id)| {
            job.last_run = last_run(conn, &id)?;
            Ok(job)
        })
        .collect()
}

fn check_threshold(value: Option<u8>) -> Result<(), JobError> {
    match value {
        Some(v) if v == 0 || v > 100 => Err(JobError::BadRequest("thresholds must be 1-100".into())),
        _ => Ok(()),
    }
}

fn validate(conn: &Connection, name: &str, trigger: &JobTrigger, action: &JobAction) -> Result<(), JobError> {
    if name.trim().is_empty() {
        return Err(JobError::BadRequest("name is required".into()));
    }
    if let JobTrigger::Cron { cron } = trigger {
        cron::parse(cron).map_err(JobError::BadRequest)?;
    }
    match action {
        JobAction::Conversation { .. } | JobAction::Research { .. } => {
            let parts = action.conversation_parts().expect("conversation-like action");
            let (project_id, computer_id, tool, prompt, limit) = (parts.project_id, parts.computer_id, parts.tool, parts.prompt, &parts.limit);
            // `auto`: the runner picks claude or codex by weekly headroom (the assistant).
            let auto = tool == "auto" && !action.is_research();
            if !TOOLS.contains(&tool) && !auto {
                return Err(JobError::BadRequest("tool must be claude or codex".into()));
            }
            if !action.is_research() && prompt.trim().is_empty() {
                return Err(JobError::BadRequest("prompt is required".into()));
            }
            if let LimitSetting::Wait { five_hour, weekly } = limit {
                check_threshold(*five_hour)?;
                check_threshold(*weekly)?;
            }
            if !project_exists(conn, project_id)? {
                return Err(JobError::NotFound("Project not found"));
            }
            if let Some(computer_id) = computer_id {
                if get_computer(conn, computer_id)?.is_none() {
                    return Err(JobError::NotFound("Computer not found"));
                }
            }
        }
        JobAction::Push { title, .. } if title.trim().is_empty() => {
            return Err(JobError::BadRequest("push title is required".into()));
        }
        JobAction::Todo { title, project_id, .. } => {
            if title.trim().is_empty() {
                return Err(JobError::BadRequest("todo title is required".into()));
            }
            if let Some(project_id) = project_id {
                if !project_exists(conn, project_id)? {
                    return Err(JobError::NotFound("Project not found"));
                }
            }
        }
        JobAction::Push { .. } => {}
        JobAction::Watch { project_id, computer_id, watcher, debug_tool, .. } => {
            if watcher.is_empty() || !watcher.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')) || watcher.starts_with('.') {
                return Err(JobError::BadRequest("watcher must be a file name in ~/.ai-remote/watchers".into()));
            }
            if let Some(tool) = debug_tool {
                if !TOOLS.contains(&tool.as_str()) {
                    return Err(JobError::BadRequest("debug tool must be claude or codex".into()));
                }
            }
            if !project_exists(conn, project_id)? {
                return Err(JobError::NotFound("Project not found"));
            }
            if get_computer(conn, computer_id)?.is_none() {
                return Err(JobError::NotFound("Computer not found"));
            }
        }
    }
    Ok(())
}

fn json(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

/// One watch job per watcher: issues are kept per watcher, so a second job's checks would clear
/// the first one's issues (and push them again when they came back).
fn watcher_free(conn: &Connection, action: &JobAction, except: Option<&str>) -> Result<(), JobError> {
    let JobAction::Watch { watcher, .. } = action else { return Ok(()) };
    let taken: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM jobs WHERE json_extract(action, '$.kind') = 'watch'
             AND json_extract(action, '$.watcher') = ?1 AND (?2 IS NULL OR id != ?2))",
        params![watcher, except],
        |r| r.get(0),
    )?;
    if taken {
        return Err(JobError::Conflict("Another watch job already uses this watcher"));
    }
    Ok(())
}

pub(crate) fn create_job_db(conn: &Connection, req: &CreateJobRequest) -> Result<Job, JobError> {
    validate(conn, &req.name, &req.trigger, &req.action)?;
    watcher_free(conn, &req.action, None)?;
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO jobs (id, name, enabled, trigger, action, max_runs_per_day, last_slot_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))",
        params![
            id,
            req.name.trim(),
            req.enabled.unwrap_or(true),
            json(&req.trigger),
            json(&req.action),
            req.max_runs_per_day.unwrap_or(4).clamp(1, 96)
        ],
    )?;
    load_job(conn, &id)?.ok_or(JobError::NotFound("Job not found"))
}

pub(crate) fn update_job_db(conn: &Connection, id: &str, req: &UpdateJobRequest) -> Result<Job, JobError> {
    let job = load_job(conn, id)?.ok_or(JobError::NotFound("Job not found"))?;
    // Switched back on, or a new schedule: start counting slots from now, so no slot from
    // the past fires at once.
    let restart = (req.enabled == Some(true) && !job.enabled) || req.trigger.as_ref().is_some_and(|t| *t != job.trigger);
    let name = req.name.clone().unwrap_or(job.name);
    let trigger = req.trigger.clone().unwrap_or(job.trigger);
    let action = req.action.clone().unwrap_or(job.action);
    validate(conn, &name, &trigger, &action)?;
    watcher_free(conn, &action, Some(id))?;
    conn.execute(
        "UPDATE jobs SET name = ?2, enabled = ?3, trigger = ?4, action = ?5, max_runs_per_day = ?6,
             updated_at = datetime('now') WHERE id = ?1",
        params![
            id,
            name.trim(),
            req.enabled.unwrap_or(job.enabled),
            json(&trigger),
            json(&action),
            req.max_runs_per_day.unwrap_or(job.max_runs_per_day).clamp(1, 96)
        ],
    )?;
    if restart {
        conn.execute("UPDATE jobs SET last_slot_at = datetime('now') WHERE id = ?1", params![id])?;
    }
    load_job(conn, id)?.ok_or(JobError::NotFound("Job not found"))
}

/// A `due` run for now: "Run now" (also for disabled jobs).
/// Jobs the hub runs for itself (a watcher's Debug job): not listed, not run by hand.
pub(crate) fn hidden_job_ids(conn: &Connection) -> rusqlite::Result<std::collections::HashSet<String>> {
    let mut stmt = conn.prepare("SELECT id FROM jobs WHERE watch_debug_for IS NOT NULL")?;
    let rows = stmt.query_map([], |r| r.get(0))?;
    rows.collect()
}

pub(crate) fn run_now_db(conn: &Connection, id: &str) -> Result<JobRun, JobError> {
    if load_job(conn, id)?.is_none() {
        return Err(JobError::NotFound("Job not found"));
    }
    if hidden_job_ids(conn)?.contains(id) {
        return Err(JobError::Conflict("This job runs only for its watcher's issues"));
    }
    let run_id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO job_runs (id, job_id, due_at, state) VALUES (?1, ?2, datetime('now'), 'due')",
        params![run_id, id],
    )?;
    load_run(conn, &run_id)?.ok_or(JobError::NotFound("Run not found"))
}

pub(crate) fn job_runs_db(conn: &Connection, id: &str, limit: usize) -> rusqlite::Result<Vec<JobRun>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {RUN_COLS} FROM job_runs WHERE job_id = ?1 ORDER BY due_at DESC, rowid DESC LIMIT ?2"
    ))?;
    let rows = stmt.query_map(params![id, limit.min(MAX_RUNS) as i64], row_to_run)?;
    rows.collect()
}

/// The newest runs across all jobs, with each job's name.
pub(crate) fn recent_runs_db(conn: &Connection, limit: usize) -> rusqlite::Result<Vec<todo_shared::RecentRun>> {
    let cols = RUN_COLS.split(", ").map(|c| format!("r.{c}")).collect::<Vec<_>>().join(", ");
    let mut stmt = conn.prepare(&format!(
        "SELECT {cols}, j.name FROM job_runs r JOIN jobs j ON j.id = r.job_id
         WHERE NOT (json_extract(j.action, '$.kind') = 'watch' AND (r.result IS 'quiet' OR r.state = 'skipped'))
         ORDER BY r.due_at DESC, r.rowid DESC LIMIT ?1"
    ))?;
    let rows = stmt.query_map(params![limit.min(MAX_RUNS) as i64], |row| {
        Ok(todo_shared::RecentRun { run: row_to_run(row)?, job_name: row.get(12)? })
    })?;
    rows.collect()
}

pub async fn recent_runs(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let limit = query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(50);
    match recent_runs_db(&conn, limit) {
        Ok(runs) => HttpResponse::Ok().json(runs),
        Err(e) => server_error(e),
    }
}

pub(crate) fn settings_db(conn: &Connection) -> rusqlite::Result<SchedulerSettings> {
    conn.query_row("SELECT five_hour, weekly, pause_waiting FROM scheduler_settings WHERE id = 1", [], |r| {
        Ok(SchedulerSettings {
            five_hour: r.get::<_, i64>(0)?.clamp(1, 100) as u8,
            weekly: r.get::<_, i64>(1)?.clamp(1, 100) as u8,
            pause_waiting: r.get::<_, i64>(2)? != 0,
        })
    })
}

// --- Handlers ---------------------------------------------------------------------

macro_rules! conn {
    ($pool:expr) => {
        match $pool.get() {
            Ok(c) => c,
            Err(e) => return server_error(e),
        }
    };
}

pub async fn list_jobs(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    let listed = list_jobs_db(&conn).and_then(|jobs| {
        let hidden = hidden_job_ids(&conn)?;
        Ok(jobs.into_iter().filter(|j| !hidden.contains(&j.id)).collect::<Vec<_>>())
    });
    match listed {
        Ok(jobs) => HttpResponse::Ok().json(jobs),
        Err(e) => server_error(e),
    }
}

pub async fn create_job(
    pool: web::Data<DbPool>,
    body: web::Json<CreateJobRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    match create_job_db(&conn, &body) {
        Ok(job) => {
            broadcaster.send();
            HttpResponse::Created().json(job)
        }
        Err(e) => respond(e),
    }
}

pub async fn update_job(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateJobRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    match update_job_db(&conn, &path, &body) {
        Ok(job) => {
            broadcaster.send();
            HttpResponse::Ok().json(job)
        }
        Err(e) => respond(e),
    }
}

pub async fn delete_job(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    // The job's runs go with it: count them first so its weeks keep their numbers.
    if let Err(e) = crate::weekly::tally_settled_runs(&conn) {
        return server_error(e);
    }
    match conn.execute("DELETE FROM jobs WHERE id = ?1", params![path.as_str()]) {
        Ok(0) => not_found("Job not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: path.into_inner() })
        }
        Err(e) => server_error(e),
    }
}

pub async fn run_job(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match run_now_db(&conn, &path) {
        Ok(run) => {
            broadcaster.send();
            HttpResponse::Created().json(run)
        }
        Err(e) => respond(e),
    }
}

pub async fn job_runs(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    query: web::Query<std::collections::HashMap<String, String>>,
) -> HttpResponse {
    let conn = conn!(pool);
    let limit = query.get("limit").and_then(|l| l.parse().ok()).unwrap_or(DEFAULT_RUNS);
    match job_runs_db(&conn, &path, limit) {
        Ok(runs) => HttpResponse::Ok().json(runs),
        Err(e) => server_error(e),
    }
}

pub async fn get_settings(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    match settings_db(&conn) {
        Ok(s) => HttpResponse::Ok().json(s),
        Err(e) => server_error(e),
    }
}

pub async fn put_settings(
    pool: web::Data<DbPool>,
    body: web::Json<SchedulerSettings>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    if !(1..=100).contains(&body.five_hour) || !(1..=100).contains(&body.weekly) {
        return bad_request("thresholds must be 1-100");
    }
    let conn = conn!(pool);
    match conn.execute(
        "UPDATE scheduler_settings SET five_hour = ?1, weekly = ?2, pause_waiting = ?3 WHERE id = 1",
        params![body.five_hour, body.weekly, body.pause_waiting],
    ) {
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(*body)
        }
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};

    use crate::test_support::{delete, get, patch, pool, post, put, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch("INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'a', 'Si', '~/a');").unwrap();
    }

    fn conversation_job(name: &str, trigger: Value) -> Value {
        json!({"name": name, "trigger": trigger, "action": {"kind": "conversation", "project_id": "pa", "computer_id": null,
            "tool": "claude", "folder": null, "prompt": "Research {project}", "priority": "background",
            "limit": {"mode": "wait", "five_hour": null, "weekly": null}}})
    }

    #[actix_web::test]
    async fn create_and_list_job() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        let (status, job) = post(&pool, "/api/jobs", conversation_job("Research", json!({"kind": "cron", "cron": "0 8 * * *"}))).await;
        assert_eq!(status, StatusCode::CREATED, "{job}");
        assert_eq!((&job["enabled"], &job["max_runs_per_day"]), (&json!(true), &json!(4)));
        assert!(job["next_fire_at"].as_str().unwrap().ends_with(":00:00Z") || job["next_fire_at"].as_str().unwrap().contains('T'));
        post(&pool, "/api/jobs", conversation_job("Manual one", json!({"kind": "manual"}))).await;
        let (_, list) = get(&pool, "/api/jobs").await;
        let list = list.as_array().unwrap();
        assert_eq!(list.len(), 2);
        let manual = list.iter().find(|j| j["name"] == "Manual one").unwrap();
        assert_eq!((&manual["next_fire_at"], &manual["last_run"]), (&Value::Null, &Value::Null));
    }

    fn watch_job(computer: &str, watcher: &str, tool: Value) -> Value {
        json!({"name": "Sentry", "trigger": {"kind": "cron", "cron": "*/10 * * * *"}, "action": {"kind": "watch",
            "project_id": "pa", "computer_id": computer, "watcher": watcher, "debug_tool": tool, "prompt": ""}})
    }

    #[actix_web::test]
    async fn watch_job_validation() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        assert_eq!(post(&pool, "/api/jobs", watch_job("nope", "sentry", json!("claude"))).await.0, StatusCode::NOT_FOUND);
        assert_eq!(post(&pool, "/api/jobs", watch_job("mac", "", json!("claude"))).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/jobs", watch_job("mac", "../x", json!("claude"))).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/jobs", watch_job("mac", "sentry", json!("cursor"))).await.0, StatusCode::BAD_REQUEST);
        let (status, job) = post(&pool, "/api/jobs", watch_job("mac", "sentry", Value::Null)).await;
        assert_eq!(status, StatusCode::CREATED, "{job}");
        assert_eq!(job["action"]["kind"], "watch");
        let (status, _) = post(&pool, "/api/jobs", watch_job("spread", "sentry", json!("claude"))).await;
        assert_eq!(status, StatusCode::CONFLICT, "a second job for one watcher would clear the first one's issues");
        let (status, other) = post(&pool, "/api/jobs", watch_job("mac", "logtail", Value::Null)).await;
        assert_eq!(status, StatusCode::CREATED, "{other}");
        let id = other["id"].as_str().unwrap();
        let rename = json!({"action": {"kind": "watch", "project_id": "pa", "computer_id": "mac", "watcher": "sentry", "debug_tool": null, "prompt": ""}});
        assert_eq!(patch(&pool, &format!("/api/jobs/{id}"), rename).await.0, StatusCode::CONFLICT);
        let same = json!({"action": {"kind": "watch", "project_id": "pa", "computer_id": "mac", "watcher": "logtail", "debug_tool": "claude", "prompt": ""}});
        assert_eq!(patch(&pool, &format!("/api/jobs/{id}"), same).await.0, StatusCode::OK, "a job keeps its own watcher");
    }

    #[actix_web::test]
    async fn create_job_validation() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        let cron = json!({"kind": "cron", "cron": "0 8 * * *"});
        let mut bad = conversation_job("", cron.clone());
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::BAD_REQUEST, "empty name");
        bad = conversation_job("x", json!({"kind": "cron", "cron": "61 * * * *"}));
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::BAD_REQUEST, "bad cron");
        bad = conversation_job("x", cron.clone());
        bad["action"]["tool"] = json!("cursor");
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::BAD_REQUEST, "tool");
        bad = conversation_job("x", cron.clone());
        bad["action"]["limit"] = json!({"mode": "wait", "five_hour": 101, "weekly": null});
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::BAD_REQUEST, "threshold");
        bad = conversation_job("x", cron.clone());
        bad["action"]["prompt"] = json!("  ");
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::BAD_REQUEST, "prompt");
        bad = conversation_job("x", cron.clone());
        bad["action"]["project_id"] = json!("nope");
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::NOT_FOUND, "project");
        bad = conversation_job("x", cron);
        bad["action"]["computer_id"] = json!("nope");
        assert_eq!(post(&pool, "/api/jobs", bad).await.0, StatusCode::NOT_FOUND, "computer");
    }

    #[actix_web::test]
    async fn patch_job_disables() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "cron", "cron": "0 8 * * *"}))).await;
        let (status, job) = patch(&pool, &format!("/api/jobs/{}", job["id"].as_str().unwrap()), json!({"enabled": false})).await;
        assert_eq!(status, StatusCode::OK, "{job}");
        assert_eq!((&job["enabled"], &job["next_fire_at"]), (&json!(false), &Value::Null));
        let (status, _) = patch(&pool, "/api/jobs/nope", json!({"enabled": false})).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn run_now_creates_due_run() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "manual"}))).await;
        let id = job["id"].as_str().unwrap();
        patch(&pool, &format!("/api/jobs/{id}"), json!({"enabled": false})).await;
        let (status, run) = post(&pool, &format!("/api/jobs/{id}/run"), json!({})).await;
        assert_eq!(status, StatusCode::CREATED, "{run}");
        assert_eq!((&run["state"], &run["job_id"]), (&json!("due"), &json!(id)));
        let (_, list) = get(&pool, "/api/jobs").await;
        assert_eq!(list[0]["last_run"]["id"], run["id"]);
    }

    #[actix_web::test]
    async fn runs_newest_first() {
        let (_db, pool) = pool("jobs");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "manual"}))).await;
        let id = job["id"].as_str().unwrap();
        conn.execute_batch(&format!(
            "INSERT INTO job_runs (id, job_id, due_at, state) VALUES
                 ('r1', '{id}', '2026-11-01 08:00:00', 'done'), ('r2', '{id}', '2026-11-02 08:00:00', 'failed'),
                 ('r3', '{id}', '2026-10-31 08:00:00', 'missed');"
        ))
        .unwrap();
        let (_, runs) = get(&pool, &format!("/api/jobs/{id}/runs?limit=2")).await;
        let ids: Vec<&str> = runs.as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["r2", "r1"]);
    }

    #[actix_web::test]
    async fn settings_get_put_validate() {
        let (_db, pool) = pool("jobs");
        let (_, s) = get(&pool, "/api/scheduler/settings").await;
        assert_eq!(s, json!({"five_hour": 60, "weekly": 80, "pause_waiting": false}));
        let (status, s) = put(&pool, "/api/scheduler/settings", json!({"five_hour": 40, "weekly": 90, "pause_waiting": true})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(s, json!({"five_hour": 40, "weekly": 90, "pause_waiting": true}));
        for bad in [json!({"five_hour": 0, "weekly": 90, "pause_waiting": false}), json!({"five_hour": 40, "weekly": 101, "pause_waiting": false})] {
            assert_eq!(put(&pool, "/api/scheduler/settings", bad).await.0, StatusCode::BAD_REQUEST);
        }
    }

    #[actix_web::test]
    async fn reenable_or_new_cron_does_not_backfire() {
        let (_db, pool) = pool("jobs");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "cron", "cron": "* * * * *"}))).await;
        let id = job["id"].as_str().unwrap();
        patch(&pool, &format!("/api/jobs/{id}"), json!({"enabled": false})).await;
        conn.execute("UPDATE jobs SET last_slot_at = datetime('now', '-1 day') WHERE id = ?1", rusqlite::params![id]).unwrap();
        patch(&pool, &format!("/api/jobs/{id}"), json!({"enabled": true})).await;
        crate::scheduler::tick_db(&conn, chrono::Utc::now()).unwrap();
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0, "re-enabling starts from now");
        conn.execute("UPDATE jobs SET last_slot_at = datetime('now', '-1 day') WHERE id = ?1", rusqlite::params![id]).unwrap();
        patch(&pool, &format!("/api/jobs/{id}"), json!({"trigger": {"kind": "cron", "cron": "*/2 * * * *"}})).await;
        crate::scheduler::tick_db(&conn, chrono::Utc::now()).unwrap();
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0, "a new cron starts from now");
    }

    #[actix_web::test]
    async fn jobs_include_schedule_text() {
        let (_db, pool) = pool("jobs");
        seed(&pool.get().unwrap());
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "cron", "cron": "0 9 * * 1-5"}))).await;
        assert_eq!(job["schedule_text"], "Weekdays at 09:00");
        let (_, job) = post(&pool, "/api/jobs", conversation_job("M", json!({"kind": "manual"}))).await;
        assert_eq!(job["schedule_text"], "Manual");
    }

    #[actix_web::test]
    async fn runs_list_newest_across_jobs() {
        let (_db, pool) = pool("jobs");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (_, a) = post(&pool, "/api/jobs", conversation_job("Alpha", json!({"kind": "manual"}))).await;
        let (_, b) = post(&pool, "/api/jobs", conversation_job("Beta", json!({"kind": "manual"}))).await;
        conn.execute_batch(&format!(
            "INSERT INTO job_runs (id, job_id, due_at, state) VALUES
                 ('r1', '{a}', '2026-11-01 08:00:00', 'done'), ('r2', '{b}', '2026-11-02 08:00:00', 'failed'),
                 ('r3', '{a}', '2026-11-03 08:00:00', 'due');",
            a = a["id"].as_str().unwrap(), b = b["id"].as_str().unwrap()
        ))
        .unwrap();
        let (status, runs) = get(&pool, "/api/runs?limit=2").await;
        assert_eq!(status, StatusCode::OK, "{runs}");
        let got: Vec<(&str, &str)> = runs.as_array().unwrap().iter().map(|r| (r["id"].as_str().unwrap(), r["job_name"].as_str().unwrap())).collect();
        assert_eq!(got, vec![("r3", "Alpha"), ("r2", "Beta")]);
    }

    #[actix_web::test]
    async fn delete_job_cascades_runs() {
        let (_db, pool) = pool("jobs");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (_, job) = post(&pool, "/api/jobs", conversation_job("R", json!({"kind": "manual"}))).await;
        let id = job["id"].as_str().unwrap();
        post(&pool, &format!("/api/jobs/{id}/run"), json!({})).await;
        assert_eq!(delete(&pool, &format!("/api/jobs/{id}")).await.0, StatusCode::OK);
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
        assert_eq!(delete(&pool, &format!("/api/jobs/{id}")).await.0, StatusCode::NOT_FOUND);
    }
}
