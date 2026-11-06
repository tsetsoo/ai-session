//! Each computer's last `ai-todo-status doctor` report, so the app can show a computer's
//! health (tool versions, which conversations run an older one, deliveries, auth) with
//! its time even when it can't reach that computer.
//!
//! The runner sends it every few minutes (`ai-todo-status report`). The hub keeps the
//! latest one per computer as it came: the app reads the fields it knows, and a newer
//! script's extra fields need no hub change.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::conversations::{bad_request, not_found, server_error};
use crate::db::DbPool;

/// A report bigger than this is refused (a busy computer's is ~20 KB).
pub(crate) const MAX_REPORT_BYTES: usize = 512 * 1024;

pub(crate) const V25_OBJECTS: &str = "
    CREATE TABLE IF NOT EXISTS computer_health (
        computer_id TEXT PRIMARY KEY REFERENCES computers(id) ON DELETE CASCADE,
        report      TEXT NOT NULL,
        reported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
";

#[derive(Debug, PartialEq)]
pub(crate) enum HealthError {
    BadRequest(&'static str),
    NotFound,
    Db(String),
}

impl From<rusqlite::Error> for HealthError {
    fn from(e: rusqlite::Error) -> Self {
        HealthError::Db(e.to_string())
    }
}

fn computer_exists(conn: &Connection, id: &str) -> Result<bool, HealthError> {
    Ok(conn.query_row("SELECT 1 FROM computers WHERE id = ?1", params![id], |_| Ok(())).optional()?.is_some())
}

/// Store `report` as computer `id`'s latest; it must be a JSON object.
pub(crate) fn set_health_db(conn: &Connection, id: &str, report: &Value) -> Result<(), HealthError> {
    if !report.is_object() {
        return Err(HealthError::BadRequest("The report must be a JSON object"));
    }
    let text = report.to_string();
    if text.len() > MAX_REPORT_BYTES {
        return Err(HealthError::BadRequest("The report is too large"));
    }
    if !computer_exists(conn, id)? {
        return Err(HealthError::NotFound);
    }
    conn.execute(
        "INSERT INTO computer_health (computer_id, report, reported_at)
         VALUES (?1, ?2, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
         ON CONFLICT(computer_id) DO UPDATE SET report = excluded.report, reported_at = excluded.reported_at",
        params![id, text],
    )?;
    Ok(())
}

/// `{computer_id, reported_at, report}`; `report` and `reported_at` are null before the
/// computer has sent one.
pub(crate) fn health_db(conn: &Connection, id: &str) -> Result<Value, HealthError> {
    if !computer_exists(conn, id)? {
        return Err(HealthError::NotFound);
    }
    let row: Option<(String, String)> = conn
        .query_row("SELECT report, reported_at FROM computer_health WHERE computer_id = ?1", params![id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()?;
    let (report, reported_at) = match row {
        Some((report, at)) => (serde_json::from_str(&report).unwrap_or(Value::Null), Value::String(at)),
        None => (Value::Null, Value::Null),
    };
    Ok(json!({"computer_id": id, "reported_at": reported_at, "report": report}))
}

fn respond(result: Result<Value, HealthError>) -> HttpResponse {
    match result {
        Ok(v) => HttpResponse::Ok().json(v),
        Err(HealthError::BadRequest(m)) => bad_request(m),
        Err(HealthError::NotFound) => not_found("Computer not found"),
        Err(HealthError::Db(e)) => server_error(e),
    }
}

pub async fn get_health(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => respond(health_db(&conn, &path)),
        Err(e) => server_error(e),
    }
}

pub async fn put_health(pool: web::Data<DbPool>, path: web::Path<String>, body: web::Json<Value>) -> HttpResponse {
    match pool.get() {
        Ok(conn) => respond(set_health_db(&conn, &path, &body).map(|_| json!({"ok": true}))),
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::http::{Method, StatusCode};

    #[actix_web::test]
    async fn stores_the_latest_report_per_computer() {
        let (_db, pool) = crate::test_support::pool("health");
        crate::test_support::seed_computers(&pool.get().unwrap());
        let uri = "/api/computers/mac/health";

        let (status, body) = crate::test_support::call(&pool, Method::GET, uri, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["report"], Value::Null);
        assert_eq!(body["reported_at"], Value::Null);

        let first = json!({"doctor_version": 3, "tools": {"claude": {"version": "2.1.318"}}});
        let (status, body) = crate::test_support::call(&pool, Method::PUT, uri, Some(first)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let second = json!({"doctor_version": 3, "tools": {"claude": {"version": "2.1.319"}}, "new_field": [1]});
        crate::test_support::call(&pool, Method::PUT, uri, Some(second)).await;

        let (_, body) = crate::test_support::call(&pool, Method::GET, uri, None).await;
        assert_eq!(body["computer_id"], "mac");
        assert_eq!(body["report"]["tools"]["claude"]["version"], "2.1.319");
        assert_eq!(body["report"]["new_field"][0], 1, "fields the hub doesn't know are kept");
        assert!(body["reported_at"].as_str().is_some_and(|at| at.ends_with('Z')), "{body}");

        // Another computer's is separate.
        let (_, other) = crate::test_support::call(&pool, Method::GET, "/api/computers/spread/health", None).await;
        assert_eq!(other["report"], Value::Null);
    }

    #[actix_web::test]
    async fn refuses_unknown_computers_and_non_objects() {
        let (_db, pool) = crate::test_support::pool("health");
        crate::test_support::seed_computers(&pool.get().unwrap());
        let (status, _) = crate::test_support::call(&pool, Method::GET, "/api/computers/nope/health", None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (status, _) =
            crate::test_support::call(&pool, Method::PUT, "/api/computers/nope/health", Some(json!({"a": 1}))).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (status, _) =
            crate::test_support::call(&pool, Method::PUT, "/api/computers/mac/health", Some(json!([1, 2]))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let conn = pool.get().unwrap();
        let big = json!({"x": "a".repeat(MAX_REPORT_BYTES)});
        assert_eq!(set_health_db(&conn, "mac", &big), Err(HealthError::BadRequest("The report is too large")));
    }

    #[test]
    fn deleting_a_computer_deletes_its_report() {
        let (_db, pool) = crate::test_support::pool("health");
        let conn = pool.get().unwrap();
        crate::test_support::seed_computers(&conn);
        set_health_db(&conn, "codbex", &json!({"doctor_version": 3})).unwrap();
        conn.execute("DELETE FROM section_computers WHERE computer_id = 'codbex'", []).unwrap();
        conn.execute("DELETE FROM computers WHERE id = 'codbex'", []).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM computer_health", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
    }
}
