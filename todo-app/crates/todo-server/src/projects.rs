//! Projects: a folder on a section. The section's computer is the project's computer.
//! Todos belong to one project. A session matches the longest project folder on its computer.
//! Two projects may use the same folder, or one folder inside another.

use std::collections::{BTreeMap, BTreeSet};

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Row, Transaction, TransactionBehavior};
use todo_shared::{Computer, CreateProjectRequest, DeleteResponse, Project, ProjectSuggestion, Section, UpdateProjectRequest};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{
    bad_request, computer_at, conflict, not_found, server_error, valid_text, COMPUTER_COLS,
};
use crate::db::DbPool;
use crate::paths;

/// Project columns with their counts (0..=11), then the computer (12..=18).
const PROJECT_SELECT: &str = "SELECT p.id, p.name, p.section, p.folder, p.repo_url, p.digest_enabled, p.created_at, p.updated_at,
        (SELECT COUNT(*) FROM todos t WHERE t.project_id = p.id AND t.completed = 0),
        (SELECT COUNT(*) FROM sessions s WHERE s.project_id = p.id),
        (SELECT COUNT(*) FROM memories x WHERE x.project_id = p.id AND x.archived = 0),
        (SELECT MAX(s.last_activity) FROM sessions s WHERE s.project_id = p.id),
        m.id, m.name, m.hostname, m.port, m.username, m.created_at, m.updated_at
     FROM projects p
     JOIN section_computers sc ON sc.section = p.section
     JOIN computers m ON m.id = sc.computer_id";

/// How many example cwds a suggestion carries.
const EXAMPLE_CWDS: usize = 3;

fn parse_section(value: &str) -> rusqlite::Result<Section> {
    match value {
        "Sp" => Ok(Section::Sp),
        "I" => Ok(Section::I),
        "Si" => Ok(Section::Si),
        "P" => Ok(Section::P),
        _ => Err(rusqlite::Error::InvalidParameterName(value.into())),
    }
}

fn row_to_project(row: &Row) -> rusqlite::Result<Project> {
    let section: String = row.get(2)?;
    Ok(Project {
        id: row.get(0)?,
        name: row.get(1)?,
        section: parse_section(&section)?,
        folder: row.get(3)?,
        repo_url: row.get(4)?,
        digest_enabled: row.get::<_, i64>(5)? != 0,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
        open_todos: row.get(8)?,
        sessions: row.get(9)?,
        memories: row.get(10)?,
        last_activity: row.get(11)?,
        computer: computer_at(row, 12)?,
    })
}

pub(crate) fn load_project(conn: &Connection, id: &str) -> rusqlite::Result<Option<Project>> {
    conn.query_row(&format!("{PROJECT_SELECT} WHERE p.id = ?1"), params![id], row_to_project).optional()
}

pub(crate) fn project_exists(conn: &Connection, id: &str) -> rusqlite::Result<bool> {
    conn.prepare("SELECT 1 FROM projects WHERE id = ?1")?.exists(params![id])
}

fn list_projects_db(conn: &Connection) -> rusqlite::Result<Vec<Project>> {
    let mut stmt = conn.prepare(&format!("{PROJECT_SELECT} ORDER BY p.name COLLATE NOCASE, p.id"))?;
    let rows = stmt.query_map([], row_to_project)?;
    rows.collect()
}

/// `(id, section, folder)` of every project whose section uses this computer.
fn computer_projects(conn: &Connection, computer_id: &str) -> rusqlite::Result<Vec<(String, String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT p.id, p.section, p.folder FROM projects p
         JOIN section_computers sc ON sc.section = p.section
         WHERE sc.computer_id = ?1",
    )?;
    let rows = stmt.query_map(params![computer_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    rows.collect()
}

fn computer_username(conn: &Connection, computer_id: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row("SELECT username FROM computers WHERE id = ?1", params![computer_id], |r| r.get(0)).optional()
}

/// The project on `computer_id` whose folder is the longest segment prefix of `cwd`.
/// Equal folders use section order `Sp`, `I`, `Si`, `P`.
pub(crate) fn project_for(conn: &Connection, computer_id: &str, cwd: &str) -> rusqlite::Result<Option<String>> {
    let username = computer_username(conn, computer_id)?.unwrap_or_default();
    let projects = computer_projects(conn, computer_id)?;
    Ok(choose_project(&paths::normalize(cwd, &username), &projects, None, None))
}

fn section_rank(section: &str) -> usize {
    match section {
        "Sp" => 0,
        "I" => 1,
        "Si" => 2,
        "P" => 3,
        _ => 4,
    }
}

fn folder_len(folder: &str) -> usize {
    folder.split('/').filter(|part| !part.is_empty()).count()
}

/// Longest matching folder. A todo's project wins when it is one of those matches.
/// Otherwise the current project stays if it still matches. Otherwise section order.
fn choose_project(
    cwd: &str,
    projects: &[(String, String, String)],
    current: Option<&str>,
    todo_project: Option<&str>,
) -> Option<String> {
    let mut matches: Vec<&(String, String, String)> = projects
        .iter()
        .filter(|(_, _, folder)| paths::is_within(cwd, folder))
        .collect();
    let longest = matches.iter().map(|(_, _, folder)| folder_len(folder)).max()?;
    matches.retain(|(_, _, folder)| folder_len(folder) == longest);
    if let Some(todo) = todo_project {
        if matches.iter().any(|(id, _, _)| id == todo) {
            return Some(todo.to_string());
        }
    }
    if let Some(current) = current {
        if matches.iter().any(|(id, _, _)| id == current) {
            return Some(current.to_string());
        }
    }
    matches.sort_by_key(|(_, section, _)| section_rank(section));
    matches.first().map(|(id, _, _)| id.clone())
}

fn session_todo_project(conn: &Connection, tool: &str, session_id: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT todos.project_id FROM conversations
         JOIN todos ON todos.id = conversations.todo_id
         WHERE conversations.tool = ?1 AND conversations.session_id = ?2",
        params![tool, session_id],
        |r| r.get::<_, Option<String>>(0),
    )
    .optional()
    .map(Option::flatten)
}

