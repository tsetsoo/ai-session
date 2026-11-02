//! What the runners on the Macs ask the hub: which conversation runs are due here, claim one
//! (atomically), mark it waiting for usage headroom, start it (the hub creates the scheduled
//! todo and its conversation), and report how it ended.

use actix_web::{web, HttpResponse};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use todo_shared::{Job, JobAction, JobRun, LimitSetting, Priority, SchedulerSettings};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, conflict, insert_conversation, load_conversation, not_found, server_error};
use crate::db::DbPool;
use crate::jobs::{list_jobs_db, load_job, load_run, settings_db};
use crate::scheduler::{insert_scheduled_todo, local_date, render, sql_time};

#[derive(Debug, Serialize)]
pub struct DueRun {
    pub run: JobRun,
    pub job: Job,
    /// "Wait for headroom" runs of this job's tool started in the last 24 hours.
    pub wait_runs_24h: u32,
}

#[derive(Debug, Serialize)]
pub struct DueResponse {
    pub settings: SchedulerSettings,
    pub runs: Vec<DueRun>,
}

#[derive(Debug, Deserialize)]
pub struct ClaimRequest {
    pub computer_id: String,
    /// The runner has no usage reading: the claim is refused once 3 "wait for headroom" runs
    /// of the tool started in the last 24 hours (checked here, so every Mac shares the cap).
    #[serde(default)]
    pub no_reading: bool,
}

/// "Wait for headroom" runs without a usage reading allowed per tool per 24 hours.
const NO_READING_CAP: i64 = 3;

#[derive(Debug, Deserialize)]
pub struct WaitRequest {
    pub reason: String,
}

#[derive(Debug, Deserialize)]
pub struct StartRequest {
    /// `~` form.
    pub cwd: String,
    pub is_git: bool,
}

#[derive(Debug, Serialize)]
pub struct StartResponse {
    pub todo_id: String,
    pub tmux_name: String,
    /// Empty when the tool assigns it later (Codex).
    pub session_id: String,
    pub tool: String,
    pub prompt: String,
}

#[derive(Debug, Deserialize)]
pub struct FinishRequest {
    pub state: String,
    #[serde(default)]
    pub result: String,
}

const PREAMBLE_GIT: &str = "This is a scheduled conversation (\"{job}\", {date}). You work in your own git worktree at {folder}. \
     Do not push, merge, deploy or change anything outside this worktree; leave results here for review.";
const PREAMBLE_PLAIN: &str = "This is a scheduled conversation (\"{job}\", {date}). You work in {folder}, which is not a git repository: \
     do not modify files. Do not push, merge, deploy or change anything outside this worktree; leave results here for review.";

/// The computer a conversation action runs on: its own, else the project's section's.
fn resolved_computer(conn: &Connection, action: &JobAction) -> rusqlite::Result<Option<String>> {
    match action {
        action if action.conversation_parts().and_then(|p| p.computer_id).is_some() => {
            Ok(action.conversation_parts().and_then(|p| p.computer_id).map(str::to_string))
        }
        action if action.conversation_parts().is_some() => conn
            .query_row(
                "SELECT sc.computer_id FROM projects p JOIN section_computers sc ON sc.section = p.section WHERE p.id = ?1",
                params![action.conversation_parts().map(|p| p.project_id)],
                |r| r.get(0),
            )
            .optional(),
        _ => Ok(None),
    }
}

/// The job's previous started run still has a conversation at work (busy or waiting on the user).
fn previous_still_working(conn: &Connection, job_id: &str, run_id: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM job_runs r JOIN conversations c ON c.todo_id = r.todo_id
             WHERE r.job_id = ?1 AND r.id != ?2 AND r.todo_id IS NOT NULL AND c.status IN ('busy','waiting'))",
        params![job_id, run_id],
        |r| r.get(0),
    )
}

