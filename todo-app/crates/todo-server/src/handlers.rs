use actix_web::{web, HttpRequest, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use todo_shared::{CreateTodoRequest, DeleteResponse, Importance, UpdateTodoRequest};
use uuid::Uuid;

use crate::auth::{forbidden, resolve_scope, RequestScope, ResourceScope};
use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::models::row_to_todo;

pub(crate) const SELECT_COLS: &str = "id, title, completed, on_hold, waiting, importance, due_date, daily_date, carried_from, created_at, updated_at, completed_at, project_id, scheduled_job_id, scheduled_run_id, \
    (SELECT status FROM conversations WHERE conversations.todo_id = todos.id \
        ORDER BY CASE status WHEN 'waiting' THEN 0 WHEN 'busy' THEN 1 \
            WHEN 'idle' THEN 2 WHEN 'unknown' THEN 2 WHEN 'closed' THEN 3 ELSE 4 END, \
            status_updated_at IS NULL, status_updated_at DESC, created_at DESC, id ASC \
        LIMIT 1) AS conversation_status";

fn scoped_read_snapshot<'a>(conn: &'a Connection, scope: &RequestScope) -> Result<Option<Transaction<'a>>, HttpResponse> {
    scope.as_ref().filter(|scope| scope.include_computer_projects)
        .map(|_| conn.unchecked_transaction())
        .transpose().map_err(crate::conversations::server_error)
}

#[derive(serde::Deserialize)]
pub struct TodosQuery {
    pub sort: Option<String>,
    pub show: Option<String>,
    pub project_id: Option<String>,
}

pub async fn list_todos(pool: web::Data<DbPool>, query: web::Query<TodosQuery>, scope: RequestScope, helper: crate::auth::RequestHelper) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };
    if helper.is_some() {
        // A host helper only needs to know which todos are still open (to close the
        // sessions of archived or deleted ones), so it gets ids and nothing else.
        let ids = conn
            .prepare("SELECT id FROM todos WHERE NOT (completed = 1 AND completed_at IS NOT NULL AND completed_at < datetime('now', '-1 day'))")
            .and_then(|mut stmt| stmt.query_map([], |row| Ok(serde_json::json!({"id": row.get::<_, String>(0)?}))).and_then(|rows| rows.collect::<rusqlite::Result<Vec<_>>>()));
        return match ids {
            Ok(rows) => HttpResponse::Ok().json(rows),
            Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
        };
    }
    let _snapshot = match scoped_read_snapshot(&conn, &scope) {
        Ok(snapshot) => snapshot,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
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

    let sql = format!(
        "SELECT {SELECT_COLS} FROM todos WHERE (?1 IS NULL OR project_id = ?1) {show_filter} ORDER BY {order}"
    );
    let mut stmt = conn.prepare(&sql).unwrap();
    let mut todos = stmt
        .query_map(params![query.project_id], row_to_todo)
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect::<Vec<_>>();

    if let Some(scope) = scope {
        todos.retain_mut(|todo| {
            let visible = scope.allows_todo(&todo.id, todo.project_id.as_deref());
            if visible {
                scope.redact_todo(todo);
            }
            visible
        });
    }
    HttpResponse::Ok().json(todos)
}

pub async fn get_todo(pool: web::Data<DbPool>, path: web::Path<String>, scope: RequestScope) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };
    let _snapshot = match scoped_read_snapshot(&conn, &scope) {
        Ok(snapshot) => snapshot,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
    };

    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let result = conn.query_row(&sql, params![id], row_to_todo);

    match result {
        Ok(mut todo) if scope.as_ref().is_none_or(|scope| scope.allows_todo(&todo.id, todo.project_id.as_deref())) => {
            if let Some(scope) = scope {
                scope.redact_todo(&mut todo);
            }
            HttpResponse::Ok().json(todo)
        }
        Ok(_) | Err(rusqlite::Error::QueryReturnedNoRows) => {
            HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}))
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

