//! Ideas per project: added in the app, by an agent (`ai-todo-idea`), or proposed by an agent
//! for approval. A research job (runner_api.rs) picks the next one and its findings come back here.

use std::collections::HashMap;

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;
use serde::Deserialize;
use todo_shared::{
    AttemptSpec, CreateIdeaRequest, CreateJobRequest, DeleteResponse, Idea, IdeaAttempt, JobAction, JobTrigger, LimitSetting,
    Priority, ResearchRequest, ResearchStart, UpdateIdeaRequest,
};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, not_found, server_error};
use crate::db::DbPool;
use crate::projects::project_exists;

const MAX_TITLE: usize = 200;
const MAX_NOTES: usize = 4000;
const MAX_FINDINGS: usize = 20_000;
const MAX_LIST: i64 = 500;
pub(crate) const STATUSES: [&str; 4] = ["new", "researching", "researched", "dropped"];
pub(crate) const IDEA_COLS: &str =
    "id, project_id, title, notes, status, starred, pending, findings, todo_id, run_id, source, created_at, updated_at";

pub(crate) enum IdeaError {
    BadRequest(String),
    NotFound(&'static str),
    Conflict(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for IdeaError {
    fn from(e: rusqlite::Error) -> Self {
        IdeaError::Db(e)
    }
}

fn respond(e: IdeaError) -> HttpResponse {
    match e {
        IdeaError::BadRequest(m) => bad_request(&m),
        IdeaError::NotFound(m) => not_found(m),
        IdeaError::Conflict(m) => crate::conversations::conflict(m),
        IdeaError::Db(e) => server_error(e),
    }
}

pub(crate) fn row_to_idea(row: &Row) -> rusqlite::Result<Idea> {
    Ok(Idea {
        id: row.get(0)?,
        project_id: row.get(1)?,
        title: row.get(2)?,
        notes: row.get(3)?,
        status: row.get(4)?,
        starred: row.get::<_, i64>(5)? != 0,
        pending: row.get::<_, i64>(6)? != 0,
        findings: row.get(7)?,
        todo_id: row.get(8)?,
        run_id: row.get(9)?,
        source: row.get(10)?,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
        attempts: Vec::new(),
    })
}

/// The research attempts of the ideas whose id passes `?1` (NULL: every idea), by idea id:
/// the runs of each idea's current group, oldest first, without those a retry replaced.
fn attempts_by_idea(conn: &Connection, idea_id: Option<&str>) -> rusqlite::Result<HashMap<String, Vec<IdeaAttempt>>> {
    let mut stmt = conn.prepare(
        "SELECT i.id, r.id, COALESCE(r.attempt_tool, 'claude'), r.attempt_model, r.state, r.result, r.conversation_id,
                f.findings, COALESCE(g.chosen_run_id = r.id, 0)
         FROM ideas i JOIN run_groups g ON g.id = i.group_id JOIN job_runs r ON r.group_id = g.id
         LEFT JOIN idea_findings f ON f.run_id = r.id
         WHERE (?1 IS NULL OR i.id = ?1) AND NOT EXISTS (SELECT 1 FROM job_runs x WHERE x.retry_of = r.id)
         ORDER BY r.created_at, r.rowid",
    )?;
    let rows = stmt.query_map(params![idea_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            IdeaAttempt {
                run_id: r.get(1)?,
                tool: r.get(2)?,
                model: r.get(3)?,
                state: r.get(4)?,
                result: r.get(5)?,
                conversation_id: r.get(6)?,
                findings: r.get(7)?,
                chosen: r.get::<_, i64>(8)? != 0,
            },
        ))
    })?;
    let mut out: HashMap<String, Vec<IdeaAttempt>> = HashMap::new();
    for row in rows {
        let (idea, attempt) = row?;
        out.entry(idea).or_default().push(attempt);
    }
    Ok(out)
}

pub(crate) fn load_idea(conn: &Connection, id: &str) -> rusqlite::Result<Option<Idea>> {
    let idea = conn.query_row(&format!("SELECT {IDEA_COLS} FROM ideas WHERE id = ?1"), params![id], row_to_idea).optional()?;
    let Some(mut idea) = idea else { return Ok(None) };
    idea.attempts = attempts_by_idea(conn, Some(id))?.remove(id).unwrap_or_default();
    Ok(Some(idea))
}

fn checked(text: &str, max: usize, what: &str, required: bool) -> Result<String, IdeaError> {
    let text = text.trim();
    let n = text.chars().count();
    if (required && n == 0) || n > max {
        return Err(IdeaError::BadRequest(format!("{what} must be {}-{max} characters", u8::from(required))));
    }
    Ok(text.to_string())
}

pub(crate) fn list_ideas_db(conn: &Connection, project_id: Option<&str>, status: Option<&str>, pending: bool) -> rusqlite::Result<Vec<Idea>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {IDEA_COLS} FROM ideas
         WHERE (?1 IS NULL OR project_id = ?1) AND (?2 IS NULL OR status = ?2) AND pending = ?3
         ORDER BY starred DESC,
                  CASE status WHEN 'new' THEN 0 WHEN 'researching' THEN 1 WHEN 'researched' THEN 2 ELSE 3 END,
                  created_at DESC, rowid DESC
         LIMIT {MAX_LIST}"
    ))?;
    let rows = stmt.query_map(params![project_id, status, pending], row_to_idea)?;
    let mut ideas: Vec<Idea> = rows.collect::<rusqlite::Result<_>>()?;
    let mut attempts = attempts_by_idea(conn, None)?;
    for idea in &mut ideas {
        idea.attempts = attempts.remove(&idea.id).unwrap_or_default();
    }
    Ok(ideas)
}