/// A run of this job is claimed but its conversation doesn't exist yet.
fn being_started(conn: &Connection, job_id: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM job_runs WHERE job_id = ?1 AND state = 'running' AND todo_id IS NULL)",
        params![job_id],
        |r| r.get(0),
    )
}

pub(crate) fn due_db(conn: &Connection, computer_id: &str) -> rusqlite::Result<DueResponse> {
    let settings = settings_db(conn)?;
    let jobs = list_jobs_db(conn)?;
    let mut runs = Vec::new();
    let mut stmt = conn.prepare(
        "SELECT id FROM job_runs WHERE state IN ('due','waiting') ORDER BY due_at, rowid",
    )?;
    let ids: Vec<String> = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    let mut seen_jobs = std::collections::HashSet::new();
    for id in ids {
        let Some(run) = load_run(conn, &id)? else { continue };
        let Some(job) = jobs.iter().find(|j| j.id == run.job_id) else { continue };
        // One run per job at a time, and none while another of its runs is being started.
        if !seen_jobs.insert(job.id.clone()) || being_started(conn, &job.id)? {
            continue;
        }
        let Some(parts) = job.action.conversation_parts() else { continue };
        let (tool, limit) = (parts.tool, &parts.limit);
        if resolved_computer(conn, &job.action)?.as_deref() != Some(computer_id) {
            continue;
        }
        let waits = matches!(limit, LimitSetting::Wait { .. });
        if waits && settings.pause_waiting {
            continue;
        }
        if previous_still_working(conn, &job.id, &run.id)? {
            continue;
        }
        let wait_runs_24h: i64 = conn.query_row(
            "SELECT COUNT(*) FROM job_runs WHERE limit_mode = 'wait' AND tool = ?1 AND started_at >= datetime('now', '-24 hours')",
            params![tool],
            |r| r.get(0),
        )?;
        let mut job = job.clone();
        job.last_run = None;
        runs.push(DueRun { run, job, wait_runs_24h: wait_runs_24h.max(0) as u32 });
    }
    Ok(DueResponse { settings, runs })
}

