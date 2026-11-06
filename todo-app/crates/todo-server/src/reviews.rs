//! Reviews of a conversation's changes: reviewer agent runs and review items (the user's
//! comments and the reviewers' findings). The app runs reviews on the conversation's computer
//! and keeps the results here, so every device sees them; the hub only stores them.
//!
//! Rows are written whole by id (`POST /api/reviews/batch`), as the Mac's review window keeps
//! them; the phone changes an item's state with `PATCH /api/review-items/{id}` (Send, Dismiss).
//! A conversation id is `conversations.id`, kept as text: reviews outlive a conversation row
//! that is replaced (relinking), and go only when deleted here.

use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection, OptionalExtension, Row};
use todo_shared::{
    DeleteResponse, Review, ReviewBatchRequest, ReviewItem, ReviewRecord, ReviewSummary, ReviewUsage,
    UpdateReviewItemRequest,
};

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, not_found, server_error};
use crate::db::DbPool;

/// v30: reviews and review items (additive).
pub(crate) const V30_OBJECTS: &str = "
    CREATE TABLE IF NOT EXISTS reviews (
        id              TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        tool            TEXT NOT NULL,
        model           TEXT,
        scope           TEXT NOT NULL,
        base_sha        TEXT NOT NULL,
        reviewed_sha    TEXT NOT NULL,
        state           TEXT NOT NULL CHECK(state IN ('running','done','failed','cancelled')),
        started_at      TEXT NOT NULL,
        finished_at     TEXT,
        summary         TEXT,
        error           TEXT,
        usage           TEXT,
        finding_count   INTEGER,
        added_count     INTEGER,
        created_at      TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS reviews_conversation ON reviews(conversation_id);
    CREATE TABLE IF NOT EXISTS review_items (
        id              TEXT PRIMARY KEY,
        review_id       TEXT,
        conversation_id TEXT NOT NULL,
        author          TEXT NOT NULL,
        fingerprint     TEXT,
        severity        TEXT,
        category        TEXT,
        title           TEXT,
        path            TEXT NOT NULL,
        side            TEXT NOT NULL CHECK(side IN ('new','old')),
        line_start      INTEGER,
        line_end        INTEGER,
        revision        TEXT NOT NULL,
        quote           TEXT NOT NULL DEFAULT '[]',
        body            TEXT NOT NULL,
        state           TEXT NOT NULL CHECK(state IN ('new','draft','sent','addressed','stale','dismissed')),
        sent_at         TEXT,
        sent_in_turn    INTEGER,
        batch_id        TEXT,
        sent_revision   TEXT,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS review_items_conversation ON review_items(conversation_id);
";

const STATES: [&str; 6] = ["new", "draft", "sent", "addressed", "stale", "dismissed"];
const RUN_STATES: [&str; 4] = ["running", "done", "failed", "cancelled"];
const MAX_TEXT: usize = 20_000;
const MAX_SHORT: usize = 500;
const MAX_QUOTE: usize = 200;
const MAX_BATCH: usize = 5_000;
/// A run older than this that never finished (its window closed) no longer counts as going.
const REVIEWING_MINUTES: i64 = 45;

const REVIEW_COLS: &str = "id, conversation_id, tool, model, scope, base_sha, reviewed_sha, state, started_at, \
    finished_at, summary, error, usage, finding_count, added_count, created_at, updated_at";
const ITEM_COLS: &str = "id, review_id, conversation_id, author, fingerprint, severity, category, title, path, side, \
    line_start, line_end, revision, quote, body, state, sent_at, sent_in_turn, batch_id, sent_revision, created_at, updated_at";

fn row_to_review(row: &Row) -> rusqlite::Result<Review> {
    let usage: Option<String> = row.get(12)?;
    Ok(Review {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        tool: row.get(2)?,
        model: row.get(3)?,
        scope: row.get(4)?,
        base_sha: row.get(5)?,
        reviewed_sha: row.get(6)?,
        state: row.get(7)?,
        started_at: row.get(8)?,
        finished_at: row.get(9)?,
        summary: row.get(10)?,
        error: row.get(11)?,
        usage: usage.and_then(|u| serde_json::from_str::<ReviewUsage>(&u).ok()),
        finding_count: row.get(13)?,
        added_count: row.get(14)?,
        created_at: row.get(15)?,
        updated_at: row.get(16)?,
    })
}

fn row_to_item(row: &Row) -> rusqlite::Result<ReviewItem> {
    let quote: String = row.get(13)?;
    Ok(ReviewItem {
        id: row.get(0)?,
        review_id: row.get(1)?,
        conversation_id: row.get(2)?,
        author: row.get(3)?,
        fingerprint: row.get(4)?,
        severity: row.get(5)?,
        category: row.get(6)?,
        title: row.get(7)?,
        path: row.get(8)?,
        side: row.get(9)?,
        line_start: row.get(10)?,
        line_end: row.get(11)?,
        revision: row.get(12)?,
        quote: serde_json::from_str(&quote).unwrap_or_default(),
        body: row.get(14)?,
        state: row.get(15)?,
        sent_at: row.get(16)?,
        sent_in_turn: row.get(17)?,
        batch_id: row.get(18)?,
        sent_revision: row.get(19)?,
        created_at: row.get(20)?,
        updated_at: row.get(21)?,
    })
}

pub(crate) fn record_db(conn: &Connection, conversation_id: &str) -> rusqlite::Result<ReviewRecord> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {REVIEW_COLS} FROM reviews WHERE conversation_id = ?1 ORDER BY started_at, rowid"
    ))?;
    let reviews = stmt.query_map(params![conversation_id], row_to_review)?.collect::<Result<_, _>>()?;
    let mut stmt = conn.prepare(&format!(
        "SELECT {ITEM_COLS} FROM review_items WHERE conversation_id = ?1 ORDER BY created_at, rowid"
    ))?;
    let items = stmt.query_map(params![conversation_id], row_to_item)?.collect::<Result<_, _>>()?;
    Ok(ReviewRecord { reviews, items })
}