pub(crate) fn create_idea_db(conn: &Connection, req: &CreateIdeaRequest) -> Result<Idea, IdeaError> {
    let title = checked(&req.title, MAX_TITLE, "title", true)?;
    let notes = checked(req.notes.as_deref().unwrap_or(""), MAX_NOTES, "notes", false)?;
    let source = req.source.as_deref().unwrap_or("manual");
    if !matches!(source, "manual" | "agent") {
        return Err(IdeaError::BadRequest("source must be manual or agent".into()));
    }
    if !project_exists(conn, &req.project_id)? {
        return Err(IdeaError::NotFound("Project not found"));
    }
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO ideas (id, project_id, title, notes, pending, source) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, req.project_id, title, notes, req.pending.unwrap_or(false), source],
    )?;
    load_idea(conn, &id)?.ok_or(IdeaError::NotFound("Idea not found"))
}

pub(crate) fn update_idea_db(conn: &Connection, id: &str, req: &UpdateIdeaRequest) -> Result<Idea, IdeaError> {
    let idea = load_idea(conn, id)?.ok_or(IdeaError::NotFound("Idea not found"))?;
    let title = req.title.as_deref().map(|t| checked(t, MAX_TITLE, "title", true)).transpose()?;
    let notes = req.notes.as_deref().map(|t| checked(t, MAX_NOTES, "notes", false)).transpose()?;
    let findings = req.findings.as_deref().map(|t| checked(t, MAX_FINDINGS, "findings", false)).transpose()?;
    if let Some(status) = &req.status {
        if !STATUSES.contains(&status.as_str()) {
            return Err(IdeaError::BadRequest("status must be new, researching, researched or dropped".into()));
        }
    }
    // Findings mean the research is done, unless the same request says otherwise.
    let status = req.status.clone().or_else(|| findings.as_ref().filter(|f| !f.is_empty()).map(|_| "researched".to_string()));
    let tx = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    // An attempt of this idea's research group saves its own findings. The idea's own copy is
    // the chosen attempt's, else the first saved.
    let attempt = match (req.attempt.as_deref().map(str::trim), &findings) {
        (Some(run_id), Some(_)) if !run_id.is_empty() => tx
            .query_row(
                "SELECT r.id, g.chosen_run_id FROM job_runs r JOIN ideas i ON i.group_id = r.group_id
                 JOIN run_groups g ON g.id = r.group_id WHERE r.id = ?1 AND i.id = ?2",
                params![run_id, idea.id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)),
            )
            .optional()?,
        _ => None,
    };
    let findings = match (attempt, findings) {
        (Some((run_id, chosen)), Some(text)) => {
            tx.execute(
                "INSERT INTO idea_findings (run_id, idea_id, findings) VALUES (?1, ?2, ?3)
                 ON CONFLICT(run_id) DO UPDATE SET findings = excluded.findings, updated_at = datetime('now')",
                params![run_id, idea.id, text],
            )?;
            let first = idea.findings.as_deref().is_none_or(str::is_empty);
            (chosen.as_deref() == Some(run_id.as_str()) || first).then_some(text)
        }
        (_, findings) => findings,
    };
    tx.execute(
        "UPDATE ideas SET title = COALESCE(?2, title), notes = COALESCE(?3, notes), status = COALESCE(?4, status),
             starred = COALESCE(?5, starred), pending = COALESCE(?6, pending), findings = COALESCE(?7, findings),
             updated_at = datetime('now')
         WHERE id = ?1",
        params![idea.id, title, notes, status, req.starred, req.pending, findings],
    )?;
    tx.commit()?;
    load_idea(conn, id)?.ok_or(IdeaError::NotFound("Idea not found"))
}