/// Insert a todo and return its new id. Shared by `POST /api/todos` and
/// `POST /api/todos/from-conversation`, so both create todos the same way.
pub(crate) fn insert_todo(
    conn: &rusqlite::Connection,
    title: &str,
    importance: Option<Importance>,
    due_date: Option<&str>,
    project_id: Option<&str>,
) -> rusqlite::Result<String> {
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO todos (id, title, importance, due_date, project_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![id, title, importance.unwrap_or_default().as_str(), due_date, project_id],
    )?;
    Ok(id)
}

fn project_not_found() -> HttpResponse {
    HttpResponse::NotFound().json(serde_json::json!({"error": "Project not found"}))
}

fn authorize_todo(conn: &Connection, scope: &ResourceScope, id: &str) -> Result<(), HttpResponse> {
    let project = conn.query_row("SELECT project_id FROM todos WHERE id = ?1", [id], |row| row.get::<_, Option<String>>(0))
        .optional().map_err(crate::conversations::server_error)?;
    match project {
        Some(project) if scope.allows_todo(id, project.as_deref()) => Ok(()),
        _ => Err(crate::conversations::not_found("Todo not found")),
    }
}

fn authorize_destination(conn: &Connection, scope: &ResourceScope, id: &str) -> Result<(), HttpResponse> {
    let computer = conn.query_row(
        "SELECT m.computer_id FROM projects p JOIN project_computers m ON m.project_id = p.id AND m.computer_id IS NOT NULL WHERE p.id = ?1",
        [id], |row| row.get::<_, String>(0),
    ).optional().map_err(crate::conversations::server_error)?;
    if scope.project_ids.contains(id) && computer.is_some_and(|id| scope.computer_ids.contains(&id)) {
        Ok(())
    } else {
        Err(project_not_found())
    }
}

fn write_transaction<'a>(conn: &'a Connection, scope: &RequestScope) -> Result<Option<Transaction<'a>>, HttpResponse> {
    scope.as_ref().map(|_| Transaction::new_unchecked(conn, TransactionBehavior::Immediate))
        .transpose().map_err(crate::conversations::server_error)
}

fn finish_todo_write(
    tx: Option<Transaction<'_>>, broadcaster: &Broadcaster, response: HttpResponse,
) -> HttpResponse {
    if let Some(tx) = tx {
        if let Err(err) = tx.commit() {
            return crate::conversations::server_error(err);
        }
    }
    broadcaster.send();
    response
}

