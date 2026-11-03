//! The hub clock: every minute it turns cron slots into runs, runs push and todo jobs
//! itself, and marks runs that waited too long as missed. Conversation runs are left `due`
//! for a Mac's runner (see runner_api.rs).

use chrono::{DateTime, Duration, NaiveDateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use todo_shared::{JobAction, JobTrigger, Section};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::cron;
use crate::db::DbPool;
use crate::push::apns::{Alert, PushKind};
use crate::push::PushNotifier;

/// A run still `due` or `waiting` this long after its slot is `missed`.
const MISSED_AFTER_HOURS: i64 = 24;
/// Slots further back than this are not looked at (a hub that was down for days).
const LOOKBACK_DAYS: i64 = 2;
/// A claimed run with no todo yet after this long is failed.
const STUCK_RUNNING_MINUTES: i64 = 15;

/// An enabled job as the clock reads it: id, name, trigger JSON, action JSON, daily cap,
/// last slot, created at.
type JobRow = (String, String, String, String, i64, Option<String>, String);

#[derive(Debug, Default)]
pub(crate) struct TickOutcome {
    /// Runs created (any action).
    pub created: Vec<String>,
    pub missed: Vec<String>,
    /// (title, body) of push jobs to send now.
    pub pushes: Vec<(String, String)>,
    /// Todos created by todo jobs.
    pub todos: Vec<String>,
}

impl TickOutcome {
    pub(crate) fn changed(&self) -> bool {
        !(self.created.is_empty() && self.missed.is_empty())
    }
}

/// One clock tick against the real database: create runs, then send the push jobs' pushes
/// (quiet, without sound, during quiet hours). Errors are logged; the clock keeps going.
pub(crate) async fn run_tick(pool: &DbPool, broadcaster: &Broadcaster, notifier: &PushNotifier) {
    let outcome = match pool.get().map_err(|e| e.to_string()).and_then(|c| tick_db(&c, Utc::now()).map_err(|e| e.to_string())) {
        Ok(outcome) => outcome,
        Err(e) => {
            println!("scheduler: tick failed: {e}");
            return;
        }
    };
    if outcome.changed() {
        broadcaster.send();
    }
    if outcome.pushes.is_empty() {
        return;
    }
    let passive = pool
        .get()
        .ok()
        .and_then(|c| crate::push::store::load_settings(&c).ok())
        .and_then(|s| s.quiet_hours)
        .is_some_and(|q| crate::push::policy::in_quiet_hours(&q, Utc::now()));
    for (title, body) in outcome.pushes {
        let alert = Alert { todo_id: None, session_id: None, title, subtitle: body, kind: PushKind::Scheduled, passive };
        notifier.send_to_devices(pool, &alert, None).await;
    }
}

pub(crate) fn sql_time(t: DateTime<Utc>) -> String {
    t.format("%Y-%m-%d %H:%M:%S").to_string()
}

pub(crate) fn parse_sql_time(s: &str) -> Option<DateTime<Utc>> {
    NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S").ok().map(|n| Utc.from_utc_datetime(&n))
}

/// The Sofia date of `t`, `YYYY-MM-DD`.
pub(crate) fn local_date(t: DateTime<Utc>) -> String {
    t.with_timezone(&cron::TZ).format("%Y-%m-%d").to_string()
}

/// `{name}` placeholders replaced by their values; unknown ones are left as they are.
pub(crate) fn render(template: &str, vars: &[(&str, &str)]) -> String {
    vars.iter().fold(template.to_string(), |text, (key, value)| text.replace(&format!("{{{key}}}"), value))
}

/// The latest cron slot in (`after`, `now`], if any.
fn latest_slot(cron: &cron::Cron, after: DateTime<Utc>, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let mut cursor = after.max(now - Duration::days(LOOKBACK_DAYS));
    let mut latest = None;
    while let Some(next) = cron.next_after(cursor, cron::TZ) {
        if next > now {
            break;
        }
        latest = Some(next);
        cursor = next;
    }
    latest
}

fn project_name_and_section(conn: &Connection, project_id: &str) -> rusqlite::Result<Option<(String, String)>> {
    conn.query_row("SELECT name, section FROM projects WHERE id = ?1", params![project_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
}

/// A todo carrying the scheduled marker. Returns its id.
pub(crate) fn insert_scheduled_todo(
    conn: &Connection,
    section: &str,
    title: &str,
    project_id: Option<&str>,
    job_id: &str,
    run_id: &str,
) -> rusqlite::Result<String> {
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO todos (id, section, title, project_id, scheduled_job_id, scheduled_run_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, section, title, project_id, job_id, run_id],
    )?;
    Ok(id)
}

pub(crate) fn tick_db(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<TickOutcome> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let mut out = TickOutcome::default();
    let stamp = sql_time(now);
    let cutoff = sql_time(now - Duration::hours(MISSED_AFTER_HOURS));
    {
        let mut stmt = tx.prepare(
            "UPDATE job_runs SET state = 'missed', updated_at = ?1 WHERE state IN ('due','waiting') AND due_at < ?2 RETURNING id",
        )?;
        out.missed = stmt.query_map(params![stamp, cutoff], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
    }
    // A run claimed but never started (runner killed, hub unreachable mid-start) fails after
    // 15 minutes instead of staying `running` forever.
    tx.execute(
        "UPDATE job_runs SET state = 'failed', result = 'the runner never started it', updated_at = ?1
         WHERE state = 'running' AND todo_id IS NULL AND updated_at < ?2",
        params![stamp, sql_time(now - Duration::minutes(STUCK_RUNNING_MINUTES))],
    )?;
    // An idea reserved by a run that will never start (missed, skipped, failed before its
    // conversation existed, or deleted with its job) goes back to the queue.
    tx.execute(
        "UPDATE ideas SET status = 'new', run_id = NULL, todo_id = NULL, updated_at = ?1
         WHERE status = 'researching' AND todo_id IS NULL AND run_id IS NOT NULL
           AND (run_id NOT IN (SELECT id FROM job_runs)
                OR run_id IN (SELECT id FROM job_runs WHERE state IN ('missed','skipped','failed')))",
        params![stamp],
    )?;

    let jobs: Vec<JobRow> = {
        let mut stmt = tx.prepare(
            "SELECT id, name, trigger, action, max_runs_per_day, last_slot_at, created_at FROM jobs WHERE enabled = 1",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    let today = local_date(now);
    let day_start = cron::TZ
        .from_local_datetime(&NaiveDateTime::parse_from_str(&format!("{today} 00:00:00"), "%Y-%m-%d %H:%M:%S").unwrap_or_default())
        .earliest()
        .map(|t| sql_time(t.with_timezone(&Utc)))
        .unwrap_or_else(|| stamp.clone());

    for (id, name, trigger, action, max_per_day, last_slot, created) in jobs {
        let Ok(JobTrigger::Cron { cron: expr }) = serde_json::from_str::<JobTrigger>(&trigger) else { continue };
        let Ok(action) = serde_json::from_str::<JobAction>(&action) else { continue };
        let Ok(parsed) = cron::parse(&expr) else { continue };
        let after = last_slot.as_deref().or(Some(created.as_str())).and_then(parse_sql_time).unwrap_or(now);
        let Some(slot) = latest_slot(&parsed, after, now) else { continue };
        tx.execute("UPDATE jobs SET last_slot_at = ?2 WHERE id = ?1", params![id, sql_time(slot)])?;

        let run_id = Uuid::new_v4().to_string();
        // A research slot with nothing to research is recorded, not queued.
        if let (true, Some(parts)) = (action.is_research(), action.conversation_parts()) {
            let has_idea: bool = tx.query_row(
                "SELECT EXISTS (SELECT 1 FROM ideas WHERE project_id = ?1 AND status = 'new' AND pending = 0)",
                params![parts.project_id],
                |r| r.get(0),
            )?;
            if !has_idea {
                tx.execute(
                    "INSERT INTO job_runs (id, job_id, due_at, state, result) VALUES (?1, ?2, ?3, 'skipped', 'no new ideas')",
                    params![run_id, id, sql_time(slot)],
                )?;
                out.created.push(run_id);
                continue;
            }
        }
        let today_runs: i64 = tx.query_row(
            "SELECT COUNT(*) FROM job_runs WHERE job_id = ?1 AND due_at >= ?2 AND state != 'skipped'",
            params![id, day_start],
            |r| r.get(0),
        )?;
        // A watcher checks on its own cron; the daily cap is for conversations.
        if today_runs >= max_per_day && !action.is_watch() {
            tx.execute(
                "INSERT INTO job_runs (id, job_id, due_at, state, result) VALUES (?1, ?2, ?3, 'skipped', 'daily run limit reached')",
                params![run_id, id, sql_time(slot)],
            )?;
            out.created.push(run_id);
            continue;
        }
        // One pending run per job: a newer slot replaces one still waiting for a runner, so a
        // Mac that slept through several slots starts the job once.
        tx.execute(
            "UPDATE job_runs SET state = 'skipped', result = 'superseded by a later slot', updated_at = ?2
             WHERE job_id = ?1 AND state IN ('due','waiting')",
            params![id, stamp],
        )?;
        tx.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state) VALUES (?1, ?2, ?3, 'due')",
            params![run_id, id, sql_time(slot)],
        )?;
        out.created.push(run_id.clone());
        match action {
            JobAction::Push { title, body } => {
                let vars = [("date", today.as_str()), ("job", name.as_str()), ("project", "")];
                out.pushes.push((render(&title, &vars), render(&body, &vars)));
                tx.execute(
                    "UPDATE job_runs SET state = 'done', started_at = ?2, result = 'push sent', updated_at = ?2 WHERE id = ?1",
                    params![run_id, stamp],
                )?;
            }
            JobAction::Todo { title, project_id, section } => {
                let project = match project_id.as_deref() {
                    Some(pid) => project_name_and_section(&tx, pid)?,
                    None => None,
                };
                let section = match (&project, section) {
                    (Some((_, s)), _) => s.clone(),
                    (None, Some(s)) => s.as_str().to_string(),
                    (None, None) => Section::P.as_str().to_string(),
                };
                let pname = project.as_ref().map(|(n, _)| n.as_str()).unwrap_or("");
                let vars = [("date", today.as_str()), ("job", name.as_str()), ("project", pname)];
                let todo = insert_scheduled_todo(&tx, &section, &render(&title, &vars), project_id.as_deref(), &id, &run_id)?;
                tx.execute(
                    "UPDATE job_runs SET state = 'done', todo_id = ?2, started_at = ?3, result = 'todo created', updated_at = ?3 WHERE id = ?1",
                    params![run_id, todo, stamp],
                )?;
                out.todos.push(todo);
            }
            // Left `due` for the Mac's runner.
            JobAction::Conversation { .. } | JobAction::Research { .. } | JobAction::Watch { .. } => {}
        }
    }
    tx.commit()?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use rusqlite::params;

    use crate::test_support::{pool, seed_computers};

    fn seed(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch("INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'app', 'Si', '~/a');").unwrap();
    }

    fn job(conn: &Connection, id: &str, cron: &str, action: &str, last_slot: &str) {
        conn.execute(
            "INSERT INTO jobs (id, name, enabled, trigger, action, max_runs_per_day, last_slot_at) VALUES (?1, ?1, 1, ?2, ?3, 4, ?4)",
            params![id, format!(r#"{{"kind":"cron","cron":"{cron}"}}"#), action, last_slot],
        )
        .unwrap();
    }

    const CONVERSATION: &str = r#"{"kind":"conversation","project_id":"pa","computer_id":null,"tool":"claude","folder":null,"prompt":"x","priority":"background","limit":{"mode":"always"}}"#;

    fn runs(conn: &Connection, job: &str) -> Vec<(String, String)> {
        let mut stmt = conn.prepare("SELECT due_at, state FROM job_runs WHERE job_id = ?1 ORDER BY due_at").unwrap();
        stmt.query_map(params![job], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    fn at(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, mo, d, h, mi, 0).unwrap()
    }

    #[test]
    fn tick_creates_run_when_slot_passes() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 9 * * *", CONVERSATION, "2026-11-01 08:00:00");
        tick_db(&conn, at(2026, 11, 2, 6, 59)).unwrap();
        assert!(runs(&conn, "j").is_empty(), "09:00 Sofia is 07:00 UTC");
        let out = tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert_eq!(out.created.len(), 1);
        assert_eq!(runs(&conn, "j"), vec![("2026-11-02 07:00:00".to_string(), "due".to_string())]);
        tick_db(&conn, at(2026, 11, 2, 7, 1)).unwrap();
        assert_eq!(runs(&conn, "j").len(), 1, "a slot runs once");
    }

    #[test]
    fn tick_coalesces_missed_slots() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "*/15 * * * *", CONVERSATION, "2026-11-02 04:00:00");
        tick_db(&conn, at(2026, 11, 2, 10, 7)).unwrap();
        assert_eq!(runs(&conn, "j"), vec![("2026-11-02 10:00:00".to_string(), "due".to_string())], "one run for the latest slot");
    }

    #[test]
    fn tick_respects_max_runs_per_day() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "*/15 * * * *", CONVERSATION, "2026-11-02 06:00:00");
        conn.execute("UPDATE jobs SET max_runs_per_day = 2", []).unwrap();
        for m in [15, 30, 45] {
            tick_db(&conn, at(2026, 11, 2, 6, m)).unwrap();
            // A runner picks each run up before the next slot.
            conn.execute("UPDATE job_runs SET state = 'done' WHERE state = 'due'", []).unwrap();
        }
        let states: Vec<String> = runs(&conn, "j").into_iter().map(|(_, s)| s).collect();
        assert_eq!(states, vec!["done", "done", "skipped"]);
    }

    #[test]
    fn watch_job_ignores_daily_cap() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        let watch = r#"{"kind":"watch","project_id":"pa","computer_id":"mac","watcher":"sentry","debug_tool":null,"prompt":""}"#;
        job(&conn, "w", "*/10 * * * *", watch, "2026-11-02 06:00:00");
        conn.execute("UPDATE jobs SET max_runs_per_day = 1", []).unwrap();
        for m in [10, 20] {
            tick_db(&conn, at(2026, 11, 2, 6, m)).unwrap();
            conn.execute("UPDATE job_runs SET state = 'done' WHERE state = 'due'", []).unwrap();
        }
        let states: Vec<String> = runs(&conn, "w").into_iter().map(|(_, s)| s).collect();
        assert_eq!(states, vec!["done", "done"]);
    }

    #[test]
    fn tick_marks_missed_after_24h() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 9 1 1 *", CONVERSATION, "2026-11-01 00:00:00");
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state) VALUES ('old', 'j', '2026-11-01 06:00:00', 'waiting'),
                 ('new', 'j', '2026-11-02 06:00:00', 'due');",
        )
        .unwrap();
        let out = tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert_eq!(out.missed, vec!["old".to_string()]);
        let state = |id: &str| -> String { conn.query_row("SELECT state FROM job_runs WHERE id = ?1", params![id], |r| r.get(0)).unwrap() };
        assert_eq!((state("old"), state("new")), ("missed".into(), "due".into()));
    }

    #[test]
    fn tick_runs_push_job_on_hub() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 9 * * *", r#"{"kind":"push","title":"Stand up {date}","body":"Stretch"}"#, "2026-11-01 08:00:00");
        let out = tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert_eq!(out.pushes, vec![("Stand up 2026-11-02".to_string(), "Stretch".to_string())]);
        assert_eq!(runs(&conn, "j")[0].1, "done");
    }

    #[test]
    fn tick_runs_todo_job_with_marker() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 9 * * *", r#"{"kind":"todo","title":"Review {project} PRs","project_id":"pa","section":null}"#, "2026-11-01 08:00:00");
        let out = tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert_eq!(out.todos.len(), 1);
        let (title, section, project, marker): (String, String, Option<String>, Option<String>) = conn
            .query_row("SELECT title, section, project_id, scheduled_job_id FROM todos WHERE id = ?1", params![out.todos[0]], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .unwrap();
        assert_eq!((title.as_str(), section.as_str(), project.as_deref(), marker.as_deref()), ("Review app PRs", "Si", Some("pa"), Some("j")));
        assert_eq!(runs(&conn, "j")[0].1, "done");
    }

    #[test]
    fn tick_ignores_disabled_and_manual() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "off", "* * * * *", CONVERSATION, "2026-11-01 08:00:00");
        conn.execute("UPDATE jobs SET enabled = 0 WHERE id = 'off'", []).unwrap();
        conn.execute(
            "INSERT INTO jobs (id, name, trigger, action) VALUES ('man', 'm', '{\"kind\":\"manual\"}', ?1)",
            params![CONVERSATION],
        )
        .unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert!(runs(&conn, "off").is_empty() && runs(&conn, "man").is_empty());
    }

    #[test]
    fn tick_supersedes_pending_run() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 * * * *", CONVERSATION, "2026-11-02 08:00:00");
        for h in [9, 10, 11] {
            tick_db(&conn, at(2026, 11, 2, h, 0)).unwrap();
        }
        let rows = runs(&conn, "j");
        let states: Vec<&str> = rows.iter().map(|(_, s)| s.as_str()).collect();
        assert_eq!(states, vec!["skipped", "skipped", "due"], "only the newest slot stays pending: {rows:?}");
        let result: String = conn.query_row("SELECT result FROM job_runs WHERE job_id = 'j' AND due_at = '2026-11-02 09:00:00'", [], |r| r.get(0)).unwrap();
        assert_eq!(result, "superseded by a later slot");
    }

    #[test]
    fn tick_fails_stuck_running_runs() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "j", "0 9 1 1 *", CONVERSATION, "2026-11-01 00:00:00");
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, updated_at) VALUES
                 ('stuck', 'j', '2026-11-02 06:00:00', 'running', '2026-11-02 06:40:00'),
                 ('fresh', 'j', '2026-11-02 06:50:00', 'running', '2026-11-02 06:55:00');
             INSERT INTO todos (id, section, title) VALUES ('t', 'Si', 'x');
             INSERT INTO job_runs (id, job_id, due_at, state, todo_id, updated_at) VALUES
                 ('started', 'j', '2026-11-02 06:00:00', 'running', 't', '2026-11-02 06:00:00');",
        )
        .unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        let state = |id: &str| -> String { conn.query_row("SELECT state FROM job_runs WHERE id = ?1", params![id], |r| r.get(0)).unwrap() };
        assert_eq!((state("stuck"), state("fresh"), state("started")), ("failed".into(), "running".into(), "running".into()));
    }

    const RESEARCH: &str = r#"{"kind":"research","project_id":"pa","computer_id":null,"tool":"claude","folder":null,"prompt":"","priority":"background","limit":{"mode":"always"}}"#;

    #[test]
    fn tick_skips_research_without_ideas() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "r", "0 9 * * *", RESEARCH, "2026-11-01 08:00:00");
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        let (state, result): (String, String) =
            conn.query_row("SELECT state, result FROM job_runs WHERE job_id = 'r'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((state.as_str(), result.as_str()), ("skipped", "no new ideas"));
        conn.execute("INSERT INTO ideas (id, project_id, title) VALUES ('i1', 'pa', 'Try Hermes')", []).unwrap();
        tick_db(&conn, at(2026, 11, 3, 7, 0)).unwrap();
        assert_eq!(runs(&conn, "r").last().unwrap().1, "due", "with an idea the run is due");
    }

    #[test]
    fn research_skips_pending_ideas() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "r", "0 9 * * *", RESEARCH, "2026-11-01 08:00:00");
        conn.execute("INSERT INTO ideas (id, project_id, title, pending) VALUES ('i1', 'pa', 'Unapproved', 1)", []).unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        assert_eq!(runs(&conn, "r")[0].1, "skipped");
    }

    #[test]
    fn missed_research_now_returns_idea() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "rn", "0 9 1 1 *", RESEARCH, "2026-11-01 00:00:00");
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, note) VALUES ('old', 'rn', '2026-11-01 06:00:00', 'due', 'idea:i1');
             INSERT INTO ideas (id, project_id, title, status, run_id) VALUES ('i1', 'pa', 'Waiting too long', 'researching', 'old');",
        )
        .unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        let (status, run_id): (String, Option<String>) =
            conn.query_row("SELECT status, run_id FROM ideas WHERE id = 'i1'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((status.as_str(), run_id), ("new", None));
    }

    #[test]
    fn stuck_claimed_research_now_returns_idea() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "rn", "0 9 1 1 *", RESEARCH, "2026-11-01 00:00:00");
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, note, updated_at)
                 VALUES ('stuck', 'rn', '2026-11-02 06:30:00', 'running', 'idea:i1', '2026-11-02 06:30:00');
             INSERT INTO ideas (id, project_id, title, status, run_id) VALUES ('i1', 'pa', 'Claimed then lost', 'researching', 'stuck');",
        )
        .unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        let status: String = conn.query_row("SELECT status FROM ideas WHERE id = 'i1'", [], |r| r.get(0)).unwrap();
        assert_eq!(status, "new", "a run the stuck sweep failed gives its idea back");
    }

    #[test]
    fn deleted_job_returns_reserved_idea() {
        let (_db, pool) = pool("sched");
        let conn = pool.get().unwrap();
        seed(&conn);
        job(&conn, "rn", "0 9 1 1 *", RESEARCH, "2026-11-01 00:00:00");
        conn.execute_batch(
            "INSERT INTO job_runs (id, job_id, due_at, state, note) VALUES ('r', 'rn', '2026-11-02 06:50:00', 'due', 'idea:i1');
             INSERT INTO ideas (id, project_id, title, status, run_id) VALUES ('i1', 'pa', 'Orphaned', 'researching', 'r');
             DELETE FROM jobs WHERE id = 'rn';",
        )
        .unwrap();
        tick_db(&conn, at(2026, 11, 2, 7, 0)).unwrap();
        let status: String = conn.query_row("SELECT status FROM ideas WHERE id = 'i1'", [], |r| r.get(0)).unwrap();
        assert_eq!(status, "new", "an idea whose run is gone goes back to the queue");
    }

    #[test]
    fn render_replaces_known_vars() {
        let out = render("{job} on {date} in {folder} for {project} {unknown}", &[("job", "J"), ("date", "D"), ("folder", "F"), ("project", "P")]);
        assert_eq!(out, "J on D in F for P {unknown}");
    }
}
