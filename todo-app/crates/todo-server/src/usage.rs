//! Usage of a todo or a job: what its conversations used themselves and what their workers
//! (sub-agents, internal threads) used, by model, with active and elapsed time.
//!
//! Computers upload the numbers (`POST /api/sessions/stats`); this only sums them. A todo's
//! conversations are `conversations.todo_id`; a job's are those of its runs' todos.
//! Heaviest first means output + cache-creation tokens: cache reads are cheap and make up
//! most of the input, so raw totals would rank the wrong thing. Never a price.

use std::collections::{BTreeMap, BTreeSet};

use actix_web::{web, HttpResponse};
use chrono::DateTime;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use todo_shared::{
    ConversationUsage, JobUsage, ModelTokens, ModelUsage, RunUsage, StatsCounters, TodoUsage, UsageReading,
    UsageSummary, WorkerTypeUsage,
};

use crate::conversations::{not_found, server_error};
use crate::db::DbPool;
use crate::sessions::StatsCountersExt;

const DEFAULT_RUNS: usize = 20;
const MAX_RUNS: usize = 200;

fn add_opt(total: &mut Option<i64>, value: Option<i64>) {
    if let Some(value) = value {
        *total = Some(total.unwrap_or(0) + value);
    }
}

/// Output + cache-creation tokens: what eats limits.
fn weight(output: Option<i64>, cache_creation: Option<i64>) -> i64 {
    output.unwrap_or(0) + cache_creation.unwrap_or(0)
}

fn seconds_between(first: &str, last: &str) -> Option<i64> {
    let first = DateTime::parse_from_rfc3339(first).ok()?;
    let last = DateTime::parse_from_rfc3339(last).ok()?;
    Some((last - first).num_seconds().max(0))
}

/// Keep the earlier (`earliest`) or later timestamp of two ISO 8601 times. Unparsable ones lose.
fn pick_time(current: &mut Option<String>, candidate: Option<String>, earliest: bool) {
    let Some(candidate) = candidate else { return };
    let Ok(c) = DateTime::parse_from_rfc3339(&candidate) else { return };
    let better = match current.as_deref().map(DateTime::parse_from_rfc3339) {
        Some(Ok(cur)) => if earliest { c < cur } else { c > cur },
        _ => true,
    };
    if better {
        *current = Some(candidate);
    }
}

fn counters_from(r: &rusqlite::Row, at: usize) -> rusqlite::Result<StatsCounters> {
    Ok(StatsCounters {
        sessions: r.get::<_, Option<i64>>(at)?.unwrap_or(0),
        prompts: r.get::<_, Option<i64>>(at + 1)?.unwrap_or(0),
        assistant_turns: r.get::<_, Option<i64>>(at + 2)?.unwrap_or(0),
        input_tokens: r.get(at + 3)?,
        output_tokens: r.get(at + 4)?,
        cache_read_tokens: r.get(at + 5)?,
        cache_creation_tokens: r.get(at + 6)?,
        active_seconds: r.get::<_, Option<i64>>(at + 7)?.unwrap_or(0),
        files_touched: r.get::<_, Option<i64>>(at + 8)?.unwrap_or(0),
    })
}

