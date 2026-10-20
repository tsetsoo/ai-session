//! Handler-level test helpers: the real `/api` routes on a test database, without auth.

use actix_web::http::{Method, StatusCode};
use actix_web::{test, web, App};
use rusqlite::Connection;
use serde_json::Value;

use crate::broadcast::Broadcaster;
use crate::db::{DbPool, TestDb};

/// A test database (removed on drop) and its pool; the pool is dropped first.
pub(crate) fn pool(name: &str) -> (TestDb, DbPool) {
    let db = TestDb::new(name);
    let pool = db.pool();
    (db, pool)
}

/// Three computers: `mac` (sections Si + P), `spread` (Sp) and `codbex` (I). The Macs'
/// user is `me`, codbex's is `tsetso`.
pub(crate) fn seed_computers(conn: &Connection) {
    conn.execute_batch(
        "INSERT INTO computers (id, name, hostname, username) VALUES
             ('mac', 'tsvetelins-macbook-pro', 'mac.tailnet', 'me'),
             ('spread', 'spreads-macbook-pro', 'spread.tailnet', 'me'),
             ('codbex', 'codbexs-macbook-pro', 'codbex.tailnet', 'tsetso');
         INSERT INTO section_computers (section, computer_id) VALUES
             ('Si', 'mac'), ('P', 'mac'),
             ('Sp', 'spread'), ('I', 'codbex');",
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