/// "Shape an idea with an agent": the project's shape job runs once with the user's hint.
const SHAPE_PROMPT: &str = "Help me shape a new idea for the project {project}. My starting point: {note}\n\n\
Ask me short questions, one at a time, until the idea is clear. Then save it with:\n\
~/.ai-remote/bin/ai-todo-idea add \"<title>\" --notes \"<two or three sentences>\"\n\
and tell me it is saved and waits for my OK in the app.";
const MAX_HINT: usize = 1000;

#[derive(Debug, Deserialize)]
pub struct ShapeRequest {
    pub project_id: String,
    pub hint: String,
}

pub(crate) fn shape_db(conn: &Connection, req: &ShapeRequest) -> Result<todo_shared::JobRun, IdeaError> {
    let hint = checked(&req.hint, MAX_HINT, "hint", true)?;
    let name: String = conn
        .query_row("SELECT name FROM projects WHERE id = ?1", params![req.project_id], |r| r.get(0))
        .optional()?
        .ok_or(IdeaError::NotFound("Project not found"))?;
    let job_id = ensure_project_job(
        conn,
        &req.project_id,
        &format!("Shape an idea · {name}"),
        JobAction::Conversation {
            project_id: req.project_id.clone(),
            computer_id: None,
            tool: "claude".into(),
            folder: None,
            prompt: SHAPE_PROMPT.into(),
            model: None,
            priority: Priority::Urgent,
            limit: LimitSetting::Always,
        },
    )?;
    let run_id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO job_runs (id, job_id, due_at, state, note) VALUES (?1, ?2, datetime('now'), 'due', ?3)",
        params![run_id, job_id, hint],
    )?;
    crate::jobs::load_run(conn, &run_id)?.ok_or(IdeaError::NotFound("Run not found"))
}