/// Usage of the conversations of these todos. Each session is counted once even when it
/// shows up twice.
pub(crate) fn usage_for_todos(conn: &Connection, todo_ids: &[String]) -> rusqlite::Result<UsageSummary> {
    let mut summary = UsageSummary::default();
    if todo_ids.is_empty() {
        return Ok(summary);
    }
    let marks = vec!["?"; todo_ids.len()].join(",");
    let mut stmt = conn.prepare(&format!(
        "SELECT c.id, c.todo_id, c.tool, c.session_id, c.computer_id, c.label, s.title, s.stats_updated_at,
                s.first_activity, s.last_activity,
                CASE WHEN s.stats_updated_at IS NULL THEN 0 ELSE 1 END, s.prompts, s.assistant_turns,
                s.input_tokens, s.output_tokens, s.cache_read_tokens, s.cache_creation_tokens, s.active_seconds,
                json_array_length(s.files_touched)
         FROM conversations c
         LEFT JOIN sessions s ON s.tool = c.tool AND s.session_id = c.session_id
         WHERE c.todo_id IN ({marks})
         ORDER BY c.created_at, c.id"
    ))?;
    let rows = stmt.query_map(params_from_iter(todo_ids), |r| {
        let tool: String = r.get(2)?;
        let session_id: Option<String> = r.get(3)?;
        let uploaded: Option<String> = r.get(7)?;
        let reading = if tool == "cursor" {
            UsageReading::Cursor
        } else if session_id.is_none() {
            UsageReading::NoSession
        } else if uploaded.is_none() {
            UsageReading::NotUploaded
        } else {
            UsageReading::Uploaded
        };
        let own = if reading == UsageReading::Uploaded { counters_from(r, 10)? } else { StatsCounters::default() };
        Ok(ConversationUsage {
            conversation_id: r.get(0)?,
            todo_id: r.get(1)?,
            tool,
            session_id,
            computer_id: r.get(4)?,
            label: r.get(5)?,
            title: r.get(6)?,
            reading,
            own,
            workers: StatsCounters::default(),
            first_activity: r.get(8)?,
            last_activity: r.get(9)?,
            stats_updated_at: uploaded,
        })
    })?;
    let mut conversations = rows.collect::<rusqlite::Result<Vec<_>>>()?;

    let mut seen = BTreeSet::new();
    let mut sessions: Vec<(String, String)> = Vec::new();
    for c in &mut conversations {
        let (UsageReading::Uploaded, Some(session_id)) = (c.reading, c.session_id.clone()) else {
            summary.unread_conversations += 1;
            continue;
        };
        let key = (c.tool.clone(), session_id);
        if !seen.insert(key.clone()) {
            continue;
        }
        let (workers, first, last): (StatsCounters, Option<String>, Option<String>) = conn.query_row(
            "SELECT COUNT(*), SUM(prompts), SUM(assistant_turns), SUM(input_tokens), SUM(output_tokens),
                    SUM(cache_read_tokens), SUM(cache_creation_tokens), SUM(active_seconds), SUM(files_touched),
                    MIN(first_activity), MAX(last_activity)
             FROM session_workers WHERE tool = ?1 AND session_id = ?2",
            params![key.0, key.1],
            |r| Ok((counters_from(r, 0)?, r.get(9)?, r.get(10)?)),
        )?;
        c.workers = workers;
        summary.own.add(&c.own);
        summary.workers.add(&c.workers);
        let mut first_c = None;
        let mut last_c = None;
        for t in [c.first_activity.clone(), first] {
            pick_time(&mut first_c, t, true);
        }
        for t in [c.last_activity.clone(), last] {
            pick_time(&mut last_c, t, false);
        }
        pick_time(&mut summary.first_activity, first_c, true);
        pick_time(&mut summary.last_activity, last_c, false);
        match (&summary.stats_updated_at, &c.stats_updated_at) {
            (Some(cur), Some(new)) if new < cur => summary.stats_updated_at = Some(new.clone()),
            (None, Some(new)) => summary.stats_updated_at = Some(new.clone()),
            _ => {}
        }
        sessions.push(key);
    }
    summary.elapsed_seconds = match (&summary.first_activity, &summary.last_activity) {
        (Some(first), Some(last)) => seconds_between(first, last),
        _ => None,
    };

    let mut models: BTreeMap<String, ModelTokens> = BTreeMap::new();
    let mut types: BTreeMap<(String, Option<String>), StatsCounters> = BTreeMap::new();
    for (tool, session_id) in &sessions {
        let mut stmt = conn.prepare_cached(
            "SELECT model, SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), SUM(cache_creation_tokens)
             FROM session_models WHERE tool = ?1 AND session_id = ?2 GROUP BY model",
        )?;
        let rows = stmt.query_map(params![tool, session_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                ModelTokens { input_tokens: r.get(1)?, output_tokens: r.get(2)?, cache_read_tokens: r.get(3)?, cache_creation_tokens: r.get(4)? },
            ))
        })?;
        for row in rows {
            let (model, t) = row?;
            let m = models.entry(model).or_default();
            add_opt(&mut m.input_tokens, t.input_tokens);
            add_opt(&mut m.output_tokens, t.output_tokens);
            add_opt(&mut m.cache_read_tokens, t.cache_read_tokens);
            add_opt(&mut m.cache_creation_tokens, t.cache_creation_tokens);
        }
        let mut stmt = conn.prepare_cached(
            "SELECT kind, worker_type, COUNT(*), SUM(prompts), SUM(assistant_turns), SUM(input_tokens), SUM(output_tokens),
                    SUM(cache_read_tokens), SUM(cache_creation_tokens), SUM(active_seconds), SUM(files_touched)
             FROM session_workers WHERE tool = ?1 AND session_id = ?2 GROUP BY kind, worker_type",
        )?;
        let rows = stmt.query_map(params![tool, session_id], |r| {
            Ok(((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?), counters_from(r, 2)?))
        })?;
        for row in rows {
            let (key, counters) = row?;
            types.entry(key).or_default().add(&counters);
        }
    }
    summary.by_model = models.into_iter().map(|(model, tokens)| ModelUsage { model, tokens }).collect();
    summary
        .by_model
        .sort_by_key(|m| (-weight(m.tokens.output_tokens, m.tokens.cache_creation_tokens), m.model.clone()));
    summary.worker_types = types
        .into_iter()
        .map(|((kind, worker_type), counters)| WorkerTypeUsage { kind, worker_type, counters })
        .collect();
    summary.worker_types.sort_by_key(|w| -weight(w.counters.output_tokens, w.counters.cache_creation_tokens));
    summary.conversations = conversations;
    Ok(summary)
}

