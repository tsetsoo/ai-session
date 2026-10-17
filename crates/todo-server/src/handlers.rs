use actix_web::{web, HttpRequest, HttpResponse};
use rusqlite::params;
use todo_shared::{CreateTodoRequest, DeleteResponse, Importance, Section, SectionCount, UpdateTodoRequest};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::models::row_to_todo;
use crate::projects::project_exists;

pub(crate) const SELECT_COLS: &str = "id, section, title, completed, importance, due_date, daily_date, carried_from, created_at, updated_at, completed_at, project_id, \
    (SELECT status FROM conversations WHERE conversations.todo_id = todos.id) AS conversation_status";

pub async fn get_sections(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let mut counts: Vec<SectionCount> = Vec::new();
    let active_filter = "AND NOT (completed = 1 AND completed_at IS NOT NULL AND completed_at < datetime('now', '-1 day'))";
    for section in Section::all() {
        let s = section.as_str();
        let total: usize = conn
            .query_row(&format!("SELECT COUNT(*) FROM todos WHERE section = ?1 {active_filter}"), params![s], |row| row.get(0))
            .unwrap_or(0);
        let completed: usize = conn
            .query_row(&format!("SELECT COUNT(*) FROM todos WHERE section = ?1 AND completed = 1 {active_filter}"), params![s], |row| row.get(0))
            .unwrap_or(0);
        counts.push(SectionCount { section: *section, total, completed });
    }

    HttpResponse::Ok().json(counts)
}

#[derive(serde::Deserialize)]
pub struct TodosQuery {
    pub section: Option<String>,
    pub sort: Option<String>,
    pub show: Option<String>,
    pub project_id: Option<String>,
}

pub async fn list_todos(pool: web::Data<DbPool>, query: web::Query<TodosQuery>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let order = match query.sort.as_deref() {
        Some("importance") => {
            "CASE importance WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END ASC, created_at DESC"
        }
        Some("due_date") => "due_date IS NULL, due_date ASC, created_at DESC",
        Some("importance_date") => {
            "CASE importance WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END ASC, due_date IS NULL, due_date ASC, created_at DESC"
        }
        _ => "created_at DESC",
    };

    let show_filter = match query.show.as_deref() {
        Some("archived") => "AND completed = 1 AND completed_at IS NOT NULL AND completed_at < datetime('now', '-1 day')",
        Some("all") => "",
        _ => "AND NOT (completed = 1 AND completed_at IS NOT NULL AND completed_at < datetime('now', '-1 day'))",
    };

    if query.section.as_deref().is_some_and(|s| Section::parse(s).is_none()) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid section"}));
    }
    let sql = format!(
        "SELECT {SELECT_COLS} FROM todos WHERE (?1 IS NULL OR section = ?1) AND (?2 IS NULL OR project_id = ?2) {show_filter} ORDER BY {order}"
    );
    let mut stmt = conn.prepare(&sql).unwrap();
    let todos = stmt
        .query_map(params![query.section, query.project_id], row_to_todo)
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect::<Vec<_>>();

    HttpResponse::Ok().json(todos)
}

pub async fn get_todo(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let result = conn.query_row(&sql, params![id], row_to_todo);

    match result {
        Ok(todo) => HttpResponse::Ok().json(todo),
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}))
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

/// Insert a todo and return its new id. Shared by `POST /api/todos` and
/// `POST /api/todos/from-conversation`, so both create todos the same way.
pub(crate) fn insert_todo(
    conn: &rusqlite::Connection,
    section: Section,
    title: &str,
    importance: Option<Importance>,
    due_date: Option<&str>,
    project_id: Option<&str>,
) -> rusqlite::Result<String> {
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO todos (id, section, title, importance, due_date, project_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, section.as_str(), title, importance.unwrap_or_default().as_str(), due_date, project_id],
    )?;
    Ok(id)
}

fn project_not_found() -> HttpResponse {
    HttpResponse::NotFound().json(serde_json::json!({"error": "Project not found"}))
}

