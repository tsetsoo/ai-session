//! The weekly recap: weeks run Monday to Sunday in daily-update days (Sofia 08:00 to 08:00).

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use rusqlite::{params, Connection};
use todo_shared::{WeeklyJob, WeeklyJobs, WeeklyRunLine};

use crate::cron::TZ;
use crate::scheduler::{parse_sql_time, sql_time};
use crate::updates::{day_window, parse_day};

const FALLBACK_HOUR: u32 = 10;

fn fmt(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

fn monday(d: NaiveDate) -> NaiveDate {
    d - Duration::days(i64::from(d.weekday().num_days_from_monday()))
}

/// The Monday of the week that `day` (YYYY-MM-DD) belongs to.
#[allow(dead_code)] // used by the recap writer (Task 3)
pub(crate) fn week_of_day(day: &str) -> Option<String> {
    Some(fmt(monday(parse_day(day)?)))
}

/// The seven days of the week starting on `week` (which must be a Monday).
#[allow(dead_code)] // used by the recap writer (Task 3)
pub(crate) fn week_days(week: &str) -> Option<Vec<String>> {
    let start = parse_day(week)?;
    if start.weekday().num_days_from_monday() != 0 {
        return None;
    }
    Some((0..7).map(|i| fmt(start + Duration::days(i))).collect())
}

/// The week of the daily-update day that contains `t`.
pub(crate) fn week_of_time(t: DateTime<Utc>) -> String {
    let local = t.with_timezone(&TZ).naive_local() - Duration::hours(8);
    fmt(monday(local.date()))
}

/// The most recent week that has ended at `now` (its end is `week + 7` 08:00 Sofia).
pub(crate) fn last_finished_week(now: DateTime<Utc>) -> Option<String> {
    let current = parse_day(&week_of_time(now))?;
    Some(fmt(current - Duration::days(7)))
}

/// When a week's recap is written anyway if its projects' updates are not all in: `week + 7` 10:00 Sofia.
pub(crate) fn week_fallback(week: &str) -> Option<DateTime<Utc>> {
    let next = parse_day(week)? + Duration::days(7);
    let local = next.and_time(NaiveTime::from_hms_opt(FALLBACK_HOUR, 0, 0)?);
    TZ.from_local_datetime(&local).single().map(|t| t.with_timezone(&Utc))
}

/// The start of a week: Sofia 08:00 on its Monday.
pub(crate) fn week_start(week: &str) -> Option<DateTime<Utc>> {
    Some(day_window(week)?.0)
}

/// The leading number of a watch result like "2 new issues", else 0.
fn new_findings(result: &str) -> u32 {
    let digits: String = result.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() || !result[digits.len()..].starts_with(" new") {
        return 0;
    }
    digits.parse().unwrap_or(0)
}

type RunRow = (String, String, String, String, Option<String>, Option<String>, Option<String>, String, String);

/// Adds every settled run not yet counted to its week's per-job tally, so the numbers outlive
/// the runs (watch upkeep deletes old ones and deleting a job cascades). Returns runs counted.
pub(crate) fn tally_settled_runs(conn: &Connection) -> rusqlite::Result<usize> {
    atomically(conn, "weekly_tally", tally_runs)
}

/// Runs `f` in a savepoint (nests inside any open transaction): its writes all land or none do.
fn atomically<T>(conn: &Connection, name: &str, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> rusqlite::Result<T> {
    conn.execute_batch(&format!("SAVEPOINT {name}"))?;
    match f(conn) {
        Ok(v) => {
            conn.execute_batch(&format!("RELEASE {name}"))?;
            Ok(v)
        }
        Err(e) => {
            let _ = conn.execute_batch(&format!("ROLLBACK TO {name}; RELEASE {name}"));
            Err(e)
        }
    }
}

/// The tick's weekly bookkeeping: a failure is logged and rolled back, never blocks scheduling.
pub(crate) fn weekly_upkeep_logged(conn: &Connection, now: DateTime<Utc>, snapshot: bool) {
    let result = if snapshot { snapshot_finished_weeks(conn, now).map(|_| ()) } else { tally_settled_runs(conn).map(|_| ()) };
    if let Err(e) = result {
        println!("weekly recap upkeep failed: {e}");
    }
}

fn tally_runs(conn: &Connection) -> rusqlite::Result<usize> {
    let rows: Vec<RunRow> = {
        let mut stmt = conn.prepare(
            "SELECT r.id, r.job_id, r.due_at, r.state, r.result, r.todo_id,
                    json_extract(j.action, '$.kind'), j.name,
                    COALESCE((SELECT p.name FROM projects p WHERE p.id = json_extract(j.action, '$.project_id')), '')
             FROM job_runs r JOIN jobs j ON j.id = r.job_id
             WHERE r.state IN ('done','failed','skipped','missed') AND r.tallied = 0
             ORDER BY r.due_at",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?))
        })?;
        mapped.collect::<rusqlite::Result<_>>()?
    };
    let mut counted = 0;
    for (id, job_id, due_at, state, result, todo_id, kind, name, project_name) in &rows {
        let Some(due) = parse_sql_time(due_at) else { continue };
        let week = week_of_time(due);
        let result = result.as_deref().unwrap_or("");
        let is_watch = kind.as_deref() == Some("watch");
        let (mut runs, mut done, mut failed, mut skipped, mut checks, mut findings) = (0, 0, 0, 0, 0, 0);
        if is_watch && (result == "quiet" || state == "skipped") {
            checks = 1;
        } else {
            runs = 1;
            match state.as_str() {
                "done" => done = 1,
                "skipped" => skipped = 1,
                _ => failed = 1,
            }
            if is_watch {
                findings = new_findings(result);
            }
        }
        let started = i64::from(result.starts_with("started "));
        conn.execute(
            "INSERT INTO weekly_job_tallies (week, job_id, job_name, project_name, is_watch, runs, done, failed, skipped,
                                             checks, findings, todos_created, conversations_started)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(week, job_id) DO UPDATE SET
                job_name = excluded.job_name, project_name = excluded.project_name, is_watch = excluded.is_watch,
                runs = runs + excluded.runs, done = done + excluded.done, failed = failed + excluded.failed,
                skipped = skipped + excluded.skipped, checks = checks + excluded.checks,
                findings = findings + excluded.findings, todos_created = todos_created + excluded.todos_created,
                conversations_started = conversations_started + excluded.conversations_started",
            params![
                week, job_id, name, project_name, i64::from(is_watch), runs, done, failed, skipped, checks, findings,
                i64::from(todo_id.is_some()), started
            ],
        )?;
        conn.execute("UPDATE job_runs SET tallied = 1 WHERE id = ?1", params![id])?;
        counted += 1;
    }
    Ok(counted)
}

