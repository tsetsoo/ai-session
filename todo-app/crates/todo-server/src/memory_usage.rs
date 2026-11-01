//! Memory usefulness: hosts report which memories were used and which days a project (or,
//! for global memories, a computer) was active. A memory nobody used for 14 active days of
//! its scope is archived as `unused`; a later use brings it back.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, get_computer, not_found, server_error};
use crate::db::DbPool;
use crate::memories::record_use;

/// Active days without a use after which a memory is archived as unused.
pub(crate) const UNUSED_ACTIVE_DAYS: i64 = 14;
/// Signals a host may report; `user` and `duplicate` are recorded by the hub itself.
const HOST_SIGNALS: [&str; 2] = ["relied", "search"];

#[derive(Debug, Deserialize)]
pub struct UseReport {
    pub id: String,
    pub signal: String,
}

/// `POST /api/memories/uses`: one host's day of activity and the uses it saw.
#[derive(Debug, Deserialize)]
pub struct UsesRequest {
    pub computer_id: String,
    /// The host's local date, `YYYY-MM-DD`.
    pub day: String,
    /// The projects active that day: the conversation's project and its ancestors.
    #[serde(default)]
    pub project_ids: Vec<String>,
    #[serde(default)]
    pub uses: Vec<UseReport>,
}

#[derive(Debug, Serialize)]
pub struct UsesResponse {
    pub recorded: usize,
    pub unknown: Vec<String>,
    pub archived: Vec<String>,
}

fn valid_day(day: &str) -> bool {
    let b = day.as_bytes();
    b.len() == 10
        && b.iter().enumerate().all(|(i, c)| if i == 4 || i == 7 { *c == b'-' } else { c.is_ascii_digit() })
}

/// Archive (reason `unused`) every live memory whose scope had at least 14 active days after
/// both its `aged_from` day and its last use. Pinned, pending and imported (`claude-memory`)
/// memories are never pruned; neither is one with no project and no computer.
pub(crate) fn prune_unused(conn: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "UPDATE memories SET archived = 1, archived_reason = 'unused', updated_at = datetime('now')
         WHERE archived = 0 AND pinned = 0 AND pending = 0 AND source != 'claude-memory'
           AND (project_id IS NOT NULL OR computer_id IS NOT NULL)
           AND (SELECT COUNT(*) FROM memory_active_days d
                WHERE d.scope = CASE WHEN memories.project_id IS NOT NULL THEN 'project:' || memories.project_id
                                     ELSE 'computer:' || memories.computer_id END
                  AND d.day > MAX(memories.aged_from, COALESCE(date(memories.last_used_at), ''))) >= ?1
         RETURNING id",
    )?;
    let ids = stmt.query_map(params![UNUSED_ACTIVE_DAYS], |r| r.get(0))?.collect::<rusqlite::Result<Vec<String>>>()?;
    Ok(ids)
}