/// Set a session's project and override flag. When the project changes, the session's
/// memories move with it.
pub(crate) fn assign_session_project(
    conn: &Connection,
    tool: &str,
    session_id: &str,
    project_id: Option<&str>,
    project_override: bool,
) -> rusqlite::Result<()> {
    let current: Option<Option<String>> = conn
        .query_row(
            "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get(0),
        )
        .optional()?;
    let Some(current) = current else {
        return Ok(());
    };
    conn.execute(
        "UPDATE sessions SET project_id = ?1, project_override = ?2 WHERE tool = ?3 AND session_id = ?4",
        params![project_id, project_override, tool, session_id],
    )?;
    if current.as_deref() != project_id {
        conn.execute(
            "UPDATE memories SET project_id = ?1 WHERE tool = ?2 AND session_id = ?3",
            params![project_id, tool, session_id],
        )?;
    }
    Ok(())
}

/// Re-match every session on a computer that has no override, and move the memories of
/// sessions whose project changed. Overrides that point at a project that is gone (or
/// not on this computer) are cleared first, so those sessions are matched again too.
pub(crate) fn rematch_sessions(conn: &Connection, computer_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE sessions SET project_override = 0
         WHERE computer_id = ?1 AND project_override = 1 AND project_id IS NOT NULL
           AND project_id NOT IN (
               SELECT p.id FROM projects p
               JOIN section_computers sc ON sc.section = p.section
               WHERE sc.computer_id = ?1
           )",
        params![computer_id],
    )?;
    let username = computer_username(conn, computer_id)?.unwrap_or_default();
    let projects = computer_projects(conn, computer_id)?;
    let sessions: Vec<(String, String, String, Option<String>)> = {
        let mut stmt = conn.prepare(
            "SELECT tool, session_id, cwd, project_id FROM sessions WHERE computer_id = ?1 AND project_override = 0",
        )?;
        let rows = stmt.query_map(params![computer_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    for (tool, session_id, cwd, current) in sessions {
        let todo_project = session_todo_project(conn, &tool, &session_id)?;
        let best = choose_project(
            &paths::normalize(&cwd, &username),
            &projects,
            current.as_deref(),
            todo_project.as_deref(),
        );
        if best.as_deref() != current.as_deref() {
            assign_session_project(conn, &tool, &session_id, best.as_deref(), false)?;
        }
    }
    Ok(())
}

#[derive(Debug)]
pub(crate) enum ProjectError {
    BadRequest(&'static str),
    NotFound(&'static str),
    Conflict(String),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for ProjectError {
    fn from(e: rusqlite::Error) -> Self {
        ProjectError::Db(e)
    }
}

fn project_error_response(e: ProjectError) -> HttpResponse {
    match e {
        ProjectError::BadRequest(msg) => bad_request(msg),
        ProjectError::NotFound(msg) => not_found(msg),
        ProjectError::Conflict(msg) => conflict(msg),
        ProjectError::Db(e) => server_error(e),
    }
}

/// A trimmed, normalized folder, or the 400 message.
fn checked_folder(folder: &str, username: &str) -> Result<String, ProjectError> {
    let folder = folder.trim();
    if folder.is_empty() {
        return Err(ProjectError::BadRequest("folder is required"));
    }
    if !(folder.starts_with('~') || folder.starts_with('/')) {
        return Err(ProjectError::BadRequest("folder must start with ~ or /"));
    }
    // Folders are compared segment by segment without resolving them, so `..` would let a
    // project slip inside another one (and never match a conversation's cwd).
    if folder.split('/').any(|s| s.trim() == "..") {
        return Err(ProjectError::BadRequest("folder must not contain .."));
    }
    Ok(paths::normalize(folder, username))
}

fn checked_name(name: &str) -> Result<&str, ProjectError> {
    if valid_text(name) {
        Ok(name.trim())
    } else {
        Err(ProjectError::BadRequest("name is required"))
    }
}

fn clean_url(url: Option<&str>) -> Option<&str> {
    url.map(str::trim).filter(|u| !u.is_empty())
}

fn folder_taken(conn: &Connection, section: &str, folder: &str, except: Option<&str>) -> rusqlite::Result<bool> {
    conn.prepare("SELECT 1 FROM projects WHERE section = ?1 AND folder = ?2 AND id IS NOT ?3")?
        .exists(params![section, folder, except])
}

pub(crate) fn create_project_db(conn: &Connection, req: &CreateProjectRequest) -> Result<Project, ProjectError> {
    let name = checked_name(&req.name)?;
    let section = req.section.as_str();
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let computer_id: String = tx
        .query_row("SELECT computer_id FROM section_computers WHERE section = ?1", params![section], |r| r.get(0))
        .optional()?
        .ok_or_else(|| ProjectError::Conflict(format!("Section {section} has no computer")))?;
    let username = computer_username(&tx, &computer_id)?.ok_or(ProjectError::NotFound("Computer not found"))?;
    let folder = checked_folder(&req.folder, &username)?;
    if folder_taken(&tx, section, &folder, None)? {
        return Err(ProjectError::Conflict(format!("Section {section} already has a project at {folder}")));
    }
    let id = Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO projects (id, name, section, folder, repo_url, digest_enabled) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, name, section, folder, clean_url(req.repo_url.as_deref()), req.digest_enabled.unwrap_or(true)],
    )?;
    rematch_sessions(&tx, &computer_id)?;
    let project = load_project(&tx, &id)?.ok_or(ProjectError::NotFound("Project not found"))?;
    tx.commit()?;
    Ok(project)
}

pub(crate) fn update_project_db(conn: &Connection, id: &str, req: &UpdateProjectRequest) -> Result<Project, ProjectError> {
    let name = req.name.as_deref().map(checked_name).transpose()?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let existing = load_project(&tx, id)?.ok_or(ProjectError::NotFound("Project not found"))?;
    let section = existing.section.as_str();
    let folder = match req.folder.as_deref() {
        Some(folder) => {
            let folder = checked_folder(folder, &existing.computer.username)?;
            if folder_taken(&tx, section, &folder, Some(id))? {
                return Err(ProjectError::Conflict(format!("Section {section} already has a project at {folder}")));
            }
            Some(folder)
        }
        None => None,
    };
    tx.execute(
        "UPDATE projects SET
            name = COALESCE(?1, name),
            folder = COALESCE(?2, folder),
            repo_url = CASE WHEN ?3 THEN ?4 ELSE repo_url END,
            digest_enabled = COALESCE(?5, digest_enabled),
            updated_at = datetime('now')
         WHERE id = ?6",
        params![
            name,
            folder,
            req.repo_url.is_some(),
            clean_url(req.repo_url.as_ref().and_then(|u| u.as_deref())),
            req.digest_enabled,
            id
        ],
    )?;
    if folder.as_deref().is_some_and(|f| f != existing.folder) {
        rematch_sessions(&tx, &existing.computer.id)?;
    }
    let project = load_project(&tx, id)?.ok_or(ProjectError::NotFound("Project not found"))?;
    tx.commit()?;
    Ok(project)
}

/// A project that still has todos is refused. Sessions are matched again (overrides pointing
/// at it are cleared), and memories follow their session or become project-less.
pub(crate) fn delete_project_db(conn: &Connection, id: &str) -> Result<(), ProjectError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let computer_id: Option<String> = tx
        .query_row(
            "SELECT sc.computer_id FROM projects p
             LEFT JOIN section_computers sc ON sc.section = p.section
             WHERE p.id = ?1",
            params![id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or(ProjectError::NotFound("Project not found"))?;
    let todos: i64 = tx.query_row("SELECT COUNT(*) FROM todos WHERE project_id = ?1", params![id], |r| r.get(0))?;
    if todos > 0 {
        return Err(ProjectError::Conflict("Project still has todos".into()));
    }
    tx.execute("UPDATE sessions SET project_override = 0 WHERE project_id = ?1", params![id])?;
    // Foreign keys set todos, sessions and memories that point at it to NULL.
    tx.execute("DELETE FROM projects WHERE id = ?1", params![id])?;
    if let Some(computer_id) = computer_id.as_deref() {
        rematch_sessions(&tx, computer_id)?;
    }
    tx.commit()?;
    Ok(())
}

/// A suggestion being collected: the distinct sessions, latest activity and cwds.
#[derive(Default)]
struct SuggestionAcc {
    sessions: BTreeSet<(String, String)>,
    last_activity: Option<String>,
    cwds: BTreeMap<String, usize>,
}

/// Suggested projects from the cwds of sessions and todo conversations, grouped by
/// computer and suggestion folder. A folder that is already a project on that computer
/// is dropped. A folder inside or around another project is still suggested.
pub(crate) fn suggestions_db(conn: &Connection) -> rusqlite::Result<Vec<ProjectSuggestion>> {
    let computers: BTreeMap<String, Computer> = {
        let mut stmt = conn.prepare(&format!("SELECT {COMPUTER_COLS} FROM computers"))?;
        let rows = stmt.query_map([], |r| computer_at(r, 0))?;
        rows.map(|c| c.map(|c| (c.id.clone(), c))).collect::<rusqlite::Result<_>>()?
    };
    // (computer, tool, session, cwd, last_activity, repo_root, repo_url)
    type Known = (String, String, String, String, Option<String>, Option<String>, Option<String>);
    let known: Vec<Known> = {
        let mut stmt = conn.prepare(
            "SELECT computer_id, tool, session_id, cwd, last_activity, repo_root, repo_url FROM sessions
             UNION ALL
             SELECT c.computer_id, c.tool, c.session_id, c.cwd, NULL, NULL, NULL FROM conversations c
             WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.tool = c.tool AND s.session_id = c.session_id)",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };

    let mut groups: BTreeMap<(String, String), SuggestionAcc> = BTreeMap::new();
    // (computer, repo_root) → (last_activity, repo_url), newest wins.
    let mut repo_urls: BTreeMap<(String, String), (Option<String>, String)> = BTreeMap::new();
    for (computer_id, tool, session_id, cwd, last_activity, repo_root, repo_url) in known {
        let Some(computer) = computers.get(&computer_id) else { continue };
        let cwd = paths::normalize(&cwd, &computer.username);
        let folder = paths::suggestion_folder(&cwd);
        let acc = groups.entry((computer_id.clone(), folder)).or_default();
        acc.sessions.insert((tool, session_id));
        if last_activity > acc.last_activity {
            acc.last_activity.clone_from(&last_activity);
        }
        *acc.cwds.entry(cwd).or_default() += 1;
        if let (Some(root), Some(url)) = (repo_root, repo_url) {
            let key = (computer_id, paths::normalize(&root, &computer.username));
            let newer = repo_urls.get(&key).is_none_or(|(seen, _)| last_activity >= *seen);
            if newer {
                repo_urls.insert(key, (last_activity, url));
            }
        }
    }

    let mut project_folders: BTreeMap<String, Vec<String>> = BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT sc.computer_id, p.folder FROM projects p
             JOIN section_computers sc ON sc.section = p.section",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        for row in rows {
            let (computer_id, folder) = row?;
            project_folders.entry(computer_id).or_default().push(folder);
        }
    }

    let mut suggestions: Vec<ProjectSuggestion> = groups
        .into_iter()
        .filter(|((computer_id, folder), _)| {
            project_folders.get(computer_id).is_none_or(|folders| {
                folders.iter().all(|existing| existing != folder)
            })
        })
        .map(|((computer_id, folder), acc)| {
            let mut cwds: Vec<(String, usize)> = acc.cwds.into_iter().collect();
            cwds.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            let name = folder.rsplit('/').find(|s| !s.is_empty()).unwrap_or(&folder).to_string();
            ProjectSuggestion {
                computer: computers[&computer_id].clone(),
                repo_url: repo_urls.get(&(computer_id, folder.clone())).map(|(_, url)| url.clone()),
                name,
                folder,
                sessions: i64::try_from(acc.sessions.len()).unwrap_or(i64::MAX),
                last_activity: acc.last_activity,
                example_cwds: cwds.into_iter().take(EXAMPLE_CWDS).map(|(cwd, _)| cwd).collect(),
            }
        })
        .collect();
    suggestions.sort_by(|a, b| {
        b.sessions
            .cmp(&a.sessions)
            .then_with(|| b.last_activity.cmp(&a.last_activity))
            .then_with(|| a.computer.name.cmp(&b.computer.name))
            .then_with(|| a.folder.cmp(&b.folder))
    });
    Ok(suggestions)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn list_projects(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match list_projects_db(&conn) {
        Ok(projects) => HttpResponse::Ok().json(projects),
        Err(e) => server_error(e),
    }
}

pub async fn get_project(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match load_project(&conn, &path.into_inner()) {
        Ok(Some(p)) => HttpResponse::Ok().json(p),
        Ok(None) => not_found("Project not found"),
        Err(e) => server_error(e),
    }
}

pub async fn create_project(
    pool: web::Data<DbPool>,
    body: web::Json<CreateProjectRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match create_project_db(&conn, &body) {
        Ok(p) => {
            broadcaster.send();
            HttpResponse::Created().json(p)
        }
        Err(e) => project_error_response(e),
    }
}

pub async fn update_project(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateProjectRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match update_project_db(&conn, &path.into_inner(), &body) {
        Ok(p) => {
            broadcaster.send();
            HttpResponse::Ok().json(p)
        }
        Err(e) => project_error_response(e),
    }
}

pub async fn delete_project(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match delete_project_db(&conn, &id) {
        Ok(()) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: id })
        }
        Err(e) => project_error_response(e),
    }
}

pub async fn project_suggestions(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match suggestions_db(&conn) {
        Ok(s) => HttpResponse::Ok().json(s),
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use serde_json::{json, Value};

    use crate::test_support::{delete, get, insert_session, patch, pool, post, seed_computers, session_project};

    async fn create(pool: &crate::db::DbPool, section: &str, folder: &str) -> (StatusCode, Value) {
        let name = folder.rsplit('/').find(|s| !s.is_empty()).unwrap();
        post(pool, "/api/projects", json!({"name": name, "section": section, "folder": folder})).await
    }

    async fn create_ok(pool: &crate::db::DbPool, computer: &str, folder: &str) -> String {
        let (status, body) = create(pool, computer, folder).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_string()
    }

    #[actix_web::test]
    async fn create_project_on_a_section_stores_no_computer_id() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let (status, body) = post(
            &pool,
            "/api/projects",
            json!({"name": "sigma", "section": "Si", "folder": "~/programming/sigma-revenue"}),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        assert_eq!(body["section"], "Si");
        assert_eq!(body["computer"]["id"], "mac");
        let columns: Vec<String> = conn
            .prepare("SELECT name FROM pragma_table_info('projects')")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(!columns.iter().any(|name| name == "computer_id"));
    }

    #[actix_web::test]
    async fn nested_project_folders_are_allowed() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        create_ok(&pool, "Si", "~/programming").await;
        let (status, body) = create(&pool, "Si", "~/programming/sigma-revenue").await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
    }

    #[actix_web::test]
    async fn create_project_on_a_section_with_no_computer_is_409() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        conn.execute("DELETE FROM section_computers WHERE section = 'P'", []).unwrap();
        let (status, body) = create(&pool, "P", "~/programming").await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        assert_eq!(body["error"], "Section P has no computer");
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM projects", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[actix_web::test]
    async fn same_folder_on_two_sections_keeps_the_current_session_project() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let si = create_ok(&pool, "Si", "~/programming/sigma-revenue").await;
        let p = create_ok(&pool, "P", "~/programming/sigma-revenue").await;
        insert_session(&conn, "mac", "claude", "s1", "~/programming/sigma-revenue/src");
        conn.execute("UPDATE sessions SET project_id = ?1 WHERE session_id = 's1'", [&p]).unwrap();
        crate::projects::rematch_sessions(&conn, "mac").unwrap();
        assert_eq!(session_project(&conn, "claude", "s1").as_deref(), Some(p.as_str()));

        insert_session(&conn, "mac", "claude", "s-todo", "~/programming/sigma-revenue/src");
        conn.execute("UPDATE sessions SET project_id = ?1 WHERE session_id = 's-todo'", [&si]).unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('t-p', 'P', 'on P', ?1)",
            [&p],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
             VALUES ('t-p', 'mac', '~/programming/sigma-revenue/src', 'claude', 'ai/claude/todo-t-p', 's-todo')",
            [],
        )
        .unwrap();
        crate::projects::rematch_sessions(&conn, "mac").unwrap();
        assert_eq!(session_project(&conn, "claude", "s-todo").as_deref(), Some(p.as_str()));
        assert_eq!(session_project(&conn, "claude", "s1").as_deref(), Some(p.as_str()));
    }

    #[actix_web::test]
    async fn create_returns_project_with_normalized_folder() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        let (status, body) = post(
            &pool,
            "/api/projects",
            json!({"name": " todo-app ", "section": "Si", "folder": "/Users/me/programming//todo-app/",
                   "repo_url": "git@github.com:tsetsoo/todo-app.git"}),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        assert_eq!(body["name"], "todo-app");
        assert_eq!(body["folder"], "~/programming/todo-app");
        assert_eq!(body["computer"]["id"], "mac");
        assert_eq!(body["section"], "Si");
        assert_eq!(body["repo_url"], "git@github.com:tsetsoo/todo-app.git");
        assert_eq!(body["digest_enabled"], true);
        assert_eq!((body["open_todos"].as_i64(), body["sessions"].as_i64(), body["memories"].as_i64()), (Some(0), Some(0), Some(0)));
        assert!(body["last_activity"].is_null());

        let id = body["id"].as_str().unwrap();
        let (status, one) = get(&pool, &format!("/api/projects/{id}")).await;
        assert_eq!((status, &one["folder"]), (StatusCode::OK, &json!("~/programming/todo-app")));
        assert_eq!(get(&pool, "/api/projects/missing").await.0, StatusCode::NOT_FOUND);

        // Validation.
        for bad in [
            json!({"name": " ", "section": "Si", "folder": "~/x"}),
            json!({"name": "x", "section": "Si", "folder": " "}),
            json!({"name": "x", "section": "Si", "folder": "relative/path"}),
        ] {
            assert_eq!(post(&pool, "/api/projects", bad.clone()).await.0, StatusCode::BAD_REQUEST, "{bad}");
        }
        let (status, body) = post(&pool, "/api/projects", json!({"name": "x", "section": "nope", "folder": "~/x"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    }

    #[actix_web::test]
    async fn create_rejects_duplicate_and_nested() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        create_ok(&pool, "Si", "~/a").await;

        let (status, body) = create(&pool, "Si", "~/a").await;
        assert_eq!(status, StatusCode::CONFLICT, "duplicate: {body}");
        let (status, body) = create(&pool, "Si", "/Users/me/a/").await;
        assert_eq!(status, StatusCode::CONFLICT, "same folder, other spelling: {body}");
        let (status, body) = create(&pool, "Si", "~/a/b").await;
        assert_eq!(status, StatusCode::CREATED, "inside: {body}");
        create_ok(&pool, "Si", "~/ab").await;

        create_ok(&pool, "Si", "~/c/d").await;
        let (status, body) = create(&pool, "Si", "~/c").await;
        assert_eq!(status, StatusCode::CREATED, "contains: {body}");

        // The same folder on another section is its own project.
        create_ok(&pool, "Sp", "~/a").await;
        create_ok(&pool, "Sp", "~/c").await;
    }

    #[actix_web::test]
    async fn folder_with_dotdot_is_400() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        create_ok(&pool, "Si", "~/programming/todo-app").await;
        for folder in ["~/x/../programming/todo-app/crates", "~/programming/todo-app/../other", "/Users/me/.."] {
            let (status, body) = create(&pool, "Si", folder).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{folder}: {body}");
        }
    }

    #[actix_web::test]
    async fn patch_folder_into_nesting_is_409() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        create_ok(&pool, "Si", "~/a").await;
        let b = create_ok(&pool, "Si", "~/b").await;
        create_ok(&pool, "Sp", "~/b/x").await;

        let (status, body) = patch(&pool, &format!("/api/projects/{b}"), json!({"folder": "~/a"})).await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        // A folder inside another project on the same section is its own project.
        let (status, body) = patch(&pool, &format!("/api/projects/{b}"), json!({"folder": "~/a/inner"})).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        // Moving within its own old folder, or renaming, is fine; another computer's project doesn't count.
        let (status, body) = patch(&pool, &format!("/api/projects/{b}"), json!({"folder": "~/b/x"})).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["folder"], "~/b/x");
        let (status, body) = patch(
            &pool,
            &format!("/api/projects/{b}"),
            json!({"name": "renamed", "digest_enabled": false, "repo_url": "https://example.com/r.git"}),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!((&body["name"], &body["digest_enabled"], &body["folder"]), (&json!("renamed"), &json!(false), &json!("~/b/x")));
        assert_eq!(body["repo_url"], "https://example.com/r.git");
        let (_, body) = patch(&pool, &format!("/api/projects/{b}"), json!({"repo_url": null})).await;
        assert!(body["repo_url"].is_null(), "null clears the repo URL: {body}");
        assert_eq!(body["name"], "renamed", "absent fields are unchanged");
        assert_eq!(patch(&pool, "/api/projects/missing", json!({"name": "x"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(patch(&pool, &format!("/api/projects/{b}"), json!({"name": ""})).await.0, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn create_and_patch_rematch_sessions() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        insert_session(&conn, "mac", "claude", "s-ax", "~/a/x/.claude/worktrees/w");
        insert_session(&conn, "mac", "claude", "s-b", "~/b");
        insert_session(&conn, "mac", "codex", "s-ab", "~/ab");
        insert_session(&conn, "spread", "claude", "s-other", "~/a/x");
        insert_session(&conn, "mac", "claude", "s-pinned", "~/a/y");
        conn.execute("UPDATE sessions SET project_override = 1 WHERE session_id = 's-pinned'", []).unwrap();
        // A memory of a session moves with it.
        conn.execute(
            "INSERT INTO memories (id, tool, session_id, kind, text, text_key) VALUES ('m1', 'claude', 's-ax', 'gotcha', 'G', 'g')",
            [],
        )
        .unwrap();

        let a = create_ok(&pool, "Si", "~/a").await;
        assert_eq!(session_project(&conn, "claude", "s-ax").as_deref(), Some(a.as_str()));
        assert_eq!(session_project(&conn, "claude", "s-b"), None);
        assert_eq!(session_project(&conn, "codex", "s-ab"), None, "~/ab is not inside ~/a");
        assert_eq!(session_project(&conn, "claude", "s-other"), None, "other computers are ignored");
        assert_eq!(session_project(&conn, "claude", "s-pinned"), None, "an override is never replaced");
        let memory_project: Option<String> =
            conn.query_row("SELECT project_id FROM memories WHERE id = 'm1'", [], |r| r.get(0)).unwrap();
        assert_eq!(memory_project.as_deref(), Some(a.as_str()));

        // A longer folder wins.
        let ax = create_ok(&pool, "Si", "~/c").await;
        let (status, _) = patch(&pool, &format!("/api/projects/{ax}"), json!({"folder": "~/b"})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(session_project(&conn, "claude", "s-b").as_deref(), Some(ax.as_str()));

        // Moving ~/a to ~/b2 un-matches s-ax and its memory.
        patch(&pool, &format!("/api/projects/{a}"), json!({"folder": "~/b2"})).await;
        assert_eq!(session_project(&conn, "claude", "s-ax"), None);
        let memory_project: Option<String> =
            conn.query_row("SELECT project_id FROM memories WHERE id = 'm1'", [], |r| r.get(0)).unwrap();
        assert_eq!(memory_project, None);
        assert_eq!(session_project(&conn, "claude", "s-pinned"), None);
    }

    #[actix_web::test]
    async fn delete_project_keeps_memories_and_clears_todos() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let outer = create_ok(&pool, "Si", "~/work").await;
        // Not nested: delete outer first, then create inner to check re-matching to the remaining one.
        let other = create_ok(&pool, "Si", "~/other").await;
        insert_session(&conn, "mac", "claude", "s1", "~/work/app");
        insert_session(&conn, "mac", "claude", "s2", "~/elsewhere");
        conn.execute("UPDATE sessions SET project_id = ?1, project_override = 1 WHERE session_id = 's2'", [&outer]).unwrap();
        conn.execute("UPDATE sessions SET project_id = ?1 WHERE session_id = 's1'", [&outer]).unwrap();
        conn.execute_batch(&format!(
            "INSERT INTO memories (id, project_id, tool, session_id, kind, text, text_key)
                 VALUES ('m-s1', '{outer}', 'claude', 's1', 'decision', 'D', 'd');
             INSERT INTO memories (id, project_id, kind, text, text_key, source)
                 VALUES ('m-manual', '{outer}', 'gotcha', 'Manual', 'manual', 'manual');"
        ))
        .unwrap();

        let (status, body) = delete(&pool, &format!("/api/projects/{outer}")).await;
        assert_eq!((status, &body), (StatusCode::OK, &json!({"deleted": outer})));
        assert_eq!(delete(&pool, &format!("/api/projects/{outer}")).await.0, StatusCode::NOT_FOUND);

        let memories: i64 = conn.query_row("SELECT COUNT(*) FROM memories", [], |r| r.get(0)).unwrap();
        assert_eq!(memories, 2, "nothing is deleted");
        let override_cleared: i64 =
            conn.query_row("SELECT project_override FROM sessions WHERE session_id = 's2'", [], |r| r.get(0)).unwrap();
        assert_eq!(override_cleared, 0, "an override pointing at the deleted project is cleared");

        // With a project at the old session's folder, the session and its memory follow it.
        let (status, _) = patch(&pool, &format!("/api/projects/{other}"), json!({"folder": "~/work/app"})).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(session_project(&conn, "claude", "s1").as_deref(), Some(other.as_str()));
        let m: Option<String> = conn.query_row("SELECT project_id FROM memories WHERE id = 'm-s1'", [], |r| r.get(0)).unwrap();
        assert_eq!(m.as_deref(), Some(other.as_str()));
        let manual: Option<String> =
            conn.query_row("SELECT project_id FROM memories WHERE id = 'm-manual'", [], |r| r.get(0)).unwrap();
        assert_eq!(manual, None, "a manual memory of the deleted project becomes project-less");
    }

    #[actix_web::test]
    async fn delete_project_with_todos_is_409() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = create_ok(&pool, "Si", "~/work").await;
        conn.execute(
            "INSERT INTO todos (id, section, title, project_id) VALUES ('t1', 'Si', 'x', ?1)",
            [&project],
        )
        .unwrap();

        let (status, _) = delete(&pool, &format!("/api/projects/{project}")).await;
        assert_eq!(status, StatusCode::CONFLICT);
        let still: i64 = conn.query_row("SELECT COUNT(*) FROM projects WHERE id = ?1", [&project], |r| r.get(0)).unwrap();
        assert_eq!(still, 1, "the project stays");
        let todo_project: String = conn.query_row("SELECT project_id FROM todos WHERE id = 't1'", [], |r| r.get(0)).unwrap();
        assert_eq!(todo_project, project);
    }

    #[actix_web::test]
    async fn deleting_a_project_rematches_to_the_remaining_ones() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let inner = create_ok(&pool, "Si", "~/work/app").await;
        insert_session(&conn, "mac", "claude", "s1", "~/work/app/sub");
        crate::projects::rematch_sessions(&conn, "mac").unwrap();
        assert_eq!(session_project(&conn, "claude", "s1").as_deref(), Some(inner.as_str()));
        delete(&pool, &format!("/api/projects/{inner}")).await;
        assert_eq!(session_project(&conn, "claude", "s1"), None);
        let outer = create_ok(&pool, "Si", "~/work").await;
        assert_eq!(session_project(&conn, "claude", "s1").as_deref(), Some(outer.as_str()));
    }

    #[actix_web::test]
    async fn clear_section_with_projects_is_409() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let id = create_ok(&pool, "Si", "~/x").await;

        let (status, body) = delete(&pool, "/api/sections/Si/computer").await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        assert!(body["error"].as_str().unwrap().contains("project"), "{body}");
        let mapping: i64 = conn
            .query_row("SELECT COUNT(*) FROM section_computers WHERE section = 'Si'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mapping, 1, "the computer stays on the section");
        let (list_status, list) = get(&pool, "/api/projects").await;
        assert_eq!(list_status, StatusCode::OK, "{list}");
        let listed = list.as_array().unwrap().iter().any(|p| p["id"].as_str() == Some(id.as_str()));
        assert!(listed, "the project stays on the list: {list}");
    }

    #[actix_web::test]
    async fn delete_computer_with_project_is_409() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        conn.execute("INSERT INTO computers (id, name, hostname, username) VALUES ('spare', 'spare', 'h', 'me')", []).unwrap();
        conn.execute("UPDATE section_computers SET computer_id = 'spare' WHERE section = 'P'", []).unwrap();
        let id = create_ok(&pool, "P", "~/x").await;
        let (status, body) = delete(&pool, "/api/computers/spare").await;
        assert_eq!(status, StatusCode::CONFLICT, "{body}");
        assert!(body["error"].as_str().unwrap().contains("project"), "{body}");
        conn.execute("UPDATE section_computers SET computer_id = 'mac' WHERE section = 'P'", []).unwrap();
        delete(&pool, &format!("/api/projects/{id}")).await;
        // Without a project, its sessions (and their days) go with it; memories stay.
        insert_session(&conn, "spare", "claude", "s1", "~/x");
        conn.execute("INSERT INTO session_days (tool, session_id, day) VALUES ('claude', 's1', '2026-10-16')", []).unwrap();
        conn.execute(
            "INSERT INTO memories (id, computer_id, tool, session_id, kind, text, text_key)
             VALUES ('m1', 'spare', 'claude', 's1', 'done', 'Done', 'done')",
            [],
        )
        .unwrap();
        assert_eq!(delete(&pool, "/api/computers/spare").await.0, StatusCode::OK);
        let left: (i64, i64) = conn
            .query_row("SELECT (SELECT COUNT(*) FROM sessions), (SELECT COUNT(*) FROM session_days)", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(left, (0, 0));
        let computer: Option<String> = conn.query_row("SELECT computer_id FROM memories WHERE id = 'm1'", [], |r| r.get(0)).unwrap();
        assert_eq!(computer, None);
    }

    #[actix_web::test]
    async fn suggestions_group_and_exclude() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        insert_session(&conn, "mac", "claude", "s1", "~/programming/sigma-revenue/x");
        insert_session(&conn, "mac", "claude", "s2", "~/programming/sigma-revenue/y/.claude/worktrees/z");
        insert_session(&conn, "spread", "claude", "s3", "/Users/me/Spread/Repository");
        conn.execute_batch(
            "UPDATE sessions SET last_activity = '2026-10-16T09:12:03Z' WHERE session_id = 's1';
             UPDATE sessions SET last_activity = '2026-10-15T09:00:00Z' WHERE session_id = 's2';
             UPDATE sessions SET repo_root = '~/programming/sigma-revenue', repo_url = 'git@example.com:s/r.git'
                 WHERE session_id = 's2';
             INSERT INTO todos (id, section, title) VALUES ('t1', 'Sp', 'linked');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
                 VALUES ('t1', 'mac', '~/programming/sigma-revenue/x', 'claude', 'ai/claude/todo-t1', 's1');",
        )
        .unwrap();

        let (status, body) = get(&pool, "/api/projects/suggestions").await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let list = body.as_array().unwrap();
        assert_eq!(list.len(), 2, "{body}");
        assert_eq!(list[0]["folder"], "~/programming/sigma-revenue");
        assert_eq!(list[0]["name"], "sigma-revenue");
        assert_eq!(list[0]["computer"]["id"], "mac");
        assert_eq!(list[0]["sessions"], 2, "a conversation that is also a session counts once");
        assert_eq!(list[0]["last_activity"], "2026-10-16T09:12:03Z");
        assert_eq!(list[0]["repo_url"], "git@example.com:s/r.git");
        let examples: Vec<&str> = list[0]["example_cwds"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        assert!(examples.contains(&"~/programming/sigma-revenue/x"), "{examples:?}");
        assert_eq!(list[1]["folder"], "~/Spread/Repository", "absolute home paths are normalized");
        assert_eq!(list[1]["sessions"], 1);
        assert!(list[1]["repo_url"].is_null());

        create_ok(&pool, "Sp", "~/Spread/Repository").await;
        let (_, body) = get(&pool, "/api/projects/suggestions").await;
        assert_eq!(body.as_array().unwrap().len(), 1, "{body}");

        // A parent folder can be its own project, so it stays suggested beside the child.
        insert_session(&conn, "mac", "codex", "s4", "~/programming");
        let (_, body) = get(&pool, "/api/projects/suggestions").await;
        assert_eq!(body.as_array().unwrap().len(), 2, "{body}");
        create_ok(&pool, "Si", "~/programming/sigma-revenue").await;
        let (_, body) = get(&pool, "/api/projects/suggestions").await;
        let left = body.as_array().unwrap();
        assert_eq!(left.len(), 1, "{body}");
        assert_eq!(left[0]["folder"], "~/programming");
    }

    #[actix_web::test]
    async fn todo_project_id_create_patch_clear_filter() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        let project = create_ok(&pool, "Si", "~/a").await;

        let (status, body) = post(&pool, "/api/todos", json!({"section": "P", "title": "x", "project_id": "nope"})).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
        assert_eq!(body["error"], "Project not found");

        let other = create_ok(&pool, "P", "~/b").await;
        let (status, with) = post(&pool, "/api/todos", json!({"section": "Si", "title": "with", "project_id": project})).await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!((&with["project_id"], &with["section"]), (&json!(project), &json!("Si")));
        let (status, elsewhere) = post(&pool, "/api/todos", json!({"title": "elsewhere", "project_id": other})).await;
        assert_eq!(status, StatusCode::CREATED, "{elsewhere}");
        assert_eq!(elsewhere["section"], "P");

        let (status, body) = get(&pool, &format!("/api/todos?project_id={project}")).await;
        assert_eq!(status, StatusCode::OK);
        let ids: Vec<&str> = body.as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec![with["id"].as_str().unwrap()]);
        let (_, body) = get(&pool, &format!("/api/todos?section=P&project_id={project}")).await;
        assert_eq!(body, json!([]));
        let (_, all) = get(&pool, "/api/todos").await;
        assert_eq!(all.as_array().unwrap().len(), 2);

        let wid = elsewhere["id"].as_str().unwrap();
        let (status, body) = patch(&pool, &format!("/api/todos/{wid}"), json!({"project_id": project})).await;
        assert_eq!((status, &body["project_id"], &body["section"]), (StatusCode::OK, &json!(project), &json!("Si")));
        let (_, body) = patch(&pool, &format!("/api/todos/{wid}"), json!({"title": "renamed"})).await;
        assert_eq!(body["project_id"], json!(project), "absent leaves it");
        let (status, body) = patch(&pool, &format!("/api/todos/{wid}"), json!({"project_id": null})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(body["error"], "project_id is required");
        assert_eq!(patch(&pool, &format!("/api/todos/{wid}"), json!({"project_id": "nope"})).await.0, StatusCode::NOT_FOUND);
        assert_eq!(patch(&pool, "/api/todos/missing", json!({"project_id": null})).await.0, StatusCode::NOT_FOUND);

        // due_date: null clears it too (the documented behaviour).
        patch(&pool, &format!("/api/todos/{wid}"), json!({"due_date": "2026-10-20"})).await;
        let (_, body) = patch(&pool, &format!("/api/todos/{wid}"), json!({"due_date": null})).await;
        assert!(body["due_date"].is_null(), "{body}");
    }

    #[actix_web::test]
    async fn project_counts() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let id = create_ok(&pool, "Si", "~/a").await;
        insert_session(&conn, "mac", "claude", "s1", "~/a");
        insert_session(&conn, "mac", "claude", "s2", "~/a/b");
        crate::projects::rematch_sessions(&conn, "mac").unwrap();
        conn.execute_batch(&format!(
            "UPDATE sessions SET last_activity = '2026-10-16T09:12:03Z' WHERE session_id = 's1';
             UPDATE sessions SET last_activity = '2026-10-15T08:00:00Z' WHERE session_id = 's2';
             INSERT INTO todos (id, section, title, project_id, completed) VALUES
                 ('t1', 'P', 'open', '{id}', 0), ('t2', 'P', 'open 2', '{id}', 0), ('t3', 'P', 'done', '{id}', 1),
                 ('t4', 'P', 'elsewhere', NULL, 0);
             INSERT INTO memories (id, project_id, kind, text, text_key, archived) VALUES
                 ('m1', '{id}', 'gotcha', 'a', 'a', 0), ('m2', '{id}', 'gotcha', 'b', 'b', 1);"
        ))
        .unwrap();
        let (_, list) = get(&pool, "/api/projects").await;
        let p = &list.as_array().unwrap()[0];
        assert_eq!(
            (&p["open_todos"], &p["sessions"], &p["memories"], &p["last_activity"]),
            (&json!(2), &json!(2), &json!(1), &json!("2026-10-16T09:12:03Z"))
        );
    }

    #[actix_web::test]
    async fn project_for_matches_any_spelling_on_its_computer() {
        let (_db, pool) = pool("proj");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let id = create_ok(&pool, "Si", "~/x").await;
        for cwd in ["~/x", "/Users/me/x/", "~//x/sub", "~/x/.claude/worktrees/w"] {
            assert_eq!(crate::projects::project_for(&conn, "mac", cwd).unwrap().as_deref(), Some(id.as_str()), "{cwd}");
        }
        assert_eq!(crate::projects::project_for(&conn, "mac", "~/xy").unwrap(), None);
        assert_eq!(crate::projects::project_for(&conn, "spread", "~/x").unwrap(), None);
        assert_eq!(crate::projects::project_for(&conn, "missing", "~/x").unwrap(), None);
    }

    #[actix_web::test]
    async fn projects_are_listed_by_name() {
        let (_db, pool) = pool("proj");
        seed_computers(&pool.get().unwrap());
        create_ok(&pool, "Si", "~/zeta").await;
        create_ok(&pool, "Si", "~/Alpha").await;
        create_ok(&pool, "Sp", "~/beta").await;
        let (_, list) = get(&pool, "/api/projects").await;
        let names: Vec<&str> = list.as_array().unwrap().iter().map(|p| p["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["Alpha", "beta", "zeta"]);
    }
}