pub(crate) fn summaries_db(conn: &Connection) -> rusqlite::Result<Vec<ReviewSummary>> {
    let mut stmt = conn.prepare(&format!(
        "WITH ids AS (SELECT conversation_id FROM reviews UNION SELECT conversation_id FROM review_items)
         SELECT ids.conversation_id,
                (SELECT COUNT(*) FROM review_items i
                  WHERE i.conversation_id = ids.conversation_id AND i.state IN ('new', 'draft')),
                EXISTS (SELECT 1 FROM reviews r WHERE r.conversation_id = ids.conversation_id AND r.state = 'running'
                         AND r.created_at >= datetime('now', '-{REVIEWING_MINUTES} minutes')),
                (SELECT MAX(r.started_at) FROM reviews r
                  WHERE r.conversation_id = ids.conversation_id AND r.state = 'done')
         FROM ids ORDER BY ids.conversation_id"
    ))?;
    let rows = stmt.query_map([], |r| {
        Ok(ReviewSummary {
            conversation_id: r.get(0)?,
            open: r.get(1)?,
            reviewing: r.get::<_, i64>(2)? != 0,
            last_reviewed_at: r.get(3)?,
        })
    })?;
    rows.collect()
}

fn check_len(value: &str, max: usize, what: &str) -> Result<(), String> {
    if value.chars().count() > max {
        return Err(format!("{what} is longer than {max} characters"));
    }
    Ok(())
}

fn check_required(value: &str, what: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{what} is required"));
    }
    check_len(value, MAX_SHORT, what)
}

fn validate_review(review: &Review) -> Result<(), String> {
    for (value, what) in [
        (&review.id, "id"),
        (&review.conversation_id, "conversation_id"),
        (&review.tool, "tool"),
        (&review.scope, "scope"),
        (&review.base_sha, "base_sha"),
        (&review.reviewed_sha, "reviewed_sha"),
        (&review.started_at, "started_at"),
    ] {
        check_required(value, what)?;
    }
    if !RUN_STATES.contains(&review.state.as_str()) {
        return Err("state must be running, done, failed or cancelled".into());
    }
    for (value, what) in [(&review.summary, "summary"), (&review.error, "error")] {
        if let Some(value) = value {
            check_len(value, MAX_TEXT, what)?;
        }
    }
    Ok(())
}