/// The id of the project's manual job with this name, created on first use.
fn ensure_project_job(conn: &Connection, project_id: &str, job_name: &str, action: JobAction) -> Result<String, IdeaError> {
    let existing: Option<String> = conn
        .query_row(
            "SELECT id FROM jobs WHERE name = ?1 AND json_extract(action, '$.project_id') = ?2",
            params![job_name, project_id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = existing {
        return Ok(id);
    }
    let request = CreateJobRequest {
        name: job_name.to_string(),
        enabled: Some(true),
        trigger: JobTrigger::Manual,
        action,
        max_runs_per_day: Some(20),
    };
    match crate::jobs::create_job_db(conn, &request) {
        Ok(job) => Ok(job.id),
        Err(crate::jobs::JobError::Db(e)) => Err(IdeaError::Db(e)),
        Err(_) => Err(IdeaError::BadRequest("could not create the job".into())),
    }
}

/// The most agents one Research Now starts.
pub(crate) const MAX_ATTEMPTS: usize = 10;

fn tool_name(tool: &str) -> String {
    tool.chars().take(1).flat_map(char::to_uppercase).chain(tool.chars().skip(1)).collect()
}

/// Research this idea now with one or more agents: one run of the project's "Research now"
/// job (always run, no pushes) per agent, all in one group with one todo. The idea is reserved
/// as researching at once. No `attempts`: one Claude attempt, as older apps asked for.
pub(crate) fn research_now_db(conn: &Connection, id: &str, req: &ResearchRequest) -> Result<ResearchStart, IdeaError> {
    let default = [AttemptSpec { tool: "claude".into(), model: None }];
    let attempts: &[AttemptSpec] = req.attempts.as_deref().unwrap_or(&default);
    if attempts.is_empty() || attempts.len() > MAX_ATTEMPTS {
        return Err(IdeaError::BadRequest(format!("Choose 1 to {MAX_ATTEMPTS} agents")));
    }
    let mut specs: Vec<(String, Option<String>)> = Vec::new();
    for a in attempts {
        let tool = a.tool.trim();
        if !matches!(tool, "claude" | "codex" | "cursor") {
            return Err(IdeaError::BadRequest("tool must be claude, codex or cursor".into()));
        }
        let model = a.model.as_deref().map(str::trim).filter(|m| !m.is_empty());
        if model.is_some_and(|m| !crate::conversations::valid_model(m)) {
            return Err(IdeaError::BadRequest(crate::conversations::MODEL_RULE.into()));
        }
        specs.push((tool.to_string(), model.map(str::to_string)));
    }
    let tx = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    let computer_id = req.computer_id.as_deref().map(str::trim).filter(|c| !c.is_empty());
    if let Some(computer_id) = computer_id {
        let (name, tools): (String, Option<String>) = tx
            .query_row("SELECT name, tools FROM computers WHERE id = ?1", params![computer_id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?
            .ok_or(IdeaError::NotFound("Computer not found"))?;
        // A runner that reported its tools: only those. One that didn't: any.
        if let Some(installed) = tools.and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()) {
            if let Some((tool, _)) = specs.iter().find(|(t, _)| !installed.contains(t)) {
                return Err(IdeaError::BadRequest(format!("{} isn't installed on {name}", tool_name(tool))));
            }
        }
    }
    let idea = load_idea(&tx, id)?.ok_or(IdeaError::NotFound("Idea not found"))?;
    if idea.status != "new" || idea.pending {
        return Err(IdeaError::Conflict("Only a new, approved idea can be researched now"));
    }
    let (name, section): (String, String) =
        tx.query_row("SELECT name, section FROM projects WHERE id = ?1", params![idea.project_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
    let job_id = ensure_project_job(
        &tx,
        &idea.project_id,
        &format!("Research now · {name}"),
        JobAction::Research {
            project_id: idea.project_id.clone(),
            computer_id: None,
            tool: "claude".into(),
            folder: None,
            prompt: String::new(),
            priority: Priority::Background,
            limit: LimitSetting::Always,
        },
    )?;
    let group_id = Uuid::new_v4().to_string();
    let run_ids: Vec<String> = specs.iter().map(|_| Uuid::new_v4().to_string()).collect();
    for ((tool, model), run_id) in specs.iter().zip(&run_ids) {
        tx.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, note, group_id, attempt_tool, attempt_model)
             VALUES (?1, ?2, datetime('now'), 'due', ?3, ?4, ?5, ?6)",
            params![run_id, job_id, format!("idea:{id}"), group_id, tool, model],
        )?;
    }
    let todo_id = crate::scheduler::insert_scheduled_todo(
        &tx,
        &section,
        &format!("Research: {}", idea.title),
        Some(&idea.project_id),
        &job_id,
        &run_ids[0],
    )?;
    // Research Now is a background job: its todo doesn't push.
    tx.execute("INSERT OR IGNORE INTO push_muted_todos (todo_id) VALUES (?1)", params![todo_id])?;
    tx.execute(
        "INSERT INTO run_groups (id, idea_id, todo_id, computer_id) VALUES (?1, ?2, ?3, ?4)",
        params![group_id, id, todo_id, computer_id],
    )?;
    tx.execute(
        "UPDATE ideas SET status = 'researching', run_id = ?2, todo_id = ?3, group_id = ?4, updated_at = datetime('now') WHERE id = ?1",
        params![id, run_ids[0], todo_id, group_id],
    )?;
    let runs = run_ids
        .iter()
        .map(|r| crate::jobs::load_run(&tx, r)?.ok_or(IdeaError::NotFound("Run not found")))
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit()?;
    Ok(ResearchStart { group_id, todo_id, runs })
}

#[derive(Debug, Serialize)]
pub struct IdeaTodo {
    pub idea: Idea,
    pub todo_id: String,
}

/// A todo in the idea's project, titled after the idea; the idea links to it.
pub(crate) fn idea_to_todo_db(conn: &Connection, id: &str) -> Result<IdeaTodo, IdeaError> {
    let idea = load_idea(conn, id)?.ok_or(IdeaError::NotFound("Idea not found"))?;
    let section: String = conn
        .query_row("SELECT section FROM projects WHERE id = ?1", params![idea.project_id], |r| r.get(0))
        .optional()?
        .ok_or(IdeaError::NotFound("Project not found"))?;
    let todo_id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO todos (id, section, title, project_id) VALUES (?1, ?2, ?3, ?4)",
        params![todo_id, section, idea.title, idea.project_id],
    )?;
    conn.execute("UPDATE ideas SET todo_id = ?2, updated_at = datetime('now') WHERE id = ?1", params![id, todo_id])?;
    let idea = load_idea(conn, id)?.ok_or(IdeaError::NotFound("Idea not found"))?;
    Ok(IdeaTodo { idea, todo_id })
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

pub async fn list_ideas(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let conn = conn!(pool);
    let pending = query.get("pending").is_some_and(|p| p == "true");
    match list_ideas_db(&conn, query.get("project_id").map(String::as_str), query.get("status").map(String::as_str), pending) {
        Ok(ideas) => HttpResponse::Ok().json(ideas),
        Err(e) => server_error(e),
    }
}

pub async fn create_idea(pool: web::Data<DbPool>, body: web::Json<CreateIdeaRequest>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match create_idea_db(&conn, &body) {
        Ok(idea) => {
            broadcaster.send();
            HttpResponse::Created().json(idea)
        }
        Err(e) => respond(e),
    }
}

pub async fn update_idea(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateIdeaRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    match update_idea_db(&conn, &path, &body) {
        Ok(idea) => {
            broadcaster.send();
            HttpResponse::Ok().json(idea)
        }
        Err(e) => respond(e),
    }
}

pub async fn delete_idea(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match conn.execute("DELETE FROM ideas WHERE id = ?1", params![path.as_str()]) {
        Ok(0) => not_found("Idea not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: path.into_inner() })
        }
        Err(e) => server_error(e),
    }
}

pub async fn shape_idea(pool: web::Data<DbPool>, body: web::Json<ShapeRequest>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match shape_db(&conn, &body) {
        Ok(run) => {
            broadcaster.send();
            HttpResponse::Created().json(run)
        }
        Err(e) => respond(e),
    }
}

pub async fn research_idea(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Bytes,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let req: ResearchRequest = if body.iter().all(u8::is_ascii_whitespace) {
        ResearchRequest::default()
    } else {
        match serde_json::from_slice(&body) {
            Ok(r) => r,
            Err(e) => return bad_request(&format!("bad research request: {e}")),
        }
    };
    let conn = conn!(pool);
    match research_now_db(&conn, &path, &req) {
        Ok(start) => {
            broadcaster.send();
            // Older apps (no `attempts`) read the answer as one run.
            if req.attempts.is_none() {
                HttpResponse::Created().json(&start.runs[0])
            } else {
                HttpResponse::Created().json(start)
            }
        }
        Err(e) => respond(e),
    }
}

pub async fn idea_to_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match idea_to_todo_db(&conn, &path) {
        Ok(v) => {
            broadcaster.send();
            HttpResponse::Created().json(v)
        }
        Err(e) => respond(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};

    use crate::test_support::{delete, get, patch, pool, post, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch("INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'app', 'Si', '~/a');").unwrap();
    }

    fn titles(v: &Value) -> Vec<String> {
        v.as_array().unwrap().iter().map(|i| i["title"].as_str().unwrap().to_string()).collect()
    }

    async fn idea(pool: &crate::db::DbPool, title: &str) -> Value {
        let (status, v) = post(pool, "/api/ideas", json!({"project_id": "pa", "title": title})).await;
        assert_eq!(status, StatusCode::CREATED, "{v}");
        v
    }

    #[actix_web::test]
    async fn create_and_list_ideas_order() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let a = idea(&pool, "Old").await;
        let b = idea(&pool, "Starred").await;
        let c = idea(&pool, "Dropped").await;
        idea(&pool, "Newest").await;
        assert_eq!((&a["status"], &a["starred"], &a["source"]), (&json!("new"), &json!(false), &json!("manual")));
        patch(&pool, &format!("/api/ideas/{}", b["id"].as_str().unwrap()), json!({"starred": true})).await;
        patch(&pool, &format!("/api/ideas/{}", c["id"].as_str().unwrap()), json!({"status": "dropped"})).await;
        let (_, list) = get(&pool, "/api/ideas?project_id=pa").await;
        assert_eq!(titles(&list), vec!["Starred", "Newest", "Old", "Dropped"]);
        let (_, dropped) = get(&pool, "/api/ideas?project_id=pa&status=dropped").await;
        assert_eq!(titles(&dropped), vec!["Dropped"]);
    }

    #[actix_web::test]
    async fn create_idea_validation() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        assert_eq!(post(&pool, "/api/ideas", json!({"project_id": "pa", "title": " "})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "x".repeat(201)})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/ideas", json!({"project_id": "nope", "title": "x"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "x", "source": "robot"})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "x", "notes": "n".repeat(4001)})).await.0, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn list_hides_pending_by_default() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "Proposed", "pending": true, "source": "agent"})).await;
        idea(&pool, "Real").await;
        assert_eq!(titles(&get(&pool, "/api/ideas?project_id=pa").await.1), vec!["Real"]);
        assert_eq!(titles(&get(&pool, "/api/ideas?project_id=pa&pending=true").await.1), vec!["Proposed"]);
    }

    #[actix_web::test]
    async fn patch_approves_and_stars() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let (_, i) = post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "Proposed", "pending": true, "source": "agent"})).await;
        let (status, i) = patch(&pool, &format!("/api/ideas/{}", i["id"].as_str().unwrap()), json!({"pending": false, "starred": true})).await;
        assert_eq!(status, StatusCode::OK, "{i}");
        assert_eq!((&i["pending"], &i["starred"]), (&json!(false), &json!(true)));
        assert_eq!(patch(&pool, &format!("/api/ideas/{}", i["id"].as_str().unwrap()), json!({"status": "maybe"})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(patch(&pool, "/api/ideas/nope", json!({"starred": true})).await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn findings_sets_researched() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let i = idea(&pool, "Try Hermes").await;
        let (_, i) = patch(&pool, &format!("/api/ideas/{}", i["id"].as_str().unwrap()), json!({"findings": "It works."})).await;
        assert_eq!((&i["status"], &i["findings"]), (&json!("researched"), &json!("It works.")));
        assert_eq!(patch(&pool, &format!("/api/ideas/{}", i["id"].as_str().unwrap()), json!({"findings": "x".repeat(20001)})).await.0, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn findings_on_dropped_idea_saves() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let i = idea(&pool, "Dropped mid-research").await;
        let id = i["id"].as_str().unwrap();
        let (_, i) = patch(&pool, &format!("/api/ideas/{id}"), json!({"status": "dropped", "findings": "Late findings."})).await;
        assert_eq!((&i["status"], &i["findings"]), (&json!("dropped"), &json!("Late findings.")));
        let (_, i) = patch(&pool, &format!("/api/ideas/{id}"), json!({"findings": "Newer."})).await;
        assert_eq!(i["status"], "researched");
    }

    #[actix_web::test]
    async fn idea_to_todo_links() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Build the importer").await;
        let (status, v) = post(&pool, &format!("/api/ideas/{}/todo", i["id"].as_str().unwrap()), json!({})).await;
        assert_eq!(status, StatusCode::CREATED, "{v}");
        let todo_id = v["todo_id"].as_str().unwrap();
        assert_eq!(v["idea"]["todo_id"], json!(todo_id));
        assert_eq!(v["idea"]["status"], "new");
        let (title, section, project): (String, String, String) = conn
            .query_row("SELECT title, section, project_id FROM todos WHERE id = ?1", [todo_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap();
        assert_eq!((title.as_str(), section.as_str(), project.as_str()), ("Build the importer", "Si", "pa"));
    }

    #[actix_web::test]
    async fn delete_idea() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let i = idea(&pool, "Gone").await;
        let path = format!("/api/ideas/{}", i["id"].as_str().unwrap());
        assert_eq!(delete(&pool, &path).await.0, StatusCode::OK);
        assert_eq!(delete(&pool, &path).await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn shape_creates_job_once_and_runs_with_note() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let (status, run) = post(&pool, "/api/ideas/shape", json!({"project_id": "pa", "hint": "faster startup"})).await;
        assert_eq!(status, StatusCode::CREATED, "{run}");
        assert_eq!((&run["state"], &run["note"]), (&json!("due"), &json!("faster startup")));
        post(&pool, "/api/ideas/shape", json!({"project_id": "pa", "hint": "a second one"})).await;
        let (jobs, runs): (i64, i64) = conn
            .query_row("SELECT (SELECT COUNT(*) FROM jobs), (SELECT COUNT(*) FROM job_runs)", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert_eq!((jobs, runs), (1, 2));
        let (name, action): (String, String) = conn.query_row("SELECT name, action FROM jobs", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(name, "Shape an idea · app");
        let action: Value = serde_json::from_str(&action).unwrap();
        assert_eq!((&action["priority"], &action["limit"]["mode"], &action["tool"]), (&json!("urgent"), &json!("always"), &json!("claude")));
        assert!(action["prompt"].as_str().unwrap().contains("My starting point: {note}"));
    }

    #[actix_web::test]
    async fn shape_validation() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        assert_eq!(post(&pool, "/api/ideas/shape", json!({"project_id": "pa", "hint": " "})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/ideas/shape", json!({"project_id": "nope", "hint": "x"})).await.0, StatusCode::NOT_FOUND);
    }

    async fn research_now(pool: &crate::db::DbPool, id: &str) -> (StatusCode, Value) {
        post(pool, &format!("/api/ideas/{id}/research"), json!({})).await
    }

    fn idea_state(conn: &Connection, id: &str) -> (String, Option<String>) {
        conn.query_row("SELECT status, run_id FROM ideas WHERE id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap()
    }

    #[actix_web::test]
    async fn research_now_reserves_idea_and_runs() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Try Hermes").await;
        let id = i["id"].as_str().unwrap();
        let (status, run) = research_now(&pool, id).await;
        assert_eq!(status, StatusCode::CREATED, "{run}");
        assert_eq!((&run["state"], &run["note"]), (&json!("due"), &json!(format!("idea:{id}"))));
        assert_eq!(idea_state(&conn, id), ("researching".to_string(), Some(run["id"].as_str().unwrap().to_string())));
        let (name, action): (String, String) = conn.query_row("SELECT name, action FROM jobs", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!(name, "Research now · app");
        let action: Value = serde_json::from_str(&action).unwrap();
        assert_eq!((&action["kind"], &action["limit"]["mode"], &action["priority"]), (&json!("research"), &json!("always"), &json!("background")));
    }

    #[actix_web::test]
    async fn research_now_twice_conflicts() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let i = idea(&pool, "Once").await;
        assert_eq!(research_now(&pool, i["id"].as_str().unwrap()).await.0, StatusCode::CREATED);
        assert_eq!(research_now(&pool, i["id"].as_str().unwrap()).await.0, StatusCode::CONFLICT);
    }

    #[actix_web::test]
    async fn research_now_pending_or_researched_conflicts() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let (_, p) = post(&pool, "/api/ideas", json!({"project_id": "pa", "title": "Proposed", "pending": true, "source": "agent"})).await;
        assert_eq!(research_now(&pool, p["id"].as_str().unwrap()).await.0, StatusCode::CONFLICT);
        let r = idea(&pool, "Done already").await;
        patch(&pool, &format!("/api/ideas/{}", r["id"].as_str().unwrap()), json!({"findings": "x"})).await;
        assert_eq!(research_now(&pool, r["id"].as_str().unwrap()).await.0, StatusCode::CONFLICT);
        assert_eq!(research_now(&pool, "nope").await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn research_now_job_created_once() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        for t in ["One", "Two"] {
            let i = idea(&pool, t).await;
            research_now(&pool, i["id"].as_str().unwrap()).await;
        }
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM jobs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
    }

    async fn research_with(pool: &crate::db::DbPool, id: &str, body: Value) -> (StatusCode, Value) {
        post(pool, &format!("/api/ideas/{id}/research"), body).await
    }

    fn ideas_list(v: &Value, id: &str) -> Value {
        v.as_array().unwrap().iter().find(|i| i["id"] == id).cloned().unwrap()
    }

    #[actix_web::test]
    async fn research_with_agents_makes_one_group_and_todo() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Compare").await;
        let id = i["id"].as_str().unwrap();
        let todos_before: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        let (status, v) = research_with(
            &pool,
            id,
            json!({"computer_id": "mac", "attempts": [{"tool": "claude"}, {"tool": "codex", "model": "gpt-6.1-terra"}]}),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{v}");
        let runs = v["runs"].as_array().unwrap();
        assert_eq!(runs.len(), 2);
        assert!(runs.iter().all(|r| r["group_id"] == v["group_id"] && r["state"] == "due"));
        assert_eq!(runs.iter().map(|r| r["attempt_tool"].clone()).collect::<Vec<_>>(), vec![json!("claude"), json!("codex")]);
        assert_eq!(runs[1]["attempt_model"], "gpt-6.1-terra");
        let todos_after: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(todos_after, todos_before + 1);
        let (todo_id, group_id, status): (String, String, String) =
            conn.query_row("SELECT todo_id, group_id, status FROM ideas WHERE id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        assert_eq!((todo_id.as_str(), group_id.as_str(), status.as_str()), (v["todo_id"].as_str().unwrap(), v["group_id"].as_str().unwrap(), "researching"));
        let computer: Option<String> = conn.query_row("SELECT computer_id FROM run_groups WHERE id = ?1", [&group_id], |r| r.get(0)).unwrap();
        assert_eq!(computer.as_deref(), Some("mac"));
        let title: String = conn.query_row("SELECT title FROM todos WHERE id = ?1", [&todo_id], |r| r.get(0)).unwrap();
        assert_eq!(title, "Research: Compare");
        let (_, list) = get(&pool, "/api/ideas").await;
        let attempts = ideas_list(&list, id)["attempts"].clone();
        assert_eq!(attempts.as_array().unwrap().len(), 2, "{attempts}");
        assert_eq!((&attempts[0]["tool"], &attempts[0]["state"], &attempts[1]["model"]), (&json!("claude"), &json!("due"), &json!("gpt-6.1-terra")));
    }

    #[actix_web::test]
    async fn research_without_body_is_one_claude_attempt() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Old app").await;
        let id = i["id"].as_str().unwrap();
        let (status, run) = research_now(&pool, id).await;
        assert_eq!(status, StatusCode::CREATED, "{run}");
        assert_eq!((&run["attempt_tool"], &run["state"]), (&json!("claude"), &json!("due")));
        let computer: Option<String> =
            conn.query_row("SELECT g.computer_id FROM run_groups g JOIN ideas i ON i.group_id = g.id WHERE i.id = ?1", [id], |r| r.get(0)).unwrap();
        assert_eq!(computer, None);
    }

    #[actix_web::test]
    async fn research_agent_count_and_model_validation() {
        let (_db, pool) = pool("ideas");
        seed(&pool.get().unwrap());
        let i = idea(&pool, "Checked").await;
        let id = i["id"].as_str().unwrap();
        let claude = json!({"tool": "claude"});
        for (body, want) in [
            (json!({"attempts": []}), StatusCode::BAD_REQUEST),
            (json!({"attempts": vec![claude.clone(); 11]}), StatusCode::BAD_REQUEST),
            (json!({"attempts": [{"tool": "claude", "model": "a b"}]}), StatusCode::BAD_REQUEST),
            (json!({"attempts": [{"tool": "auto"}]}), StatusCode::BAD_REQUEST),
            (json!({"computer_id": "nope", "attempts": [claude.clone()]}), StatusCode::NOT_FOUND),
        ] {
            let (status, v) = research_with(&pool, id, body.clone()).await;
            assert_eq!(status, want, "{body} → {v}");
        }
        let (status, v) = research_with(&pool, id, json!({"attempts": [{"tool": "claude", "model": "opus[1m]"}]})).await;
        assert_eq!(status, StatusCode::CREATED, "{v}");
        assert_eq!(v["runs"][0]["attempt_model"], "opus[1m]");
    }

    #[actix_web::test]
    async fn research_rejects_tool_not_installed() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE computers SET tools = '[\"claude\"]' WHERE id = 'mac'", []).unwrap();
        let i = idea(&pool, "Installed").await;
        let id = i["id"].as_str().unwrap();
        let (status, v) = research_with(&pool, id, json!({"computer_id": "mac", "attempts": [{"tool": "codex"}]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(v.to_string().contains("Codex isn't installed on tsvetelins-macbook-pro"), "{v}");
        let (status, _) = research_with(&pool, id, json!({"computer_id": "spread", "attempts": [{"tool": "codex"}]})).await;
        assert_eq!(status, StatusCode::CREATED, "a computer that reported no tools takes any");
    }

    #[actix_web::test]
    async fn findings_per_attempt() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Two views").await;
        let id = i["id"].as_str().unwrap();
        let (_, v) = research_with(&pool, id, json!({"attempts": [{"tool": "claude"}, {"tool": "codex"}]})).await;
        let (r1, r2) = (v["runs"][0]["id"].as_str().unwrap(), v["runs"][1]["id"].as_str().unwrap());
        let (status, after) = patch(&pool, &format!("/api/ideas/{id}"), json!({"findings": "A", "attempt": r1})).await;
        assert_eq!(status, StatusCode::OK, "{after}");
        assert_eq!((&after["status"], &after["findings"]), (&json!("researched"), &json!("A")));
        let (_, after) = patch(&pool, &format!("/api/ideas/{id}"), json!({"findings": "B", "attempt": r2})).await;
        assert_eq!(after["findings"], "A", "the first saved findings stay the idea's until one is chosen");
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM idea_findings WHERE idea_id = ?1", [id], |r| r.get(0)).unwrap();
        assert_eq!(n, 2);
        let attempts = after["attempts"].as_array().unwrap();
        assert_eq!((&attempts[0]["findings"], &attempts[1]["findings"]), (&json!("A"), &json!("B")));
        assert!(attempts.iter().all(|a| a["chosen"] == false));
    }

    #[actix_web::test]
    async fn findings_with_unknown_attempt_saves_on_idea() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        let i = idea(&pool, "Scheduled").await;
        let id = i["id"].as_str().unwrap();
        let (status, after) = patch(&pool, &format!("/api/ideas/{id}"), json!({"findings": "Plain", "attempt": "conversation-folder"})).await;
        assert_eq!(status, StatusCode::OK, "{after}");
        assert_eq!((&after["status"], &after["findings"]), (&json!("researched"), &json!("Plain")));
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM idea_findings", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[actix_web::test]
    async fn deleting_project_cascades_ideas() {
        let (_db, pool) = pool("ideas");
        let conn = pool.get().unwrap();
        seed(&conn);
        idea(&pool, "Lost with its project").await;
        conn.execute("DELETE FROM projects WHERE id = 'pa'", []).unwrap();
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM ideas", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }
}