/// A week's jobs from the tallies plus the runs still present (quiet watch checks are not lines).
pub(crate) fn live_jobs(conn: &Connection, week: &str) -> rusqlite::Result<WeeklyJobs> {
    let mut jobs: Vec<WeeklyJob> = {
        let mut stmt = conn.prepare(
            "SELECT job_id, job_name, project_name, is_watch, runs, done, failed, skipped, checks, findings
             FROM weekly_job_tallies WHERE week = ?1 ORDER BY project_name, job_name, job_id",
        )?;
        let mapped = stmt.query_map(params![week], |r| {
            Ok(WeeklyJob {
                job_id: r.get(0)?,
                name: r.get(1)?,
                project_name: r.get(2)?,
                is_watch: r.get::<_, i64>(3)? != 0,
                runs: r.get(4)?,
                done: r.get(5)?,
                failed: r.get(6)?,
                skipped: r.get(7)?,
                checks: r.get(8)?,
                findings: r.get(9)?,
                lines: Vec::new(),
            })
        })?;
        mapped.collect::<rusqlite::Result<_>>()?
    };
    let (mut todos_created, mut conversations_started) = (0, 0);
    conn.query_row(
        "SELECT COALESCE(SUM(todos_created), 0), COALESCE(SUM(conversations_started), 0) FROM weekly_job_tallies WHERE week = ?1",
        params![week],
        |r| {
            todos_created = r.get(0)?;
            conversations_started = r.get(1)?;
            Ok(())
        },
    )?;
    if let Some(start) = week_start(week) {
        let mut stmt = conn.prepare(
            "SELECT r.job_id, r.id, r.due_at, r.state, COALESCE(t.title, r.result, ''), r.todo_id
             FROM job_runs r JOIN jobs j ON j.id = r.job_id LEFT JOIN todos t ON t.id = r.todo_id
             WHERE r.state IN ('done','failed','skipped','missed') AND r.due_at >= ?1 AND r.due_at < ?2
               AND NOT (COALESCE(json_extract(j.action, '$.kind'), '') = 'watch'
                        AND (r.state = 'skipped' OR COALESCE(r.result, '') = 'quiet'))
             ORDER BY (r.state IN ('failed','missed')) DESC, COALESCE(t.completed, 1) ASC, r.due_at DESC, r.id",
        )?;
        let mapped = stmt.query_map(params![sql_time(start), sql_time(start + Duration::days(7))], |r| {
            Ok((
                r.get::<_, String>(0)?,
                WeeklyRunLine { run_id: r.get(1)?, due_at: r.get(2)?, state: r.get(3)?, outcome: r.get(4)?, todo_id: r.get(5)? },
            ))
        })?;
        for line in mapped {
            let (job_id, line) = line?;
            if let Some(job) = jobs.iter_mut().find(|j| j.job_id == job_id) {
                job.lines.push(line);
            }
        }
    }
    Ok(WeeklyJobs {
        runs: jobs.iter().map(|j| j.runs).sum(),
        done: jobs.iter().map(|j| j.done).sum(),
        failed: jobs.iter().map(|j| j.failed).sum(),
        skipped: jobs.iter().map(|j| j.skipped).sum(),
        findings: jobs.iter().map(|j| j.findings).sum(),
        todos_created,
        conversations_started,
        jobs,
    })
}