fn validate_item(item: &ReviewItem) -> Result<(), String> {
    for (value, what) in [
        (&item.id, "id"),
        (&item.conversation_id, "conversation_id"),
        (&item.author, "author"),
        (&item.path, "path"),
        (&item.revision, "revision"),
        (&item.created_at, "created_at"),
    ] {
        check_required(value, what)?;
    }
    if !STATES.contains(&item.state.as_str()) {
        return Err(format!("state must be one of {}", STATES.join(", ")));
    }
    if item.side != "new" && item.side != "old" {
        return Err("side must be new or old".into());
    }
    if item.body.trim().is_empty() {
        return Err("body is required".into());
    }
    check_len(&item.body, MAX_TEXT, "body")?;
    if item.quote.len() > MAX_QUOTE {
        return Err(format!("quote has more than {MAX_QUOTE} lines"));
    }
    if let (Some(start), Some(end)) = (item.line_start, item.line_end) {
        if start < 1 || end < start {
            return Err("line_end must not be before line_start".into());
        }
    }
    Ok(())
}

fn upsert_review(conn: &Connection, review: &Review) -> rusqlite::Result<()> {
    let usage = review.usage.as_ref().and_then(|u| serde_json::to_string(u).ok());
    conn.execute(
        "INSERT INTO reviews (id, conversation_id, tool, model, scope, base_sha, reviewed_sha, state, started_at,
             finished_at, summary, error, usage, finding_count, added_count)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
         ON CONFLICT(id) DO UPDATE SET conversation_id = excluded.conversation_id, tool = excluded.tool,
             model = excluded.model, scope = excluded.scope, base_sha = excluded.base_sha,
             reviewed_sha = excluded.reviewed_sha, state = excluded.state, started_at = excluded.started_at,
             finished_at = excluded.finished_at, summary = excluded.summary, error = excluded.error,
             usage = excluded.usage, finding_count = excluded.finding_count, added_count = excluded.added_count,
             updated_at = datetime('now')",
        params![
            review.id, review.conversation_id, review.tool, review.model, review.scope, review.base_sha,
            review.reviewed_sha, review.state, review.started_at, review.finished_at, review.summary, review.error,
            usage, review.finding_count, review.added_count
        ],
    )?;
    Ok(())
}

fn upsert_item(conn: &Connection, item: &ReviewItem) -> rusqlite::Result<()> {
    let quote = serde_json::to_string(&item.quote).unwrap_or_else(|_| "[]".into());
    conn.execute(
        "INSERT INTO review_items (id, review_id, conversation_id, author, fingerprint, severity, category, title,
             path, side, line_start, line_end, revision, quote, body, state, sent_at, sent_in_turn, batch_id,
             sent_revision, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
         ON CONFLICT(id) DO UPDATE SET review_id = excluded.review_id, conversation_id = excluded.conversation_id,
             author = excluded.author, fingerprint = excluded.fingerprint, severity = excluded.severity,
             category = excluded.category, title = excluded.title, path = excluded.path, side = excluded.side,
             line_start = excluded.line_start, line_end = excluded.line_end, revision = excluded.revision,
             quote = excluded.quote, body = excluded.body, state = excluded.state, sent_at = excluded.sent_at,
             sent_in_turn = excluded.sent_in_turn, batch_id = excluded.batch_id,
             sent_revision = excluded.sent_revision, created_at = excluded.created_at,
             updated_at = datetime('now')",
        params![
            item.id, item.review_id, item.conversation_id, item.author, item.fingerprint, item.severity,
            item.category, item.title, item.path, item.side, item.line_start, item.line_end, item.revision, quote,
            item.body, item.state, item.sent_at, item.sent_in_turn, item.batch_id, item.sent_revision,
            item.created_at
        ],
    )?;
    Ok(())
}