pub async fn create_todo(pool: web::Data<DbPool>, body: web::Json<CreateTodoRequest>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let title = body.title.trim();
    if title.is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Title cannot be empty"}));
    }

    if let Some(project_id) = body.project_id.as_deref() {
        match project_exists(&conn, project_id) {
            Ok(true) => {}
            Ok(false) => return project_not_found(),
            Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
        }
    }

    match insert_todo(&conn, body.section, title, body.importance, body.due_date.as_deref(), body.project_id.as_deref()) {
        Ok(id) => {
            broadcaster.send();
            let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
            let todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
            HttpResponse::Created().json(todo)
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

pub async fn update_todo(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateTodoRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let exists: bool = conn
        .query_row("SELECT COUNT(*) FROM todos WHERE id = ?1", params![id], |row| row.get::<_, i32>(0))
        .is_ok_and(|c| c > 0);

    if !exists {
        return HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}));
    }

    if let Some(Some(project_id)) = body.project_id.as_ref() {
        match project_exists(&conn, project_id) {
            Ok(true) => {}
            Ok(false) => return project_not_found(),
            Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
        }
    }

    if let Some(ref title) = body.title {
        let title = title.trim();
        if title.is_empty() {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "Title cannot be empty"}));
        }
        conn.execute("UPDATE todos SET title = ?1, updated_at = datetime('now') WHERE id = ?2", params![title, id]).unwrap();
    }

    if let Some(completed) = body.completed {
        if completed {
            conn.execute(
                "UPDATE todos SET completed = 1, updated_at = datetime('now'), completed_at = COALESCE(completed_at, datetime('now')), carried_from = NULL WHERE id = ?1",
                params![id],
            )
            .unwrap();
        } else {
            conn.execute("UPDATE todos SET completed = 0, updated_at = datetime('now'), completed_at = NULL WHERE id = ?1", params![id]).unwrap();
        }
    }

    if let Some(section) = body.section {
        conn.execute("UPDATE todos SET section = ?1, updated_at = datetime('now') WHERE id = ?2", params![section.as_str(), id]).unwrap();
    }

    if let Some(importance) = body.importance {
        conn.execute("UPDATE todos SET importance = ?1, updated_at = datetime('now') WHERE id = ?2", params![importance.as_str(), id]).unwrap();
    }

    if let Some(ref due_date_opt) = body.due_date {
        conn.execute("UPDATE todos SET due_date = ?1, updated_at = datetime('now') WHERE id = ?2", params![due_date_opt.as_deref(), id]).unwrap();
    }

    if let Some(ref project_opt) = body.project_id {
        conn.execute("UPDATE todos SET project_id = ?1, updated_at = datetime('now') WHERE id = ?2", params![project_opt.as_deref(), id]).unwrap();
    }

    broadcaster.send();
    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
    HttpResponse::Ok().json(todo)
}

pub async fn delete_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let affected = conn.execute("DELETE FROM todos WHERE id = ?1", params![id]).unwrap_or(0);

    if affected == 0 {
        HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}))
    } else {
        broadcaster.send();
        HttpResponse::Ok().json(DeleteResponse { deleted: id })
    }
}

pub async fn toggle_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let affected = conn
        .execute(
            "UPDATE todos SET
                completed = 1 - completed,
                updated_at = datetime('now'),
                completed_at = CASE WHEN completed = 0 THEN datetime('now') ELSE NULL END,
                carried_from = CASE WHEN completed = 0 THEN NULL ELSE carried_from END
             WHERE id = ?1",
            params![id],
        )
        .unwrap_or(0);

    if affected == 0 {
        return HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}));
    }

    broadcaster.send();
    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
    HttpResponse::Ok().json(todo)
}

pub async fn ws_handler(
    req: HttpRequest,
    body: web::Payload,
    broadcaster: web::Data<Broadcaster>,
) -> actix_web::Result<HttpResponse> {
    let (response, mut session, _msg_stream) = actix_ws::handle(&req, body)?;

    let mut rx = broadcaster.subscribe();
    actix_web::rt::spawn(async move {
        while rx.recv().await.is_ok() {
            if session.text("refresh").await.is_err() {
                break;
            }
        }
    });

    Ok(response)
}