/// Stores the jobs snapshot of the last finished week once, when its recap is due.
/// Returns how many snapshots were taken.
pub(crate) fn snapshot_finished_weeks(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize> {
    atomically(conn, "weekly_snapshot", |c| snapshot_week(c, now))
}

fn snapshot_week(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<usize> {
    let Some(week) = last_finished_week(now) else { return Ok(0) };
    if week_fallback(&week).is_none_or(|t| now < t) {
        return Ok(0);
    }
    let have: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM weekly_jobs WHERE week = ?1)", params![week], |r| r.get(0))?;
    if have {
        return Ok(0);
    }
    tally_settled_runs(conn)?;
    let snapshot = live_jobs(conn, &week)?;
    let json = serde_json::to_string(&snapshot).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    conn.execute(
        "INSERT OR IGNORE INTO weekly_jobs (week, snapshot, taken_at) VALUES (?1, ?2, ?3)",
        params![week, json, sql_time(now)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn week_of_day_is_the_monday() {
        assert_eq!(week_of_day("2026-11-08").as_deref(), Some("2026-11-02"));
        assert_eq!(week_of_day("2026-11-09").as_deref(), Some("2026-11-09"));
        assert_eq!(week_of_day("nope"), None);
    }

    #[test]
    fn week_days_are_seven() {
        let d = week_days("2026-11-02").unwrap();
        assert_eq!(d.len(), 7);
        assert_eq!(d[0], "2026-11-02");
        assert_eq!(d[6], "2026-11-08");
        assert_eq!(week_days("2026-11-03"), None);
    }

    #[test]
    fn week_of_time_shifts_eight_hours() {
        assert_eq!(week_of_time(utc("2026-11-09T05:59:00Z")), "2026-11-02");
        assert_eq!(week_of_time(utc("2026-11-09T06:00:00Z")), "2026-11-09");
    }

    #[test]
    fn last_finished_week_ends_monday_eight() {
        assert_eq!(last_finished_week(utc("2026-11-09T06:00:00Z")).as_deref(), Some("2026-11-02"));
        assert_eq!(last_finished_week(utc("2026-11-09T05:59:00Z")).as_deref(), Some("2026-10-26"));
    }

    #[test]
    fn dst_boundary_weeks() {
        assert_eq!(week_fallback("2026-10-19"), Some(utc("2026-10-26T08:00:00Z")));
        assert_eq!(week_of_time(utc("2026-10-26T05:59:00Z")), "2026-10-19");
        assert_eq!(week_of_time(utc("2026-10-26T06:00:00Z")), "2026-10-26");
    }

    #[test]
    fn fallback_is_monday_ten() {
        assert_eq!(week_fallback("2026-11-02"), Some(utc("2026-11-09T08:00:00Z")));
    }

    use crate::test_support::pool;
    use rusqlite::Connection;

    const TODO_JOB: &str = r#"{"kind":"conversation","project_id":"pa"}"#;
    const WATCH_JOB: &str = r#"{"kind":"watch","project_id":"pa"}"#;

    fn seed(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO projects (id, name, section, folder) VALUES ('pa', 'Alpha', 'Si', '~/a');
             INSERT INTO todos (id, section, title, completed) VALUES ('open1', 'Si', 'Open todo', 0), ('shut1', 'Si', 'Shut todo', 1);",
        )
        .unwrap();
        for (id, name, action) in [("j", "Research", TODO_JOB), ("w", "Sentry", WATCH_JOB)] {
            conn.execute(
                "INSERT INTO jobs (id, name, trigger, action) VALUES (?1, ?2, '{\"kind\":\"manual\"}', ?3)",
                params![id, name, action],
            )
            .unwrap();
        }
    }

    fn run(conn: &Connection, job: &str, due: &str, state: &str, result: Option<&str>, todo: Option<&str>) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO job_runs (id, job_id, due_at, state, result, todo_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, job, due, state, result, todo],
        )
        .unwrap();
        id
    }

    type Tally = (u32, u32, u32, u32, u32, u32, u32, u32);

    fn tally(conn: &Connection, week: &str, job: &str) -> Tally {
        conn.query_row(
            "SELECT runs, done, failed, skipped, checks, findings, todos_created, conversations_started
             FROM weekly_job_tallies WHERE week = ?1 AND job_id = ?2",
            params![week, job],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?)),
        )
        .unwrap()
    }

    #[test]
    fn tally_counts_runs_by_week() {
        let (_db, pool) = pool("tally-week");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-03 09:00:00", "done", Some("started claude"), Some("open1"));
        run(&conn, "j", "2026-11-04 09:00:00", "done", Some("ok"), None);
        run(&conn, "j", "2026-11-05 09:00:00", "failed", Some("boom"), None);
        run(&conn, "j", "2026-11-06 09:00:00", "missed", None, None);
        run(&conn, "j", "2026-11-05 09:00:00", "due", None, None);
        assert_eq!(tally_settled_runs(&conn).unwrap(), 4);
        assert_eq!(tally(&conn, "2026-11-02", "j"), (4, 2, 2, 0, 0, 0, 1, 1));
        let name: (String, String) = conn
            .query_row("SELECT job_name, project_name FROM weekly_job_tallies WHERE job_id = 'j'", [], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert_eq!(name, ("Research".into(), "Alpha".into()));
        assert_eq!(tally_settled_runs(&conn).unwrap(), 0);
    }

    #[test]
    fn tally_watch_checks_and_findings() {
        let (_db, pool) = pool("tally-watch");
        let conn = pool.get().unwrap();
        seed(&conn);
        for h in 1..=3 {
            run(&conn, "w", &format!("2026-11-03 0{h}:00:00"), "done", Some("quiet"), None);
        }
        run(&conn, "w", "2026-11-03 05:00:00", "done", Some("2 new"), None);
        run(&conn, "w", "2026-11-03 06:00:00", "failed", Some("x"), None);
        tally_settled_runs(&conn).unwrap();
        assert_eq!(tally(&conn, "2026-11-02", "w"), (2, 1, 1, 0, 3, 2, 0, 0));
    }

    #[test]
    fn tally_survives_watch_prune() {
        let (_db, pool) = pool("tally-prune");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "w", "2026-11-03 01:00:00", "done", Some("quiet"), None);
        run(&conn, "w", "2026-11-03 02:00:00", "failed", Some("x"), None);
        tally_settled_runs(&conn).unwrap();
        let later = utc("2026-11-03T00:00:00Z") + Duration::days(3);
        crate::watch::watch_upkeep(&conn, later).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
        assert_eq!(tally(&conn, "2026-11-02", "w"), (1, 0, 1, 0, 1, 0, 0, 0));
        assert_eq!(tally_settled_runs(&conn).unwrap(), 0);
        assert_eq!(tally(&conn, "2026-11-02", "w"), (1, 0, 1, 0, 1, 0, 0, 0));
    }

    #[actix_web::test]
    async fn delete_job_tallies_first() {
        let (_db, pool) = pool("tally-delete");
        {
            let conn = pool.get().unwrap();
            seed(&conn);
            run(&conn, "j", "2026-11-03 09:00:00", "done", Some("ok"), None);
        }
        assert_eq!(crate::test_support::delete(&pool, "/api/jobs/j").await.0, actix_web::http::StatusCode::OK);
        let conn = pool.get().unwrap();
        let name: String = conn.query_row("SELECT job_name FROM weekly_job_tallies WHERE job_id = 'j'", [], |r| r.get(0)).unwrap();
        assert_eq!(name, "Research");
        assert_eq!(tally(&conn, "2026-11-02", "j").0, 1);
    }

    #[test]
    fn snapshot_once_after_fallback() {
        let (_db, pool) = pool("snapshot");
        let conn = pool.get().unwrap();
        seed(&conn);
        let plain = run(&conn, "j", "2026-11-03 09:00:00", "done", Some("fine"), Some("shut1"));
        let opened = run(&conn, "j", "2026-11-04 09:00:00", "done", Some("fine"), Some("open1"));
        let failed = run(&conn, "j", "2026-11-02 09:00:00", "failed", Some("boom"), None);
        run(&conn, "w", "2026-11-03 09:00:00", "done", Some("quiet"), None);
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T07:59:00Z")).unwrap(), 0);
        let n: i64 = conn.query_row("SELECT COUNT(*) FROM weekly_jobs", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T08:00:00Z")).unwrap(), 1);
        let (json, taken): (String, String) =
            conn.query_row("SELECT snapshot, taken_at FROM weekly_jobs WHERE week = '2026-11-02'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        let snap: WeeklyJobs = serde_json::from_str(&json).unwrap();
        assert_eq!((snap.runs, snap.done, snap.failed, snap.todos_created), (3, 2, 1, 2));
        let job = snap.jobs.iter().find(|j| j.job_id == "j").unwrap();
        let ids: Vec<&str> = job.lines.iter().map(|l| l.run_id.as_str()).collect();
        assert_eq!(ids, [failed.as_str(), opened.as_str(), plain.as_str()]);
        assert_eq!(job.lines[1].outcome, "Open todo");
        assert_eq!(job.lines[0].outcome, "boom");
        let sentry = snap.jobs.iter().find(|j| j.job_id == "w").unwrap();
        assert_eq!((sentry.checks, sentry.lines.len()), (1, 0));
        assert_eq!(snapshot_finished_weeks(&conn, utc("2026-11-09T09:00:00Z")).unwrap(), 0);
        let again: String = conn.query_row("SELECT taken_at FROM weekly_jobs", [], |r| r.get(0)).unwrap();
        assert_eq!(again, taken);
    }

    #[test]
    fn weeks_split_at_monday_eight() {
        let (_db, pool) = pool("tally-split");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-09 05:59:00", "done", Some("a"), None);
        run(&conn, "j", "2026-11-09 06:00:00", "done", Some("b"), None);
        run(&conn, "j", "garbage", "done", Some("c"), None);
        assert_eq!(tally_settled_runs(&conn).unwrap(), 2);
        assert_eq!(tally(&conn, "2026-11-02", "j").0, 1);
        assert_eq!(tally(&conn, "2026-11-09", "j").0, 1);
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE tallied = 0", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 1);
    }

    #[test]
    fn check_runs_are_not_snapshot_lines() {
        let (_db, pool) = pool("lines-checks");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "w", "2026-11-03 01:00:00", "done", Some("quiet"), None);
        run(&conn, "w", "2026-11-03 02:00:00", "skipped", Some("busy"), None);
        let kept = run(&conn, "w", "2026-11-03 03:00:00", "done", Some("1 new"), None);
        tally_settled_runs(&conn).unwrap();
        let jobs = live_jobs(&conn, "2026-11-02").unwrap();
        assert_eq!(jobs.jobs[0].checks, 2);
        let ids: Vec<&str> = jobs.jobs[0].lines.iter().map(|l| l.run_id.as_str()).collect();
        assert_eq!(ids, [kept.as_str()]);
    }

    #[test]
    fn failed_tally_rolls_back_and_tick_continues() {
        let (_db, pool) = pool("tally-fails");
        let conn = pool.get().unwrap();
        seed(&conn);
        run(&conn, "j", "2026-11-03 09:00:00", "done", Some("ok"), None);
        run(&conn, "w", "2026-10-01 01:00:00", "done", Some("quiet"), None);
        conn.execute_batch("DROP TABLE weekly_job_tallies").unwrap();
        assert!(tally_settled_runs(&conn).is_err());
        let untallied: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE tallied = 0", [], |r| r.get(0)).unwrap();
        assert_eq!(untallied, 2);
        // The tick still runs: the old quiet check is pruned although tallying failed.
        crate::scheduler::tick_db(&conn, utc("2026-11-09T09:00:00Z")).unwrap();
        let pruned: i64 = conn.query_row("SELECT COUNT(*) FROM job_runs WHERE job_id = 'w'", [], |r| r.get(0)).unwrap();
        assert_eq!(pruned, 0);
    }
}
