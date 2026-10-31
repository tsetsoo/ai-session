use actix_web::{web, HttpRequest, HttpResponse};
use rusqlite::{params, OptionalExtension};
use todo_shared::{CreateTodoRequest, DeleteResponse, Importance, Section, SectionCount, UpdateTodoRequest};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::models::row_to_todo;

pub(crate) const SELECT_COLS: &str = "id, section, title, completed, on_hold, importance, due_date, daily_date, carried_from, created_at, updated_at, completed_at, project_id, \
    (SELECT status FROM conversations WHERE conversations.todo_id = todos.id \
        ORDER BY CASE status WHEN 'waiting' THEN 0 WHEN 'busy' THEN 1 \
            WHEN 'idle' THEN 2 WHEN 'unknown' THEN 2 WHEN 'closed' THEN 3 ELSE 4 END, \
            status_updated_at IS NULL, status_updated_at DESC, created_at DESC, id ASC \
        LIMIT 1) AS conversation_status";

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

fn named_section(value: &str) -> Option<Section> {
    match value {
        "Sp" => Some(Section::Sp),
        "I" => Some(Section::I),
        "Si" => Some(Section::Si),
        "P" => Some(Section::P),
        _ => None,
    }
}

fn project_section(conn: &rusqlite::Connection, id: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row("SELECT section FROM projects WHERE id = ?1", params![id], |row| row.get(0)).optional()
}