enum RunError {
    BadRequest(&'static str),
    NotFound(&'static str),
    Conflict(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for RunError {
    fn from(e: rusqlite::Error) -> Self {
        RunError::Db(e)
    }
}

fn respond(e: RunError) -> HttpResponse {
    match e {
        RunError::BadRequest(m) => bad_request(m),
        RunError::NotFound(m) => not_found(m),
        RunError::Conflict(m) => conflict(m),
        RunError::Db(e) => server_error(e),
    }
}

fn claim_db(conn: &Connection, run_id: &str, computer_id: &str, no_reading: bool) -> Result<DueRun, RunError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if no_reading {
        let run = load_run(&tx, run_id)?.ok_or(RunError::NotFound("Run not found"))?;
        if let Some(tool) = load_job(&tx, &run.job_id)?.and_then(|j| j.action.conversation_parts().map(|p| p.tool.to_string())) {
            let started: i64 = tx.query_row(
                "SELECT COUNT(*) FROM job_runs WHERE limit_mode = 'wait' AND tool = ?1 AND started_at >= datetime('now', '-24 hours')",
                params![tool],
                |r| r.get(0),
            )?;
            if started >= NO_READING_CAP {
                return Err(RunError::Conflict("No usage reading and 3 runs in 24 hours"));
            }
        }
    }
    let result = claim_in(&tx, run_id, computer_id)?;
    tx.commit()?;
    Ok(result)
}

fn claim_in(conn: &Connection, run_id: &str, computer_id: &str) -> Result<DueRun, RunError> {
    let changed = conn.execute(
        "UPDATE job_runs SET state = 'running', computer_id = ?2, updated_at = datetime('now')
         WHERE id = ?1 AND state IN ('due','waiting')",
        params![run_id, computer_id],
    )?;
    if changed == 0 {
        return match load_run(conn, run_id)? {
            Some(_) => Err(RunError::Conflict("Run is not due")),
            None => Err(RunError::NotFound("Run not found")),
        };
    }
    let run = load_run(conn, run_id)?.ok_or(RunError::NotFound("Run not found"))?;
    let mut job = load_job(conn, &run.job_id)?.ok_or(RunError::NotFound("Job not found"))?;
    job.last_run = None;
    Ok(DueRun { run, job, wait_runs_24h: 0 })
}

fn wait_db(conn: &Connection, run_id: &str, reason: &str) -> Result<(), RunError> {
    let changed = conn.execute(
        "UPDATE job_runs SET state = 'waiting', waiting_reason = ?2, updated_at = datetime('now')
         WHERE id = ?1 AND state IN ('due','waiting')",
        params![run_id, reason.trim()],
    )?;
    if changed == 0 {
        return match load_run(conn, run_id)? {
            Some(_) => Err(RunError::Conflict("Run is not due")),
            None => Err(RunError::NotFound("Run not found")),
        };
    }
    Ok(())
}

fn start_db(conn: &Connection, run_id: &str, req: &StartRequest) -> Result<StartResponse, RunError> {
    let cwd = req.cwd.trim();
    if cwd.is_empty() {
        return Err(RunError::BadRequest("cwd is required"));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let run = load_run(&tx, run_id)?.ok_or(RunError::NotFound("Run not found"))?;
    if run.state != "running" || run.todo_id.is_some() {
        return Err(RunError::Conflict("Run is not claimed, or already started"));
    }
    let computer_id = run.computer_id.clone().ok_or(RunError::Conflict("Run is not claimed"))?;
    let job = load_job(&tx, &run.job_id)?.ok_or(RunError::NotFound("Job not found"))?;
    let Some(parts) = job.action.conversation_parts() else {
        return Err(RunError::BadRequest("Not a conversation job"));
    };
    let (project_id, tool, prompt, priority, limit) = (parts.project_id, parts.tool, parts.prompt, &parts.priority, &parts.limit);
    let (project_name, section): (String, String) = tx
        .query_row("SELECT name, section FROM projects WHERE id = ?1", params![project_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()?
        .ok_or(RunError::NotFound("Project not found"))?;
    let date = local_date(Utc::now());
    let title = format!("{} · {date}", job.name);
    let todo_id = insert_scheduled_todo(&tx, &section, &title, Some(project_id), &job.id, &run.id)?;
    if *priority == Priority::Background {
        tx.execute("INSERT OR IGNORE INTO push_muted_todos (todo_id) VALUES (?1)", params![todo_id])?;
    }
    let session_id = (tool == "claude").then(|| Uuid::new_v4().to_string());
    if insert_conversation(&tx, &todo_id, &computer_id, cwd, tool, session_id.as_deref(), false, None, None)?.is_none() {
        return Err(RunError::Conflict("No free tmux session name"));
    }
    let conversation = load_conversation(&tx, &todo_id)?.ok_or(RunError::NotFound("Conversation not found"))?;
    let limit_mode = match limit {
        LimitSetting::Always => "always",
        LimitSetting::Wait { .. } => "wait",
    };
    tx.execute(
        "UPDATE job_runs SET todo_id = ?2, tool = ?3, limit_mode = ?4, started_at = ?5, updated_at = ?5 WHERE id = ?1",
        params![run.id, todo_id, tool, limit_mode, sql_time(Utc::now())],
    )?;
    let vars = [("job", job.name.as_str()), ("date", date.as_str()), ("folder", cwd), ("project", project_name.as_str())];
    let preamble = render(if req.is_git { PREAMBLE_GIT } else { PREAMBLE_PLAIN }, &vars);
    let prompt = format!("{preamble}\n\n{}", render(prompt, &vars));
    tx.commit()?;
    Ok(StartResponse {
        todo_id,
        tmux_name: conversation.tmux_name,
        session_id: conversation.session_id,
        tool: tool.to_string(),
        prompt,
    })
}

fn finish_db(conn: &Connection, run_id: &str, req: &FinishRequest) -> Result<(), RunError> {
    if !matches!(req.state.as_str(), "done" | "failed") {
        return Err(RunError::BadRequest("state must be done or failed"));
    }
    let changed = conn.execute(
        "UPDATE job_runs SET state = ?2, result = ?3, updated_at = datetime('now') WHERE id = ?1 AND state = 'running'",
        params![run_id, req.state, req.result.chars().take(500).collect::<String>()],
    )?;
    if changed == 0 {
        return match load_run(conn, run_id)? {
            Some(_) => Err(RunError::Conflict("Run is not running")),
            None => Err(RunError::NotFound("Run not found")),
        };
    }
    Ok(())
}

// --- Handlers ---------------------------------------------------------------------

pub async fn due(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let Some(computer_id) = query.get("computer_id").filter(|c| !c.trim().is_empty()) else {
        return bad_request("computer_id is required");
    };
    match pool.get().map_err(|e| e.to_string()).and_then(|c| due_db(&c, computer_id).map_err(|e| e.to_string())) {
        Ok(resp) => HttpResponse::Ok().json(resp),
        Err(e) => server_error(e),
    }
}

macro_rules! with_conn {
    ($pool:expr, $broadcaster:expr, $body:expr, $ok:expr) => {
        match $pool.get() {
            Ok(conn) => match $body(&conn) {
                Ok(value) => {
                    $broadcaster.send();
                    $ok(value)
                }
                Err(e) => respond(e),
            },
            Err(e) => server_error(e),
        }
    };
}

pub async fn claim(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<ClaimRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    with_conn!(pool, broadcaster, |c: &Connection| claim_db(c, &path, body.computer_id.trim(), body.no_reading), |v| HttpResponse::Ok().json(v))
}

pub async fn wait(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<WaitRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    with_conn!(pool, broadcaster, |c: &Connection| wait_db(c, &path, &body.reason), |_| HttpResponse::Ok()
        .json(serde_json::json!({"ok": true})))
}

pub async fn start(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<StartRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    with_conn!(pool, broadcaster, |c: &Connection| start_db(c, &path, &body), |v| HttpResponse::Ok().json(v))
}

pub async fn finish(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<FinishRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    with_conn!(pool, broadcaster, |c: &Connection| finish_db(c, &path, &body), |_| HttpResponse::Ok()
        .json(serde_json::json!({"ok": true})))
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::{params, Connection};
    use serde_json::{json, Value};

    use crate::test_support::{get, pool, post, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'app', 'Si', '~/a'), ('ps', 'spread', 'Sp', '~/s');",
        )
        .unwrap();
    }

    fn job(conn: &Connection, id: &str, project: &str, computer: Option<&str>, priority: &str, limit: &str) {
        let action = json!({"kind": "conversation", "project_id": project, "computer_id": computer, "tool": "claude",
            "folder": null, "prompt": "Research {project} in {folder}", "priority": priority,
            "limit": serde_json::from_str::<Value>(limit).unwrap()});
        conn.execute(
            "INSERT INTO jobs (id, name, trigger, action) VALUES (?1, ?2, '{\"kind\":\"manual\"}', ?3)",
            params![id, format!("Job {id}"), action.to_string()],
        )
        .unwrap();
    }

    fn run(conn: &Connection, id: &str, job: &str, state: &str) {
        conn.execute("INSERT INTO job_runs (id, job_id, due_at, state) VALUES (?1, ?2, datetime('now'), ?3)", params![id, job, state])
            .unwrap();
    }

    fn due_ids(v: &Value) -> Vec<String> {
        v["runs"].as_array().unwrap().iter().map(|r| r["run"]["id"].as_str().unwrap().to_string()).collect()
    }

    const ALWAYS: &str = r#"{"mode":"always"}"#;
    const WAIT: &str = r#"{"mode":"wait","five_hour":null,"weekly":null}"#;

    #[actix_web::test]
    async fn due_lists_runs_for_computer_only() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "jm", "pa", Some("mac"), "background", ALWAYS);
        job(&conn, "js", "pa", Some("spread"), "background", ALWAYS);
        run(&conn, "r-mac", "jm", "due");
        run(&conn, "r-spread", "js", "due");
        run(&conn, "r-done", "jm", "done");
        let (status, v) = get(&pool, "/api/runner/due?computer_id=mac").await;
        assert_eq!(status, StatusCode::OK, "{v}");
        assert_eq!(due_ids(&v), vec!["r-mac"]);
        assert_eq!(v["settings"], json!({"five_hour": 60, "weekly": 80, "pause_waiting": false}));
        assert_eq!(v["runs"][0]["job"]["id"], "jm");
    }

    #[actix_web::test]
    async fn due_resolves_section_computer() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "ps", None, "background", ALWAYS);
        run(&conn, "r", "j", "due");
        assert!(due_ids(&get(&pool, "/api/runner/due?computer_id=mac").await.1).is_empty());
        assert_eq!(due_ids(&get(&pool, "/api/runner/due?computer_id=spread").await.1), vec!["r"]);
    }