pub async fn create_todo(pool: web::Data<DbPool>, body: web::Json<CreateTodoRequest>, broadcaster: web::Data<Broadcaster>, scope: RequestScope) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let tx = match write_transaction(&conn, &scope) {
        Ok(tx) => tx,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
    };
    let title = body.title.trim();
    if title.is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Title cannot be empty"}));
    }

    let Some(project_id) = body.project_id.as_deref().filter(|id| !id.trim().is_empty()) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "project_id is required"}));
    };
    if let Some(scope) = &scope {
        if let Err(response) = authorize_destination(&conn, scope, project_id) {
            return response;
        }
    }
    match crate::projects::project_exists(&conn, project_id) {
        Ok(true) => {}
        Ok(false) => return project_not_found(),
        Err(error) => return crate::conversations::server_error(error),
    }
    match insert_todo(&conn, title, body.importance, body.due_date.as_deref(), Some(project_id)) {
        Ok(id) => {
            let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
            let mut todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
            if let Some(scope) = scope {
                scope.redact_todo(&mut todo);
            }
            finish_todo_write(tx, &broadcaster, HttpResponse::Created().json(todo))
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

pub async fn update_todo(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateTodoRequest>,
    broadcaster: web::Data<Broadcaster>,
    scope: RequestScope,
) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let tx = match write_transaction(&conn, &scope) {
        Ok(tx) => tx,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
    };
    if let Some(scope) = &scope {
        if let Err(response) = authorize_todo(&conn, scope, &id) {
            return response;
        }
    }

    let exists: bool = conn
        .query_row("SELECT COUNT(*) FROM todos WHERE id = ?1", params![id], |row| row.get::<_, i32>(0))
        .is_ok_and(|c| c > 0);

    if !exists {
        return HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}));
    }

    if matches!(body.project_id, Some(None)) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "project_id is required"}));
    }

    if body.on_hold == Some(true) && body.waiting == Some(true) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Choose either Waiting or On hold"}));
    }
    if body.on_hold == Some(true) || body.waiting == Some(true) {
        let completed = body.completed.unwrap_or_else(|| {
            conn.query_row("SELECT completed FROM todos WHERE id = ?1", params![id], |row| row.get::<_, bool>(0)).unwrap()
        });
        if completed {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "A completed todo cannot be moved to Waiting or On hold"}));
        }
    }

    let new_project = if let Some(Some(project_id)) = body.project_id.as_ref() {
        if let Some(scope) = &scope {
            if let Err(response) = authorize_destination(&conn, scope, project_id) {
                return response;
            }
        }
        match crate::projects::project_exists(&conn, project_id) {
            Ok(true) => Some(project_id),
            Ok(false) => return project_not_found(),
            Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
        }
    } else {
        None
    };
    if let Some(ref title) = body.title {
        let title = title.trim();
        if title.is_empty() {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "Title cannot be empty"}));
        }
        conn.execute("UPDATE todos SET title = ?1, updated_at = datetime('now') WHERE id = ?2", params![title, id]).unwrap();
    }

    if body.completed.is_some() || body.on_hold.is_some() || body.waiting.is_some() {
        conn.execute(
            "UPDATE todos SET
                completed = COALESCE(?1, completed),
                on_hold = CASE WHEN COALESCE(?1, completed) OR ?3 = 1 THEN 0 ELSE COALESCE(?2, on_hold) END,
                waiting = CASE WHEN COALESCE(?1, completed) OR ?2 = 1 THEN 0 ELSE COALESCE(?3, waiting) END,
                completed_at = CASE ?1 WHEN 1 THEN COALESCE(completed_at, datetime('now'))
                                       WHEN 0 THEN NULL ELSE completed_at END,
                carried_from = CASE WHEN ?1 = 1 THEN NULL ELSE carried_from END,
                updated_at = datetime('now')
             WHERE id = ?4",
            params![body.completed, body.on_hold, body.waiting, id],
        )
        .unwrap();
    }


    if let Some(importance) = body.importance {
        conn.execute("UPDATE todos SET importance = ?1, updated_at = datetime('now') WHERE id = ?2", params![importance.as_str(), id]).unwrap();
    }

    if let Some(ref due_date_opt) = body.due_date {
        conn.execute("UPDATE todos SET due_date = ?1, updated_at = datetime('now') WHERE id = ?2", params![due_date_opt.as_deref(), id]).unwrap();
    }

    if let Some(project_id) = new_project {
        conn.execute(
            "UPDATE todos SET project_id = ?1, updated_at = datetime('now') WHERE id = ?2",
            params![project_id, id],
        )
        .unwrap();
    }

    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let mut todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
    if let Some(scope) = scope {
        scope.redact_todo(&mut todo);
    }
    finish_todo_write(tx, &broadcaster, HttpResponse::Ok().json(todo))
}

pub async fn delete_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>, scope: RequestScope) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let tx = match write_transaction(&conn, &scope) {
        Ok(tx) => tx,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
    };
    if let Some(scope) = &scope {
        if let Err(response) = authorize_todo(&conn, scope, &id) {
            return response;
        }
    }

    if let Some(scope) = &scope {
        match crate::conversations::todo_conversations_within_scope(&conn, scope, &id, false) {
            Ok(true) => {}
            Ok(false) => return forbidden("Deleting would remove a conversation outside your grants"),
            Err(err) => return crate::conversations::open_error(err),
        }
        let linked: rusqlite::Result<bool> = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM memories WHERE todo_id = ?1)
                 OR EXISTS(SELECT 1 FROM job_runs WHERE todo_id = ?1)
                 OR EXISTS(SELECT 1 FROM ideas WHERE todo_id = ?1)
                 OR EXISTS(SELECT 1 FROM push_muted_todos WHERE todo_id = ?1)",
            [&id], |row| row.get(0),
        );
        match linked {
            Ok(false) => {}
            Ok(true) => return forbidden("Deleting a todo with linked records requires a full-access token"),
            Err(err) => return crate::conversations::server_error(err),
        }
    }

    let affected = conn.execute("DELETE FROM todos WHERE id = ?1", params![id]).unwrap_or(0);

    if affected == 0 {
        HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"}))
    } else {
        finish_todo_write(tx, &broadcaster, HttpResponse::Ok().json(DeleteResponse { deleted: id }))
    }
}

