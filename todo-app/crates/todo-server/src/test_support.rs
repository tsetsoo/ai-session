//! Handler-level test helpers: the real `/api` routes on a test database, without auth.

use actix_web::http::{Method, StatusCode};
use actix_web::{test, web, App};
use rusqlite::Connection;
use serde_json::Value;

use crate::broadcast::Broadcaster;
use crate::db::{DbPool, TestDb};

/// One shared-limits store for every test request (tests use distinct account keys), so a
/// claim and its report reach the same store although each call builds a new app.
fn shared_limits() -> &'static crate::limits::SharedLimits {
    static LIMITS: std::sync::OnceLock<crate::limits::SharedLimits> = std::sync::OnceLock::new();
    LIMITS.get_or_init(Default::default)
}

/// A test database (removed on drop) and its pool; the pool is dropped first.
pub(crate) fn pool(name: &str) -> (TestDb, DbPool) {
    let db = TestDb::new(name);
    let pool = db.pool();
    (db, pool)
}

/// Three computers: `mac`, `spread` and `codbex`. The Macs'
/// user is `me`, codbex's is `tsetso`.
pub(crate) fn seed_computers(conn: &Connection) {
    conn.execute_batch(
        "INSERT INTO computers (id, name, hostname, username) VALUES
             ('mac', 'tsvetelins-macbook-pro', 'mac.tailnet', 'me'),
             ('spread', 'spreads-macbook-pro', 'spread.tailnet', 'me'),
             ('codbex', 'codbexs-macbook-pro', 'codbex.tailnet', 'tsetso');
",
    )
    .unwrap();
}

/// A session row with only its location (stats default to zero).
pub(crate) fn insert_session(conn: &Connection, computer: &str, tool: &str, session_id: &str, cwd: &str) {
    conn.execute(
        "INSERT INTO sessions (tool, session_id, computer_id, cwd) VALUES (?1, ?2, ?3, ?4)",
        rusqlite::params![tool, session_id, computer, cwd],
    )
    .unwrap();
}

/// The project id stored on a session.
pub(crate) fn session_project(conn: &Connection, tool: &str, session_id: &str) -> Option<String> {
    conn.query_row(
        "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2",
        rusqlite::params![tool, session_id],
        |r| r.get(0),
    )
    .unwrap()
}

/// Send one request through the real routes and return the status and JSON body
/// (`Null` when empty, a JSON string when the body isn't JSON).
pub(crate) async fn call(pool: &DbPool, method: Method, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    call_with(pool, &crate::push::PushNotifier::disabled(), &crate::push::Presence::default(), method, uri, body).await
}

/// `call` with a given push notifier and presence store.
pub(crate) async fn call_with(
    pool: &DbPool,
    notifier: &crate::push::PushNotifier,
    presence: &crate::push::Presence,
    method: Method,
    uri: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(pool.clone()))
            .app_data(web::Data::new(Broadcaster::new()))
            .app_data(web::Data::new(notifier.clone()))
            .app_data(web::Data::new(presence.clone()))
            .app_data(web::Data::new(shared_limits().clone()))
            .configure(crate::api_routes),
    )
    .await;
    let mut req = test::TestRequest::default().method(method).uri(uri);
    if let Some(body) = body {
        req = req.set_json(body);
    }
    let resp = test::call_service(&app, req.to_request()).await;
    let status = resp.status();
    let bytes = test::read_body(resp).await;
    let json = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned()))
    };
    (status, json)
}

pub(crate) async fn get(pool: &DbPool, uri: &str) -> (StatusCode, Value) {
    call(pool, Method::GET, uri, None).await
}

pub(crate) async fn post(pool: &DbPool, uri: &str, body: Value) -> (StatusCode, Value) {
    call(pool, Method::POST, uri, Some(body)).await
}

pub(crate) async fn patch(pool: &DbPool, uri: &str, body: Value) -> (StatusCode, Value) {
    call(pool, Method::PATCH, uri, Some(body)).await
}

pub(crate) async fn put(pool: &DbPool, uri: &str, body: Value) -> (StatusCode, Value) {
    call(pool, Method::PUT, uri, Some(body)).await
}

pub(crate) async fn delete(pool: &DbPool, uri: &str) -> (StatusCode, Value) {
    call(pool, Method::DELETE, uri, None).await
}

/// Export nonempty responses from the real routes for the released Mac client's decoders.
#[actix_web::test]
async fn export_mac_compatibility_responses() {
    let Some(output) = std::env::var_os("MAC_COMPATIBILITY_RESPONSES") else { return };
    let (_db, pool) = pool("mac-compatibility");
    {
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, folder, computer_id) VALUES ('p', 'Example', '~/example', 'spread');
             INSERT INTO todos (id, title, project_id) VALUES ('t', 'Example todo', 'p');
             INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id)
                VALUES ('c', 't', 'spread', '/tmp', 'codex', 'test', 'test-session');",
        ).unwrap();
    }
    let output = std::path::PathBuf::from(output);
    for endpoint in ["todos", "computers", "conversations", "projects"] {
        let (status, body) = get(&pool, &format!("/api/{endpoint}")).await;
        assert_eq!(status, StatusCode::OK, "{endpoint}: {body}");
        assert!(body.as_array().is_some_and(|rows| !rows.is_empty()), "{endpoint}: {body}");
        std::fs::write(output.join(format!("{endpoint}.json")), serde_json::to_vec(&body).unwrap()).unwrap();
    }
}