    #[actix_web::test]
    async fn due_skips_job_whose_last_conversation_is_busy() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "pa", Some("mac"), "background", ALWAYS);
        conn.execute_batch(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('t-prev', 'Si', 'prev', 'pa');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                 VALUES ('t-prev', 'mac', '~/a', 'claude', 'ai/claude/todo-prev', 's-prev', 'busy');
             INSERT INTO job_runs (id, job_id, due_at, state, todo_id, started_at)
                 VALUES ('r-prev', 'j', datetime('now', '-1 hour'), 'done', 't-prev', datetime('now', '-1 hour'));",
        )
        .unwrap();
        run(&conn, "r-next", "j", "due");
        assert!(due_ids(&get(&pool, "/api/runner/due?computer_id=mac").await.1).is_empty());
        conn.execute("UPDATE conversations SET status = 'idle' WHERE todo_id = 't-prev'", []).unwrap();
        assert_eq!(due_ids(&get(&pool, "/api/runner/due?computer_id=mac").await.1), vec!["r-next"], "an idle one doesn't block");
    }

    #[actix_web::test]
    async fn due_hides_wait_runs_when_paused() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "jw", "pa", Some("mac"), "background", WAIT);
        job(&conn, "ja", "pa", Some("mac"), "urgent", ALWAYS);
        run(&conn, "rw", "jw", "due");
        run(&conn, "ra", "ja", "waiting");
        conn.execute("UPDATE scheduler_settings SET pause_waiting = 1", []).unwrap();
        assert_eq!(due_ids(&get(&pool, "/api/runner/due?computer_id=mac").await.1), vec!["ra"]);
    }

    #[actix_web::test]
    async fn due_counts_wait_runs_24h() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "jw", "pa", Some("mac"), "background", WAIT);
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, tool, limit_mode, started_at) VALUES
                 ('a', 'jw', datetime('now'), 'done', 'claude', 'wait', datetime('now', '-2 hours')),
                 ('b', 'jw', datetime('now'), 'done', 'claude', 'wait', datetime('now', '-30 hours')),
                 ('c', 'jw', datetime('now'), 'done', 'codex', 'wait', datetime('now', '-1 hours')),
                 ('d', 'jw', datetime('now'), 'done', 'claude', 'always', datetime('now', '-1 hours'));",
        )
        .unwrap();
        run(&conn, "r", "jw", "due");
        let (_, v) = get(&pool, "/api/runner/due?computer_id=mac").await;
        assert_eq!(v["runs"][0]["wait_runs_24h"], json!(1));
    }

    #[actix_web::test]
    async fn claim_is_atomic() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "pa", Some("mac"), "background", ALWAYS);
        run(&conn, "r", "j", "due");
        let (first, body) = post(&pool, "/api/runs/r/claim", json!({"computer_id": "mac"})).await;
        let (second, _) = post(&pool, "/api/runs/r/claim", json!({"computer_id": "mac"})).await;
        assert_eq!((first, second), (StatusCode::OK, StatusCode::CONFLICT), "{body}");
        assert_eq!(body["run"]["state"], "running");
    }

    async fn started(pool: &crate::db::DbPool, conn: &Connection, priority: &str, is_git: bool) -> Value {
        job(conn, "j", "pa", Some("mac"), priority, WAIT);
        run(conn, "r", "j", "due");
        post(pool, "/api/runs/r/claim", json!({"computer_id": "mac"})).await;
        let (status, v) = post(pool, "/api/runs/r/start", json!({"cwd": "~/.ai-remote/worktrees/pa/r", "is_git": is_git})).await;
        assert_eq!(status, StatusCode::OK, "{v}");
        v
    }

    #[actix_web::test]
    async fn start_creates_marked_todo_and_conversation_with_cwd() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        let v = started(&pool, &conn, "background", true).await;
        let todo_id = v["todo_id"].as_str().unwrap();
        let (title, section, project, job, run): (String, String, String, String, String) = conn
            .query_row(
                "SELECT title, section, project_id, scheduled_job_id, scheduled_run_id FROM todos WHERE id = ?1",
                params![todo_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert!(title.starts_with("Job j · 20"), "{title}");
        assert_eq!((section.as_str(), project.as_str(), job.as_str(), run.as_str()), ("Si", "pa", "j", "r"));
        let (cwd, computer, tool): (String, String, String) = conn
            .query_row("SELECT cwd, computer_id, tool FROM conversations WHERE todo_id = ?1", params![todo_id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!((cwd.as_str(), computer.as_str(), tool.as_str()), ("~/.ai-remote/worktrees/pa/r", "mac", "claude"));
        assert_eq!(v["tool"], "claude");
        assert!(v["tmux_name"].as_str().unwrap().starts_with("ai/claude/todo-"));
        assert!(!v["session_id"].as_str().unwrap().is_empty());
        let (todo, limit_mode, started): (String, String, Option<String>) = conn
            .query_row("SELECT todo_id, limit_mode, started_at FROM job_runs WHERE id = 'r'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap();
        assert_eq!((todo.as_str(), limit_mode.as_str()), (todo_id, "wait"));
        assert!(started.is_some());
        let (status, _) = post(&pool, "/api/runs/r/start", json!({"cwd": "~/x", "is_git": true})).await;
        assert_eq!(status, StatusCode::CONFLICT, "a run starts once");
    }

    #[actix_web::test]
    async fn start_mutes_background_not_urgent() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        let v = started(&pool, &conn, "background", true).await;
        let muted = |todo: &str| -> i64 {
            conn.query_row("SELECT COUNT(*) FROM push_muted_todos WHERE todo_id = ?1", params![todo], |r| r.get(0)).unwrap()
        };
        assert_eq!(muted(v["todo_id"].as_str().unwrap()), 1);
        let (_db2, pool2) = crate::test_support::pool("runner");
        let conn2 = pool2.get().unwrap();
        seed(&conn2);
        let v2 = started(&pool2, &conn2, "urgent", true).await;
        let n: i64 = conn2.query_row("SELECT COUNT(*) FROM push_muted_todos WHERE todo_id = ?1", params![v2["todo_id"].as_str().unwrap()], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[actix_web::test]
    async fn start_prompt_has_preamble() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        let v = started(&pool, &conn, "background", true).await;
        let prompt = v["prompt"].as_str().unwrap();
        let date = &prompt[prompt.find("\"Job j\", ").unwrap() + 9..][..10];
        assert_eq!(
            prompt,
            format!(
                "This is a scheduled conversation (\"Job j\", {date}). You work in your own git worktree at ~/.ai-remote/worktrees/pa/r. \
                 Do not push, merge, deploy or change anything outside this worktree; leave results here for review.\n\n\
                 Research app in ~/.ai-remote/worktrees/pa/r"
            )
        );
        let (_db2, pool2) = crate::test_support::pool("runner");
        let conn2 = pool2.get().unwrap();
        seed(&conn2);
        let v2 = started(&pool2, &conn2, "background", false).await;
        assert!(v2["prompt"].as_str().unwrap().contains(
            "You work in ~/.ai-remote/worktrees/pa/r, which is not a git repository: do not modify files. Do not push"
        ), "{}", v2["prompt"]);
    }

    #[actix_web::test]
    async fn finish_records_result() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        started(&pool, &conn, "background", true).await;
        let (status, _) = post(&pool, "/api/runs/r/finish", json!({"state": "failed", "result": "tmux failed"})).await;
        assert_eq!(status, StatusCode::OK);
        let (state, result): (String, String) =
            conn.query_row("SELECT state, result FROM job_runs WHERE id = 'r'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((state.as_str(), result.as_str()), ("failed", "tmux failed"));
        assert_eq!(post(&pool, "/api/runs/r/finish", json!({"state": "running", "result": "x"})).await.0, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn due_returns_one_run_per_job_and_skips_running() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "pa", Some("mac"), "background", ALWAYS);
        job(&conn, "k", "pa", Some("mac"), "background", ALWAYS);
        run(&conn, "j1", "j", "due");
        run(&conn, "j2", "j", "due");
        run(&conn, "k-run", "k", "running");
        run(&conn, "k-due", "k", "due");
        assert_eq!(due_ids(&get(&pool, "/api/runner/due?computer_id=mac").await.1), vec!["j1"]);
    }

    #[actix_web::test]
    async fn claim_refuses_over_no_reading_cap() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "jw", "pa", Some("mac"), "background", WAIT);
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, tool, limit_mode, started_at) VALUES
                 ('a', 'jw', datetime('now'), 'done', 'claude', 'wait', datetime('now', '-1 hours')),
                 ('b', 'jw', datetime('now'), 'done', 'claude', 'wait', datetime('now', '-2 hours')),
                 ('c', 'jw', datetime('now'), 'done', 'claude', 'wait', datetime('now', '-3 hours'));",
        )
        .unwrap();
        run(&conn, "r", "jw", "due");
        let (status, _) = post(&pool, "/api/runs/r/claim", json!({"computer_id": "mac", "no_reading": true})).await;
        assert_eq!(status, StatusCode::CONFLICT, "3 wait runs without a reading in 24h");
        let (status, _) = post(&pool, "/api/runs/r/claim", json!({"computer_id": "mac"})).await;
        assert_eq!(status, StatusCode::OK, "with a reading the cap doesn't apply");
    }

    #[actix_web::test]
    async fn wait_then_claim() {
        let (_db, pool) = pool("runner");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "pa", Some("mac"), "background", WAIT);
        run(&conn, "r", "j", "due");
        let (status, _) = post(&pool, "/api/runs/r/wait", json!({"reason": "5h 72% > 60%"})).await;
        assert_eq!(status, StatusCode::OK);
        let (state, reason): (String, String) =
            conn.query_row("SELECT state, waiting_reason FROM job_runs WHERE id = 'r'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((state.as_str(), reason.as_str()), ("waiting", "5h 72% > 60%"));
        assert_eq!(post(&pool, "/api/runs/r/claim", json!({"computer_id": "mac"})).await.0, StatusCode::OK);
        assert_eq!(post(&pool, "/api/runs/r/wait", json!({"reason": "x"})).await.0, StatusCode::CONFLICT);
    }
}