pub async fn toggle_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>, scope: RequestScope) -> HttpResponse {
    let id = path.into_inner();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let tx = match write_transaction(&conn, &scope) {
        Ok(tx) => tx,
        Err(response) => return response,
    };
    let scope = match resolve_scope(&conn, scope) {
        Ok(scope) => scope,
        Err(response) => return response,
    };
    if let Some(scope) = &scope {
        if let Err(response) = authorize_todo(&conn, scope, &id) {
            return response;
        }
    }

    let affected = conn
        .execute(
            "UPDATE todos SET
                completed = 1 - completed,
                on_hold = 0,
                waiting = 0,
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

    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    let mut todo = conn.query_row(&sql, params![id], row_to_todo).unwrap();
    if let Some(scope) = scope {
        scope.redact_todo(&mut todo);
    }
    finish_todo_write(tx, &broadcaster, HttpResponse::Ok().json(todo))
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
            "INSERT INTO projects (id, name, computer_id, folder) VALUES (?1, ?2, (SELECT id FROM computers WHERE id = ?3), ?4)",
            rusqlite::params![id, section, "mac", format!("~/{section}")],
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
    async fn waiting_switches_status_and_clears_on_completion() {
        use crate::test_support::{get, patch};
        let (_db, pool) = pool("todo-waiting");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = project_on(&conn, "Si");
        let (_, created) = post(&pool, "/api/todos", json!({"title": "Return shortly", "project_id": project})).await;
        assert_eq!(created["waiting"], false);
        let id = created["id"].as_str().unwrap();
        let uri = format!("/api/todos/{id}");
        for (change, waiting, on_hold) in [
            (json!({"on_hold": true}), false, true),
            (json!({"waiting": true}), true, false),
            (json!({"title": "Renamed"}), true, false),
            (json!({"waiting": false}), false, false),
            (json!({"waiting": true}), true, false),
            (json!({"on_hold": true}), false, true),
            (json!({"waiting": true}), true, false),
        ] {
            let (status, updated) = patch(&pool, &uri, change).await;
            assert_eq!(status, StatusCode::OK, "{updated}");
            assert_eq!(updated["waiting"], waiting);
            assert_eq!(updated["on_hold"], on_hold);
            assert_eq!(updated["project_id"], project);
        }
        let (_, listed) = get(&pool, "/api/todos").await;
        assert_eq!(listed[0]["waiting"], true);
        let (status, _) = patch(&pool, &uri, json!({"waiting": true, "on_hold": true})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (_, done) = post(&pool, &format!("{uri}/toggle"), json!({})).await;
        assert_eq!(done["completed"], true);
        assert_eq!(done["waiting"], false);
        let (status, _) = patch(&pool, &uri, json!({"waiting": true})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
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
    async fn create_todo_stores_the_project() {
        let (_db, pool) = pool("todo");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        let project = project_on(&conn, "Si");
        let (status, body) = post(&pool, "/api/todos", json!({"title": "x", "project_id": project})).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        assert_eq!(body["project_id"], project);
        let (status, cleared) = crate::test_support::patch(&pool, &format!("/api/todos/{}", body["id"].as_str().unwrap()), json!({"project_id": null})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{cleared}");
        assert_eq!(cleared["error"], "project_id is required");
    }
}
