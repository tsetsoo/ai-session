//! Ideas per project: added in the app, by an agent (`ai-todo-idea`), or proposed by an agent
//! for approval. A research job (runner_api.rs) picks the next one and its findings come back here.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;
use serde::Deserialize;
use todo_shared::{
    CreateIdeaRequest, CreateJobRequest, DeleteResponse, Idea, JobAction, JobTrigger, LimitSetting, Priority,
    UpdateIdeaRequest,
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
    })
}

pub(crate) fn load_idea(conn: &Connection, id: &str) -> rusqlite::Result<Option<Idea>> {
    conn.query_row(&format!("SELECT {IDEA_COLS} FROM ideas WHERE id = ?1"), params![id], row_to_idea).optional()
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
    rows.collect()
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
    conn.execute(
        "UPDATE ideas SET title = COALESCE(?2, title), notes = COALESCE(?3, notes), status = COALESCE(?4, status),
             starred = COALESCE(?5, starred), pending = COALESCE(?6, pending), findings = COALESCE(?7, findings),
             updated_at = datetime('now')
         WHERE id = ?1",
        params![idea.id, title, notes, status, req.starred, req.pending, findings],
    )?;
    load_idea(conn, id)?.ok_or(IdeaError::NotFound("Idea not found"))
}

/// "Shape an idea with an agent": the project's shape job runs once with the user's hint.
const SHAPE_PROMPT: &str = "Help me shape a new idea for the project {project}. My starting point: {note}\n\n\
Ask me short questions, one at a time, until the idea is clear. Then save it with:\n\
~/.ai-remote/bin/ai-todo-idea add \"<title>\" --notes \"<two or three sentences>\"\nand tell me it is saved.";
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
    let job_name = format!("Shape an idea · {name}");
    let existing: Option<String> = conn
        .query_row(
            "SELECT id FROM jobs WHERE name = ?1 AND json_extract(action, '$.project_id') = ?2",
            params![job_name, req.project_id],
            |r| r.get(0),
        )
        .optional()?;
    let job_id = match existing {
        Some(id) => id,
        None => {
            let request = CreateJobRequest {
                name: job_name,
                enabled: Some(true),
                trigger: JobTrigger::Manual,
                action: JobAction::Conversation {
                    project_id: req.project_id.clone(),
                    computer_id: None,
                    tool: "claude".into(),
                    folder: None,
                    prompt: SHAPE_PROMPT.into(),
                    priority: Priority::Urgent,
                    limit: LimitSetting::Always,
                },
                max_runs_per_day: Some(20),
            };
            match crate::jobs::create_job_db(conn, &request) {
                Ok(job) => job.id,
                Err(crate::jobs::JobError::Db(e)) => return Err(IdeaError::Db(e)),
                Err(_) => return Err(IdeaError::BadRequest("could not create the shape job".into())),
            }
        }
    };
    let run_id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO job_runs (id, job_id, due_at, state, note) VALUES (?1, ?2, datetime('now'), 'due', ?3)",
        params![run_id, job_id, hint],
    )?;
    crate::jobs::load_run(conn, &run_id)?.ok_or(IdeaError::NotFound("Run not found"))
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