pub(crate) enum ReviewError {
    BadRequest(String),
    NotFound(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for ReviewError {
    fn from(e: rusqlite::Error) -> Self {
        ReviewError::Db(e)
    }
}

fn respond(e: ReviewError) -> HttpResponse {
    match e {
        ReviewError::BadRequest(m) => bad_request(&m),
        ReviewError::NotFound(m) => not_found(m),
        ReviewError::Db(e) => server_error(e),
    }
}

/// Validates everything first, then writes it in one transaction: all or nothing.
pub(crate) fn batch_db(conn: &Connection, req: &ReviewBatchRequest) -> Result<(), ReviewError> {
    let total = req.reviews.len() + req.items.len() + req.delete_reviews.len() + req.delete_items.len();
    if total > MAX_BATCH {
        return Err(ReviewError::BadRequest(format!("a batch holds at most {MAX_BATCH} changes")));
    }
    for review in &req.reviews {
        validate_review(review).map_err(ReviewError::BadRequest)?;
    }
    for item in &req.items {
        validate_item(item).map_err(ReviewError::BadRequest)?;
    }
    let tx = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    for review in &req.reviews {
        upsert_review(&tx, review)?;
    }
    for item in &req.items {
        upsert_item(&tx, item)?;
    }
    for id in &req.delete_items {
        tx.execute("DELETE FROM review_items WHERE id = ?1", params![id])?;
    }
    for id in &req.delete_reviews {
        tx.execute("DELETE FROM reviews WHERE id = ?1", params![id])?;
    }
    tx.commit()?;
    Ok(())
}

fn load_item(conn: &Connection, id: &str) -> rusqlite::Result<Option<ReviewItem>> {
    conn.query_row(&format!("SELECT {ITEM_COLS} FROM review_items WHERE id = ?1"), params![id], row_to_item)
        .optional()
}

fn load_review(conn: &Connection, id: &str) -> rusqlite::Result<Option<Review>> {
    conn.query_row(&format!("SELECT {REVIEW_COLS} FROM reviews WHERE id = ?1"), params![id], row_to_review)
        .optional()
}

pub(crate) fn update_item_db(conn: &Connection, id: &str, req: &UpdateReviewItemRequest) -> Result<ReviewItem, ReviewError> {
    let mut item = load_item(conn, id)?.ok_or(ReviewError::NotFound("Review item not found"))?;
    if let Some(state) = &req.state {
        item.state = state.clone();
    }
    if let Some(body) = &req.body {
        item.body = body.trim().to_string();
    }
    if req.sent_at.is_some() {
        item.sent_at = req.sent_at.clone();
    }
    if req.sent_in_turn.is_some() {
        item.sent_in_turn = req.sent_in_turn;
    }
    if req.batch_id.is_some() {
        item.batch_id = req.batch_id.clone();
    }
    if req.sent_revision.is_some() {
        item.sent_revision = req.sent_revision.clone();
    }
    validate_item(&item).map_err(ReviewError::BadRequest)?;
    upsert_item(conn, &item)?;
    load_item(conn, id)?.ok_or(ReviewError::NotFound("Review item not found"))
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

/// `GET /api/reviews?conversation_id=X`: that conversation's runs and items.
pub async fn list_reviews(pool: web::Data<DbPool>, query: web::Query<std::collections::HashMap<String, String>>) -> HttpResponse {
    let Some(conversation_id) = query.get("conversation_id").filter(|c| !c.is_empty()) else {
        return bad_request("conversation_id is required");
    };
    let conn = conn!(pool);
    match record_db(&conn, conversation_id) {
        Ok(record) => HttpResponse::Ok().json(record),
        Err(e) => server_error(e),
    }
}

pub async fn review_summaries(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    match summaries_db(&conn) {
        Ok(summaries) => HttpResponse::Ok().json(summaries),
        Err(e) => server_error(e),
    }
}

pub async fn batch(pool: web::Data<DbPool>, body: web::Json<ReviewBatchRequest>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match batch_db(&conn, &body) {
        Ok(()) => {
            broadcaster.send();
            HttpResponse::Ok().json(serde_json::json!({ "ok": true }))
        }
        Err(e) => respond(e),
    }
}

/// `POST /api/reviews`: one run, upserted by id.
pub async fn put_review(pool: web::Data<DbPool>, body: web::Json<Review>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    let req = ReviewBatchRequest { reviews: vec![body.into_inner()], ..Default::default() };
    if let Err(e) = batch_db(&conn, &req) {
        return respond(e);
    }
    broadcaster.send();
    match load_review(&conn, &req.reviews[0].id) {
        Ok(Some(review)) => HttpResponse::Ok().json(review),
        Ok(None) => not_found("Review not found"),
        Err(e) => server_error(e),
    }
}

/// `POST /api/review-items`: one item, upserted by id.
pub async fn put_item(pool: web::Data<DbPool>, body: web::Json<ReviewItem>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    let req = ReviewBatchRequest { items: vec![body.into_inner()], ..Default::default() };
    if let Err(e) = batch_db(&conn, &req) {
        return respond(e);
    }
    broadcaster.send();
    match load_item(&conn, &req.items[0].id) {
        Ok(Some(item)) => HttpResponse::Ok().json(item),
        Ok(None) => not_found("Review item not found"),
        Err(e) => server_error(e),
    }
}

pub async fn update_item(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<UpdateReviewItemRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = conn!(pool);
    match update_item_db(&conn, &path, &body) {
        Ok(item) => {
            broadcaster.send();
            HttpResponse::Ok().json(item)
        }
        Err(e) => respond(e),
    }
}

pub async fn delete_item(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match conn.execute("DELETE FROM review_items WHERE id = ?1", params![path.as_str()]) {
        Ok(0) => not_found("Review item not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: path.into_inner() })
        }
        Err(e) => server_error(e),
    }
}

/// Deletes a run; its findings stay (they may have been sent).
pub async fn delete_review(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    match conn.execute("DELETE FROM reviews WHERE id = ?1", params![path.as_str()]) {
        Ok(0) => not_found("Review not found"),
        Ok(_) => {
            broadcaster.send();
            HttpResponse::Ok().json(DeleteResponse { deleted: path.into_inner() })
        }
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use serde_json::{json, Value};

    use crate::test_support::{delete, get, patch, pool, post};

    fn item(id: &str, state: &str) -> Value {
        json!({
            "id": id, "conversation_id": "c1", "author": "reviewer:claude", "fingerprint": format!("fp-{id}"),
            "severity": "high", "category": "correctness", "title": "Off by one", "path": "src/a.rs", "side": "new",
            "line_start": 3, "line_end": 4, "revision": "abc", "quote": ["x < n", "y"], "body": "Use <=.",
            "state": state, "review_id": "r1", "created_at": "2026-11-06T20:00:00Z"
        })
    }

    fn review(state: &str) -> Value {
        json!({
            "id": "r1", "conversation_id": "c1", "tool": "claude", "model": "m", "scope": "uncommitted",
            "base_sha": "b", "reviewed_sha": "abc", "state": state, "started_at": "2026-11-06T20:00:00Z",
            "usage": {"input_tokens": 10, "output_tokens": 20, "cost_usd": 0.5}, "finding_count": 2
        })
    }

    #[actix_web::test]
    async fn batch_writes_and_lists_a_conversations_review() {
        let (_db, pool) = pool("reviews_batch");
        let (status, v) = post(&pool, "/api/reviews/batch",
            json!({"reviews": [review("running")], "items": [item("i1", "new"), item("i2", "draft")]})).await;
        assert_eq!(status, StatusCode::OK, "{v}");
        let (status, v) = get(&pool, "/api/reviews?conversation_id=c1").await;
        assert_eq!(status, StatusCode::OK, "{v}");
        assert_eq!(v["reviews"][0]["usage"]["cost_usd"], 0.5);
        assert_eq!(v["reviews"][0]["state"], "running");
        assert_eq!(v["items"].as_array().unwrap().len(), 2);
        assert_eq!(v["items"][0]["quote"], json!(["x < n", "y"]));
        assert_eq!(v["items"][0]["line_end"], 4);
        // The same ids again replace the rows; deletes go in the same batch.
        let mut done = review("done");
        done["finished_at"] = json!("2026-11-06T20:05:00Z");
        let mut sent = item("i2", "sent");
        sent["batch_id"] = json!("b1");
        sent["sent_in_turn"] = json!(7);
        let (status, _) = post(&pool, "/api/reviews/batch",
            json!({"reviews": [done], "items": [sent], "delete_items": ["i1"]})).await;
        assert_eq!(status, StatusCode::OK);
        let (_, v) = get(&pool, "/api/reviews?conversation_id=c1").await;
        assert_eq!(v["reviews"][0]["state"], "done");
        assert_eq!(v["items"].as_array().unwrap().len(), 1);
        assert_eq!(v["items"][0]["state"], "sent");
        assert_eq!(v["items"][0]["sent_in_turn"], 7);
        let (_, v) = get(&pool, "/api/reviews?conversation_id=other").await;
        assert_eq!(v, json!({"reviews": [], "items": []}));
        let (status, _) = get(&pool, "/api/reviews").await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn a_bad_row_rejects_the_whole_batch() {
        let (_db, pool) = pool("reviews_bad");
        let mut bad = item("i2", "new");
        bad["side"] = json!("left");
        let (status, v) = post(&pool, "/api/reviews/batch", json!({"items": [item("i1", "new"), bad]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{v}");
        let mut bad = item("i3", "maybe");
        bad["side"] = json!("new");
        let (status, _) = post(&pool, "/api/reviews/batch", json!({"items": [bad]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let mut empty = item("i4", "new");
        empty["body"] = json!("  ");
        let (status, _) = post(&pool, "/api/reviews/batch", json!({"items": [empty]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (_, v) = get(&pool, "/api/reviews?conversation_id=c1").await;
        assert_eq!(v["items"], json!([]));
    }

    #[actix_web::test]
    async fn the_phone_sends_and_dismisses_items() {
        let (_db, pool) = pool("reviews_patch");
        post(&pool, "/api/review-items", item("i1", "new")).await;
        let (status, v) = patch(&pool, "/api/review-items/i1",
            json!({"state": "sent", "sent_at": "2026-11-06T21:00:00Z", "sent_in_turn": 3, "batch_id": "b9", "sent_revision": "abc"})).await;
        assert_eq!(status, StatusCode::OK, "{v}");
        assert_eq!((v["state"].as_str(), v["batch_id"].as_str(), v["title"].as_str()), (Some("sent"), Some("b9"), Some("Off by one")));
        let (status, _) = patch(&pool, "/api/review-items/i1", json!({"state": "gone"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _) = patch(&pool, "/api/review-items/nope", json!({"state": "dismissed"})).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (status, _) = delete(&pool, "/api/review-items/i1").await;
        assert_eq!(status, StatusCode::OK);
        let (status, _) = delete(&pool, "/api/review-items/i1").await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn summaries_count_open_items_and_running_reviews() {
        let (_db, pool) = pool("reviews_summary");
        post(&pool, "/api/reviews", review("running")).await;
        let mut other = item("i3", "new");
        other["conversation_id"] = json!("c2");
        post(&pool, "/api/reviews/batch",
            json!({"items": [item("i1", "new"), item("i2", "draft"), item("i4", "dismissed"), item("i5", "sent"), other]})).await;
        let (status, v) = get(&pool, "/api/reviews/summary").await;
        assert_eq!(status, StatusCode::OK, "{v}");
        assert_eq!(v, json!([
            {"conversation_id": "c1", "open": 2, "reviewing": true, "last_reviewed_at": null},
            {"conversation_id": "c2", "open": 1, "reviewing": false, "last_reviewed_at": null},
        ]));
        post(&pool, "/api/reviews", review("done")).await;
        // A run left running long ago (its window closed) isn't "reviewing" any more.
        let conn = pool.get().unwrap();
        conn.execute_batch("INSERT INTO reviews (id, conversation_id, tool, scope, base_sha, reviewed_sha, state, started_at, created_at)
            VALUES ('old', 'c2', 'codex', 'branch', 'b', 'h', 'running', '2026-01-01T00:00:00Z', datetime('now', '-2 hours'));").unwrap();
        let (_, v) = get(&pool, "/api/reviews/summary").await;
        assert_eq!(v[0]["reviewing"], false);
        assert_eq!(v[0]["last_reviewed_at"], "2026-11-06T20:00:00Z");
        assert_eq!(v[1]["reviewing"], false);
        let (status, _) = delete(&pool, "/api/reviews/r1").await;
        assert_eq!(status, StatusCode::OK);
        let (_, v) = get(&pool, "/api/reviews?conversation_id=c1").await;
        assert_eq!(v["items"].as_array().unwrap().len(), 4, "a deleted run's items stay");
    }
}