pub(crate) fn todo_usage_db(conn: &Connection, todo_id: &str) -> rusqlite::Result<Option<TodoUsage>> {
    let exists = conn.query_row("SELECT 1 FROM todos WHERE id = ?1", params![todo_id], |_| Ok(())).optional()?;
    if exists.is_none() {
        return Ok(None);
    }
    let usage = usage_for_todos(conn, &[todo_id.to_string()])?;
    Ok(Some(TodoUsage { todo_id: todo_id.to_string(), usage }))
}

/// A job's usage over all its runs, and the newest `runs` runs one by one.
pub(crate) fn job_usage_db(conn: &Connection, job_id: &str, runs: usize) -> rusqlite::Result<Option<JobUsage>> {
    let exists = conn.query_row("SELECT 1 FROM jobs WHERE id = ?1", params![job_id], |_| Ok(())).optional()?;
    if exists.is_none() {
        return Ok(None);
    }
    let all: Vec<String> = conn
        .prepare("SELECT DISTINCT todo_id FROM job_runs WHERE job_id = ?1 AND todo_id IS NOT NULL")?
        .query_map(params![job_id], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let usage = usage_for_todos(conn, &all)?;
    let newest: Vec<(String, String, String, Option<String>)> = conn
        .prepare("SELECT id, due_at, state, todo_id FROM job_runs WHERE job_id = ?1 ORDER BY due_at DESC, id LIMIT ?2")?
        .query_map(params![job_id, i64::try_from(runs).unwrap_or(i64::MAX)], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })?
        .collect::<rusqlite::Result<_>>()?;
    let mut run_usage = Vec::with_capacity(newest.len());
    for (run_id, due_at, state, todo_id) in newest {
        let usage = usage_for_todos(conn, todo_id.as_slice())?;
        run_usage.push(RunUsage { run_id, due_at, state, todo_id, usage });
    }
    Ok(Some(JobUsage { job_id: job_id.to_string(), usage, runs: run_usage }))
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn todo_usage(pool: web::Data<DbPool>, path: web::Path<String>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match todo_usage_db(&conn, &path) {
        Ok(Some(usage)) => HttpResponse::Ok().json(usage),
        Ok(None) => not_found("Todo not found"),
        Err(e) => server_error(e),
    }
}

#[derive(Debug, serde::Deserialize)]
pub struct JobUsageQuery {
    /// How many of the newest runs to list one by one (default 20, at most 200)
    pub runs: Option<usize>,
}

pub async fn job_usage(pool: web::Data<DbPool>, path: web::Path<String>, query: web::Query<JobUsageQuery>) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match job_usage_db(&conn, &path, query.runs.unwrap_or(DEFAULT_RUNS).min(MAX_RUNS)) {
        Ok(Some(usage)) => HttpResponse::Ok().json(usage),
        Ok(None) => not_found("Job not found"),
        Err(e) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use actix_web::http::StatusCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};

    use crate::db::DbPool;
    use crate::test_support::{get, pool, post, seed_computers};

    fn tokens(input: i64, output: i64, read: i64, creation: Option<i64>) -> Value {
        json!({"input_tokens": input, "output_tokens": output, "cache_read_tokens": read, "cache_creation_tokens": creation})
    }

    fn stats(output: i64, active: i64, first: &str, last: &str) -> Value {
        json!({"prompts": 2, "assistant_turns": 3, "input_tokens": 10, "output_tokens": output, "cache_read_tokens": 1000,
               "cache_creation_tokens": 50, "active_seconds": active, "first_activity": first, "last_activity": last,
               "files_touched": ["a.rs", "b.rs"], "models": ["claude-opus-5-5"]})
    }

    fn worker(id: &str, kind: &str, kind_type: &str, output: i64, last: &str) -> Value {
        json!({"id": id, "kind": kind, "type": kind_type, "title": "Look around", "depth": 1,
               "stats": stats(output, 60, "2026-11-02T10:05:00Z", last),
               "days": [{"day": "2026-11-02", "prompts": 1, "assistant_turns": 2, "input_tokens": 1, "output_tokens": output,
                         "cache_read_tokens": 5, "cache_creation_tokens": 7, "active_seconds": 60, "files_touched": 0}],
               "by_model": {"claude-haiku-5-5": tokens(1, output, 5, Some(7))}})
    }

    fn session(id: &str, own_output: i64, workers: Option<Vec<Value>>) -> Value {
        let mut s = json!({"tool": "claude", "session_id": id, "cwd": "~/a", "title": "Do it",
            "stats": stats(own_output, 600, "2026-11-02T10:00:00Z", "2026-11-02T11:00:00Z"),
            "days": [{"day": "2026-11-02", "prompts": 2, "assistant_turns": 3, "input_tokens": 10, "output_tokens": own_output,
                      "cache_read_tokens": 1000, "cache_creation_tokens": 50, "active_seconds": 600, "files_touched": 2}],
            "by_model": {"claude-opus-5-5": tokens(10, own_output, 1000, Some(50))},
            "copied_entries_skipped": 4});
        if let Some(w) = workers {
            s["workers"] = json!(w);
        }
        s
    }

    async fn upload(pool: &DbPool, sessions: Vec<Value>) {
        let (status, body) = post(pool, "/api/sessions/stats", json!({"computer_id": "mac", "sessions": sessions})).await;
        assert_eq!(status, StatusCode::OK, "{body}");
    }

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'a', 'Si', '~/a');
             INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'one'), ('t2', 'Si', 'two'), ('t3', 'Si', 'empty');
             INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, created_at) VALUES
                 ('c1', 't1', 'mac', '~/a', 'claude', 'ai/1', 's1', '2026-11-02 10:00:00'),
                 ('c2', 't1', 'mac', '~/a', 'cursor', 'ai/2', 'cur', '2026-11-02 10:01:00'),
                 ('c3', 't1', 'mac', '~/a', 'codex', 'ai/3', NULL, '2026-11-02 10:02:00'),
                 ('c4', 't1', 'mac', '~/a', 'claude', 'ai/4', 'never', '2026-11-02 10:03:00'),
                 ('c5', 't2', 'mac', '~/a', 'claude', 'ai/5', 's2', '2026-11-02 10:04:00');",
        )
        .unwrap();
    }

    fn count(conn: &Connection, table: &str) -> i64 {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0)).unwrap()
    }

    #[actix_web::test]
    async fn upload_replaces_workers_and_keeps_them_when_absent() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        let two = vec![worker("w1", "agent", "Explore", 100, "2026-11-02T12:00:00Z"), worker("w2", "internal", "guardian", 5, "2026-11-02T10:30:00Z")];
        upload(&pool, vec![session("s1", 1000, Some(two.clone()))]).await;
        assert_eq!((count(&conn, "session_workers"), count(&conn, "session_worker_days"), count(&conn, "session_models")), (2, 2, 3));
        upload(&pool, vec![session("s1", 1000, Some(two))]).await;
        assert_eq!((count(&conn, "session_workers"), count(&conn, "session_worker_days"), count(&conn, "session_models")), (2, 2, 3), "idempotent");

        // An older collector sends no workers or models: what is stored stays.
        let mut old = session("s1", 1000, None);
        old.as_object_mut().unwrap().remove("by_model");
        upload(&pool, vec![old]).await;
        assert_eq!((count(&conn, "session_workers"), count(&conn, "session_models")), (2, 3));

        // An empty list replaces them.
        upload(&pool, vec![session("s1", 1000, Some(vec![]))]).await;
        assert_eq!((count(&conn, "session_workers"), count(&conn, "session_worker_days"), count(&conn, "session_models")), (0, 0, 1));
        let skipped: i64 = conn.query_row("SELECT copied_entries_skipped FROM sessions", [], |r| r.get(0)).unwrap();
        assert_eq!(skipped, 4);

        let mut bad = session("s1", 1, Some(vec![worker("w1", "robot", "x", 1, "2026-11-02T12:00:00Z")]));
        let (status, _) = post(&pool, "/api/sessions/stats", json!({"computer_id": "mac", "sessions": [bad.clone()]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "unknown kind");
        bad["workers"][0]["kind"] = json!("agent");
        bad["workers"][0]["days"][0]["day"] = json!("2026-02-30");
        let (status, _) = post(&pool, "/api/sessions/stats", json!({"computer_id": "mac", "sessions": [bad]})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "bad worker day");
    }

    #[actix_web::test]
    async fn todo_usage_sums_own_and_workers() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        upload(
            &pool,
            vec![
                session("s1", 1000, Some(vec![worker("w1", "agent", "Explore", 100, "2026-11-02T12:00:00Z"), worker("w2", "agent", "Explore", 300, "2026-11-02T10:30:00Z"), worker("w3", "internal", "guardian", 5, "2026-11-02T10:10:00Z")])),
                session("s2", 7, Some(vec![])),
            ],
        )
        .await;
        conn.execute("INSERT INTO sessions (tool, session_id, computer_id, cwd) VALUES ('claude', 'never', 'mac', '~/a')", []).unwrap();

        let (status, u) = get(&pool, "/api/todos/t1/usage").await;
        assert_eq!(status, StatusCode::OK, "{u}");
        assert_eq!(u["todo_id"], "t1");
        assert_eq!((&u["own"]["sessions"], &u["own"]["output_tokens"], &u["own"]["active_seconds"]), (&json!(1), &json!(1000), &json!(600)));
        assert_eq!((&u["workers"]["sessions"], &u["workers"]["output_tokens"]), (&json!(3), &json!(405)));
        assert_eq!(u["unread_conversations"], 3);
        let readings: Vec<&str> = u["conversations"].as_array().unwrap().iter().map(|c| c["reading"].as_str().unwrap()).collect();
        assert_eq!(readings, vec!["uploaded", "cursor", "no_session", "not_uploaded"]);
        assert_eq!(u["conversations"][0]["workers"]["output_tokens"], 405);
        assert_eq!(u["conversations"][3]["own"]["sessions"], 0, "no reading, no numbers");

        assert_eq!((&u["first_activity"], &u["last_activity"]), (&json!("2026-11-02T10:00:00Z"), &json!("2026-11-02T12:00:00Z")));
        assert_eq!(u["elapsed_seconds"], 7200, "a worker ran past the conversation");
        assert!(u["stats_updated_at"].is_string());

        // Heaviest (output + cache creation) first; the internal guardian is its own row.
        let models: Vec<(&str, i64)> = u["by_model"].as_array().unwrap().iter().map(|m| (m["model"].as_str().unwrap(), m["output_tokens"].as_i64().unwrap())).collect();
        assert_eq!(models, vec![("claude-opus-5-5", 1000), ("claude-haiku-5-5", 405)]);
        let types: Vec<(&str, &str, i64)> = u["worker_types"].as_array().unwrap().iter()
            .map(|w| (w["kind"].as_str().unwrap(), w["type"].as_str().unwrap(), w["sessions"].as_i64().unwrap())).collect();
        assert_eq!(types, vec![("agent", "Explore", 2), ("internal", "guardian", 1)]);

        let (_, empty) = get(&pool, "/api/todos/t3/usage").await;
        assert_eq!((&empty["own"]["sessions"], &empty["conversations"], &empty["elapsed_seconds"]), (&json!(0), &json!([]), &Value::Null));
        assert_eq!(get(&pool, "/api/todos/nope/usage").await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn job_usage_sums_runs() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        upload(&pool, vec![session("s1", 1000, Some(vec![worker("w1", "agent", "Explore", 100, "2026-11-02T12:00:00Z")])), session("s2", 7, None)]).await;
        conn.execute_batch(
            "INSERT INTO jobs (id, name, trigger, action) VALUES ('j1', 'Gardener', '{}', '{}'), ('j2', 'Idle', '{}', '{}');
             INSERT INTO job_runs (id, job_id, due_at, state, todo_id) VALUES
                 ('r1', 'j1', '2026-11-01T08:00:00Z', 'done', 't1'),
                 ('r2', 'j1', '2026-11-02T08:00:00Z', 'done', 't2'),
                 ('r3', 'j1', '2026-11-03T08:00:00Z', 'skipped', NULL);",
        )
        .unwrap();
        let (status, u) = get(&pool, "/api/jobs/j1/usage").await;
        assert_eq!(status, StatusCode::OK, "{u}");
        assert_eq!((&u["own"]["sessions"], &u["own"]["output_tokens"], &u["workers"]["output_tokens"]), (&json!(2), &json!(1007), &json!(100)));
        let runs: Vec<(&str, i64)> = u["runs"].as_array().unwrap().iter().map(|r| (r["run_id"].as_str().unwrap(), r["own"]["output_tokens"].as_i64().unwrap_or(0))).collect();
        assert_eq!(runs, vec![("r3", 0), ("r2", 7), ("r1", 1000)], "newest first");
        assert_eq!(u["runs"][2]["workers"]["output_tokens"], 100);
        let (_, one) = get(&pool, "/api/jobs/j1/usage?runs=1").await;
        assert_eq!((one["runs"].as_array().unwrap().len(), &one["own"]["sessions"]), (1, &json!(2)), "totals stay over all runs");
        let (_, idle) = get(&pool, "/api/jobs/j2/usage").await;
        assert_eq!((&idle["runs"], &idle["own"]["sessions"]), (&json!([]), &json!(0)));
        assert_eq!(get(&pool, "/api/jobs/nope/usage").await.0, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn weekly_includes_workers() {
        let (_db, pool) = pool("usage");
        let conn = pool.get().unwrap();
        seed(&conn);
        upload(&pool, vec![session("s1", 1000, Some(vec![worker("w1", "agent", "Explore", 100, "2026-11-02T12:00:00Z"), worker("w2", "agent", "Plan", 20, "2026-11-02T12:00:00Z")]))]).await;
        let (status, w) = get(&pool, "/api/stats/weekly?week_start=2026-11-02").await;
        assert_eq!(status, StatusCode::OK, "{w}");
        assert_eq!((&w["totals"]["sessions"], &w["totals"]["output_tokens"]), (&json!(1), &json!(1000)));
        assert_eq!((&w["workers"]["sessions"], &w["workers"]["output_tokens"], &w["workers"]["active_seconds"]), (&json!(2), &json!(120), &json!(120)));
        assert_eq!((&w["by_project"][0]["project_id"], &w["by_project"][0]["workers"]["output_tokens"]), (&json!("pa"), &json!(120)));
        assert_eq!(w["by_computer"][0]["workers"]["sessions"], 2);
        assert_eq!(w["by_section"][0]["workers"]["prompts"], 2);
        let (_, other) = get(&pool, "/api/stats/weekly?week_start=2026-10-26").await;
        assert_eq!(other["workers"]["sessions"], 0);
    }
}