fn project_section_of_todo(conn: &rusqlite::Connection, id: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT p.section FROM todos t JOIN projects p ON p.id = t.project_id WHERE t.id = ?1",
        params![id],
        |row| row.get(0),
    )
    .optional()
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

    let Some(project_id) = body.project_id.as_deref().filter(|id| !id.trim().is_empty()) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "project_id is required"}));
    };
    let project_section = match project_section(&conn, project_id) {
        Ok(Some(section)) => section,
        Ok(None) => return project_not_found(),
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };
    let Some(section) = named_section(&project_section) else {
        return HttpResponse::InternalServerError().json(serde_json::json!({"error": "project section is invalid"}));
    };
    if body.section.is_some_and(|asked| asked != section) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "section does not match project"}));
    }

    match insert_todo(&conn, section, title, body.importance, body.due_date.as_deref(), Some(project_id)) {
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

    if matches!(body.project_id, Some(None)) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "project_id is required"}));
    }

    if body.on_hold == Some(true) {
        let completed = body.completed.unwrap_or_else(|| {
            conn.query_row("SELECT completed FROM todos WHERE id = ?1", params![id], |row| row.get::<_, bool>(0)).unwrap()
        });
        if completed {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "A completed todo cannot be put on hold"}));
        }
    }

    let new_project = if let Some(Some(project_id)) = body.project_id.as_ref() {
        match project_section(&conn, project_id) {
            Ok(Some(section)) => Some((project_id.clone(), section)),
            Ok(None) => return project_not_found(),
            Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
        }
    } else {
        None
    };
    if let Some(asked) = body.section {
        let expected = if let Some((_, section)) = &new_project {
            Some(section.clone())
        } else {
            match project_section_of_todo(&conn, &id) {
                Ok(section) => section,
                Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
            }
        };
        if expected.is_some_and(|section| section != asked.as_str()) {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "section does not match project"}));
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
                "UPDATE todos SET completed = 1, on_hold = 0, updated_at = datetime('now'), completed_at = COALESCE(completed_at, datetime('now')), carried_from = NULL WHERE id = ?1",
                params![id],
            )
            .unwrap();
        } else {
            conn.execute("UPDATE todos SET completed = 0, updated_at = datetime('now'), completed_at = NULL WHERE id = ?1", params![id]).unwrap();
        }
    }

    if new_project.is_none() {
        if let Some(section) = body.section {
            conn.execute("UPDATE todos SET section = ?1, updated_at = datetime('now') WHERE id = ?2", params![section.as_str(), id]).unwrap();
        }
    }

    if let Some(on_hold) = body.on_hold {
        conn.execute("UPDATE todos SET on_hold = ?1, updated_at = datetime('now') WHERE id = ?2", params![on_hold, id]).unwrap();
    }

    if let Some(importance) = body.importance {
        conn.execute("UPDATE todos SET importance = ?1, updated_at = datetime('now') WHERE id = ?2", params![importance.as_str(), id]).unwrap();
    }

    if let Some(ref due_date_opt) = body.due_date {
        conn.execute("UPDATE todos SET due_date = ?1, updated_at = datetime('now') WHERE id = ?2", params![due_date_opt.as_deref(), id]).unwrap();
    }

    if let Some((project_id, section)) = new_project {
        conn.execute(
            "UPDATE todos SET project_id = ?1, section = ?2, updated_at = datetime('now') WHERE id = ?3",
            params![project_id, section, id],
        )
        .unwrap();
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
                on_hold = 0,
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
    let (response, mut session, mut messages) = actix_ws::handle(&req, body)?;

    let mut rx = broadcaster.subscribe();
    actix_web::rt::spawn(async move {
        // The first fetch and the upgrade are separate requests. Reconcile anything
        // that changed between them, even if no later mutation arrives.
        if session.text("refresh").await.is_err() {
            return;
        }
        let mut heartbeat = tokio::time::interval(std::time::Duration::from_secs(25));
        let mut last_pong = tokio::time::Instant::now();
        loop {
            tokio::select! {
                change = rx.recv() => {
                    match change {
                        Ok(()) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                            // A slow reader only needs the latest snapshot. Lagging
                            // must not permanently stop its refresh notifications.
                            if session.text("refresh").await.is_err() { break; }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
                message = messages.recv() => {
                    match message {
                        Some(Ok(actix_ws::Message::Ping(bytes))) => {
                            if session.pong(&bytes).await.is_err() { break; }
                        }
                        Some(Ok(actix_ws::Message::Pong(_))) => last_pong = tokio::time::Instant::now(),
                        Some(Ok(actix_ws::Message::Close(reason))) => {
                            let _ = session.close(reason).await;
                            return;
                        }
                        None | Some(Err(_)) => break,
                        _ => {}
                    }
                }
                _ = heartbeat.tick() => {
                    if last_pong.elapsed() > std::time::Duration::from_secs(60)
                        || session.ping(b"hub").await.is_err() { break; }
                }
            }
        }
        let _ = session.close(None).await;
    });

    Ok(response)
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use serde_json::json;

    use crate::test_support::{pool, post, seed_computers};

    #[actix_web::test]
    async fn websocket_reconciles_on_connect_and_answers_client_ping() {
        use actix_web::{test, web, App};
        let app = test::init_service(
            App::new().app_data(web::Data::new(crate::broadcast::Broadcaster::new()))
                .route("/api/ws", web::get().to(super::ws_handler))
        ).await;
        // Masked client ping("test"), then close. Reading the request stream is
        // essential: the old send-only handler never answered or closed this body.
        let frames = vec![0x89, 0x84, 1, 2, 3, 4, b't' ^ 1, b'e' ^ 2, b's' ^ 3, b't' ^ 4,
                          0x88, 0x80, 1, 2, 3, 4];
        let request = test::TestRequest::get().uri("/api/ws")
            .insert_header(("connection", "upgrade"))
            .insert_header(("upgrade", "websocket"))
            .insert_header(("sec-websocket-version", "13"))
            .insert_header(("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="))
            .set_payload(frames).to_request();
        let response = test::call_service(&app, request).await;
        assert_eq!(response.status(), StatusCode::SWITCHING_PROTOCOLS);
        let bytes = tokio::time::timeout(std::time::Duration::from_secs(2), test::read_body(response))
            .await.expect("WebSocket must process the client's close frame");
        assert!(bytes.windows(9).any(|frame| frame == b"\x81\x07refresh"), "initial refresh missing");
        assert!(bytes.windows(6).any(|frame| frame == b"\x8a\x04test"), "ping was not answered");
    }

    fn project_on(conn: &rusqlite::Connection, section: &str) -> String {
        let id = format!("p-{section}");
        conn.execute(
            "INSERT INTO projects (id, name, section, folder) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id, section, section, format!("~/{section}")],
        )
        .unwrap();
        id
    }

    #[actix_web::test]
    async fn hold_and_resume_preserve_todo_and_conversations() {
        use crate::test_support::{get, patch};
        let (_db, pool) = pool("todo-hold");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = project_on(&conn, "Si");
        let (status, created) = post(&pool, "/api/todos", json!({"title": "Continue later", "project_id": project})).await;
        assert_eq!(status, StatusCode::CREATED);
        assert_eq!(created["on_hold"], false);
        let id = created["id"].as_str().unwrap();
        let uri = format!("/api/todos/{id}");
        conn.execute(
            "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, status) VALUES ('c', ?1, 'mac', '~/code', 'claude', 'hold-test', 'busy')",
            rusqlite::params![id],
        ).unwrap();
        for on_hold in [true, false, true] {
            let (status, updated) = patch(&pool, &uri, json!({"on_hold": on_hold})).await;
            assert_eq!(status, StatusCode::OK, "{updated}");
            assert_eq!(updated["on_hold"], on_hold);
            assert_eq!(updated["completed"], false);
            assert_eq!(updated["project_id"], project);
            assert_eq!(updated["conversation_status"], "busy");
            let (_, fetched) = get(&pool, &uri).await;
            assert_eq!(fetched["on_hold"], on_hold);
            let (_, listed) = get(&pool, "/api/todos").await;
            assert_eq!(listed[0]["on_hold"], on_hold);
        }
        // An older client updating another field must preserve the hold state.
        let (_, renamed) = patch(&pool, &uri, json!({"title": "Renamed"})).await;
        assert_eq!(renamed["on_hold"], true);
        let (_, done) = post(&pool, &format!("{uri}/toggle"), json!({})).await;
        assert_eq!(done["completed"], true);
        assert_eq!(done["on_hold"], false);
        let (status, _) = patch(&pool, &uri, json!({"on_hold": true, "title": "Invalid"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (_, unchanged) = get(&pool, &uri).await;
        assert_eq!(unchanged["title"], "Renamed");
        let (_, held) = patch(&pool, &uri, json!({"completed": false, "on_hold": true})).await;
        assert_eq!(held["on_hold"], true);
        let (_, done) = patch(&pool, &uri, json!({"completed": true})).await;
        assert_eq!(done["on_hold"], false);
        let (status, _) = patch(&pool, &uri, json!({"completed": true, "on_hold": true})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(conn.query_row("SELECT status FROM conversations WHERE id = 'c'", [], |r| r.get::<_, String>(0)).unwrap(), "busy");
    }

    #[actix_web::test]
    async fn create_todo_without_a_project_inserts_nothing() {
        let (_db, pool) = pool("todo");
        seed_computers(&pool.get().unwrap());
        let (status, body) = post(&pool, "/api/todos", json!({"section": "Si", "title": "loose"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(body["error"], "project_id is required");
        let n: i64 = pool.get().unwrap().query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[actix_web::test]
    async fn create_todo_rejects_a_section_that_disagrees_with_the_project() {
        let (_db, pool) = pool("todo");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = project_on(&conn, "Si");
        let (status, body) = post(&pool, "/api/todos", json!({"section": "P", "title": "x", "project_id": project})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(body["error"], "section does not match project");
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM todos", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }

    #[actix_web::test]
    async fn create_todo_stores_the_projects_section() {
        let (_db, pool) = pool("todo");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = project_on(&conn, "Si");
        let (status, body) = post(&pool, "/api/todos", json!({"title": "x", "project_id": project})).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        assert_eq!(body["section"], "Si");
        assert_eq!(body["project_id"], project);
        let (status, cleared) = crate::test_support::patch(&pool, &format!("/api/todos/{}", body["id"].as_str().unwrap()), json!({"project_id": null})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{cleared}");
        assert_eq!(cleared["error"], "project_id is required");
    }
}