enum UsesError {
    BadRequest(String),
    NotFound(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for UsesError {
    fn from(e: rusqlite::Error) -> Self {
        UsesError::Db(e)
    }
}

fn record_uses_db(conn: &Connection, req: &UsesRequest) -> Result<UsesResponse, UsesError> {
    if !valid_day(&req.day) {
        return Err(UsesError::BadRequest("day must be YYYY-MM-DD".into()));
    }
    if let Some(bad) = req.uses.iter().find(|u| !HOST_SIGNALS.contains(&u.signal.as_str())) {
        return Err(UsesError::BadRequest(format!("signal must be relied or search, not {}", bad.signal)));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let computer_id = req.computer_id.trim();
    if get_computer(&tx, computer_id)?.is_none() {
        return Err(UsesError::NotFound("Computer not found"));
    }
    let scopes = std::iter::once(format!("computer:{computer_id}"))
        .chain(req.project_ids.iter().map(|p| p.trim()).filter(|p| !p.is_empty()).map(|p| format!("project:{p}")));
    for scope in scopes {
        tx.execute("INSERT OR IGNORE INTO memory_active_days (scope, day) VALUES (?1, ?2)", params![scope, req.day])?;
    }
    let mut recorded = 0;
    let mut unknown = Vec::new();
    for u in &req.uses {
        if record_use(&tx, &u.id, &u.signal)? {
            recorded += 1;
        } else {
            unknown.push(u.id.clone());
        }
    }
    let archived = prune_unused(&tx)?;
    tx.commit()?;
    Ok(UsesResponse { recorded, unknown, archived })
}

pub async fn record_uses(
    pool: web::Data<DbPool>,
    body: web::Json<UsesRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match record_uses_db(&conn, &body) {
        Ok(resp) => {
            if resp.recorded > 0 || !resp.archived.is_empty() {
                broadcaster.send();
            }
            HttpResponse::Ok().json(resp)
        }
        Err(UsesError::BadRequest(msg)) => bad_request(&msg),
        Err(UsesError::NotFound(msg)) => not_found(msg),
        Err(UsesError::Db(e)) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::{params, Connection};
    use serde_json::{json, Value};

    use crate::db::DbPool;
    use crate::test_support::{get, pool, post, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'a', 'Si', '~/a');
             INSERT INTO memories (id, project_id, kind, text, text_key, aged_from) VALUES
                 ('m1', 'pa', 'gotcha', 'Unlock the keychain before signing', 'k1', '2026-01-01'),
                 ('m2', 'pa', 'decision', 'Pinned rule', 'k2', '2026-01-01'),
                 ('m3', 'pa', 'gotcha', 'Pending idea', 'k3', '2026-01-01'),
                 ('m4', 'pa', 'gotcha', 'Imported note', 'k4', '2026-01-01');
             UPDATE memories SET pinned = 1 WHERE id = 'm2';
             UPDATE memories SET pending = 1 WHERE id = 'm3';
             UPDATE memories SET source = 'claude-memory', source_key = 'x/y.md', computer_id = 'mac' WHERE id = 'm4';",
        )
        .unwrap();
    }

    fn day(n: u32) -> String {
        format!("2026-02-{n:02}")
    }

    async fn active(pool: &DbPool, project: &str, from: u32, to: u32) -> Value {
        let mut last = Value::Null;
        for n in from..=to {
            let (status, body) = post(pool, "/api/memories/uses",
                json!({"computer_id": "mac", "day": day(n), "project_ids": [project], "uses": []})).await;
            assert_eq!(status, StatusCode::OK, "{body}");
            last = body;
        }
        last
    }

    fn state(conn: &Connection, id: &str) -> (i64, Option<String>) {
        conn.query_row("SELECT archived, archived_reason FROM memories WHERE id = ?1", params![id], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
    }

    #[actix_web::test]
    async fn uses_records_active_days_once() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        active(&pool, "pa", 1, 1).await;
        active(&pool, "pa", 1, 1).await;
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM memory_active_days", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 2, "one project day and one computer day");
        let (status, _) = post(&pool, "/api/memories/uses", json!({"computer_id": "mac", "day": "Feb 1", "project_ids": [], "uses": []})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _) = post(&pool, "/api/memories/uses",
            json!({"computer_id": "mac", "day": day(2), "project_ids": [], "uses": [{"id": "m1", "signal": "shown"}]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "being shown is not a use");
    }

    #[actix_web::test]
    async fn prune_after_14_active_days() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        let r = active(&pool, "pa", 1, 13).await;
        assert_eq!(r["archived"], json!([]));
        assert_eq!(state(&conn, "m1"), (0, None));
        let r = active(&pool, "pa", 14, 14).await;
        assert_eq!(r["archived"], json!(["m1"]));
        assert_eq!(state(&conn, "m1"), (1, Some("unused".into())));
    }

    #[actix_web::test]
    async fn prune_counts_from_last_use() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        active(&pool, "pa", 1, 9).await;
        let (_, r) = post(&pool, "/api/memories/uses",
            json!({"computer_id": "mac", "day": day(10), "project_ids": ["pa"], "uses": [{"id": "m1", "signal": "relied"}, {"id": "bogus", "signal": "relied"}]})).await;
        assert_eq!((&r["recorded"], &r["unknown"]), (&json!(1), &json!(["bogus"])));
        // The use lands on today's date in UTC; count its day as used.
        conn.execute("UPDATE memories SET last_used_at = '2026-02-10 12:00:00' WHERE id = 'm1'", []).unwrap();
        active(&pool, "pa", 11, 23).await;
        assert_eq!(state(&conn, "m1"), (0, None), "13 active days since the use");
        active(&pool, "pa", 24, 24).await;
        assert_eq!(state(&conn, "m1"), (1, Some("unused".into())));
    }

    #[actix_web::test]
    async fn prune_skips_pinned_pending_claude_memory() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        active(&pool, "pa", 1, 20).await;
        for id in ["m2", "m3", "m4"] {
            assert_eq!(state(&conn, id), (0, None), "{id}");
        }
    }

    #[actix_web::test]
    async fn prune_global_uses_computer_scope() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO memories (id, computer_id, kind, text, text_key, aged_from) VALUES ('g', 'mac', 'gotcha', 'Global', 'g', '2026-01-01')", [])
            .unwrap();
        for n in 1..=14 {
            post(&pool, "/api/memories/uses", json!({"computer_id": "spread", "day": day(n), "project_ids": [], "uses": []})).await;
        }
        assert_eq!(state(&conn, "g"), (0, None), "another computer's days don't count");
        for n in 1..=14 {
            post(&pool, "/api/memories/uses", json!({"computer_id": "mac", "day": day(n), "project_ids": [], "uses": []})).await;
        }
        assert_eq!(state(&conn, "g"), (1, Some("unused".into())));
    }

    #[actix_web::test]
    async fn search_use_revives_unused() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("UPDATE memories SET archived = 1, archived_reason = 'unused' WHERE id = 'm1'", []).unwrap();
        post(&pool, "/api/memories/uses", json!({"computer_id": "mac", "day": day(1), "project_ids": [], "uses": [{"id": "m1", "signal": "search"}]})).await;
        assert_eq!(state(&conn, "m1"), (0, None));
    }

    #[actix_web::test]
    async fn old_memories_age_from_migration() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        // Days before a memory's aged_from never count.
        conn.execute("UPDATE memories SET aged_from = '2026-02-10' WHERE id = 'm1'", []).unwrap();
        active(&pool, "pa", 1, 23).await;
        assert_eq!(state(&conn, "m1"), (0, None), "13 active days after aged_from");
    }

    #[actix_web::test]
    async fn search_matches_words_and_ranks() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute("INSERT INTO memories (id, project_id, kind, text, text_key) VALUES ('m5', 'pa', 'gotcha', 'Signing uses team 233QTK6KCL; signing breaks without it', 'k5')", [])
            .unwrap();
        let (status, r) = get(&pool, "/api/memories?q=signing%20team&project_id=pa").await;
        assert_eq!(status, StatusCode::OK, "{r}");
        let ids: Vec<&str> = r.as_array().unwrap().iter().map(|m| m["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["m5", "m1"], "best match first; any word matches");
        let (_, r) = get(&pool, "/api/memories?q=sign").await;
        assert_eq!(r.as_array().unwrap().len(), 2, "words match as prefixes");
    }

    #[actix_web::test]
    async fn search_quotes_fts_syntax() {
        let (_db, pool) = pool("usage");
        seed(&pool.get().unwrap());
        let (status, r) = get(&pool, "/api/memories?q=keychain%22%20OR%20(NEAR*").await;
        assert_eq!(status, StatusCode::OK, "{r}");
        assert_eq!(r.as_array().unwrap().len(), 1);
        let (status, r) = get(&pool, "/api/memories?q=%22%22").await;
        assert_eq!((status, r), (StatusCode::OK, json!([])), "nothing searchable finds nothing");
    }

    #[actix_web::test]
    async fn search_include_unused_after_live() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        conn.execute_batch(
            "INSERT INTO memories (id, project_id, kind, text, text_key) VALUES ('live', 'pa', 'gotcha', 'keychain once', 'kl');
             INSERT INTO memories (id, project_id, kind, text, text_key, archived, archived_reason) VALUES
                 ('old', 'pa', 'gotcha', 'keychain keychain keychain', 'ko', 1, 'unused'),
                 ('dup', 'pa', 'gotcha', 'keychain duplicate', 'kd', 1, 'duplicate');",
        )
        .unwrap();
        let (_, r) = get(&pool, "/api/memories?q=keychain&include_unused=true").await;
        let ids: Vec<&str> = r.as_array().unwrap().iter().map(|m| m["id"].as_str().unwrap()).collect();
        assert_eq!(ids.last(), Some(&"old"), "{ids:?}");
        assert!(!ids.contains(&"dup"));
        let (_, r) = get(&pool, "/api/memories?q=keychain").await;
        assert!(!r.as_array().unwrap().iter().any(|m| m["id"] == "old"));
    }
}
