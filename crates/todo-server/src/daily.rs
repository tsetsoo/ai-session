use actix_web::{web, HttpResponse};
use rusqlite::{params, Connection};
use todo_shared::{CreateDailyRequest, DailyStatus, SetTodoDailyRequest, Todo};

use crate::broadcast::Broadcaster;
use crate::db::DbPool;
use crate::handlers::SELECT_COLS;
use crate::models::row_to_todo;

fn valid_date(s: &str) -> bool {
    if s.len() != 10
        || s.as_bytes().get(4).is_none_or(|b| *b != b'-')
        || s.as_bytes().get(7).is_none_or(|b| *b != b'-')
    {
        return false;
    }
    let Ok(y) = s[0..4].parse::<i32>() else {
        return false;
    };
    let Ok(m) = s[5..7].parse::<u32>() else {
        return false;
    };
    let Ok(d) = s[8..10].parse::<u32>() else {
        return false;
    };
    if !(1..=12).contains(&m) || d == 0 {
        return false;
    }
    let max_d = days_in_month(y, m);
    d <= max_d
}

fn is_leap(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y: i32, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(y) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Add one calendar day to YYYY-MM-DD.
pub fn add_one_day(date: &str) -> Option<String> {
    if !valid_date(date) {
        return None;
    }
    let y: i32 = date[0..4].parse().ok()?;
    let m: u32 = date[5..7].parse().ok()?;
    let d: u32 = date[8..10].parse().ok()?;
    let max_d = days_in_month(y, m);
    if d < max_d {
        return Some(format!("{y:04}-{m:02}-{:02}", d + 1));
    }
    if m < 12 {
        return Some(format!("{y:04}-{:02}-01", m + 1));
    }
    Some(format!("{:04}-01-01", y + 1))
}

fn day_exists(conn: &Connection, date: &str) -> bool {
    conn.query_row(
        "SELECT COUNT(*) FROM daily_days WHERE date = ?1",
        params![date],
        |row| row.get::<_, i32>(0),
    )
    .is_ok_and(|c| c > 0)
}

fn previous_date(conn: &Connection, before: &str) -> Option<String> {
    conn.query_row(
        "SELECT date FROM daily_days WHERE date < ?1 ORDER BY date DESC LIMIT 1",
        params![before],
        |row| row.get(0),
    )
    .ok()
}

fn insert_day(conn: &Connection, date: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO daily_days (date) VALUES (?1)",
        params![date],
    )?;
    Ok(())
}

fn carry_incomplete(conn: &Connection, from: &str, to: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE todos SET daily_date = ?1, carried_from = ?2, updated_at = datetime('now')
         WHERE daily_date = ?2 AND completed = 0",
        params![to, from],
    )
}

fn list_for_date(conn: &Connection, date: &str) -> rusqlite::Result<Vec<Todo>> {
    // History view: return every todo on that board, including completed.
    let order = "CASE importance WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 END ASC, due_date IS NULL, due_date ASC, created_at DESC";
    let sql = format!(
        "SELECT {SELECT_COLS} FROM todos WHERE daily_date = ?1 ORDER BY {order}"
    );
    let mut stmt = conn.prepare(&sql)?;
    let todos = stmt
        .query_map(params![date], row_to_todo)?
        .filter_map(std::result::Result::ok)
        .collect();
    Ok(todos)
}

#[derive(serde::Deserialize)]
pub struct DailyStatusQuery {
    pub local_today: String,
}

pub async fn daily_status(pool: web::Data<DbPool>, query: web::Query<DailyStatusQuery>) -> HttpResponse {
    let today = query.local_today.trim();
    if !valid_date(today) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid local_today"}));
    }
    let Some(tomorrow) = add_one_day(today) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid local_today"}));
    };

    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let has_today = day_exists(&conn, today);
    let has_tomorrow = day_exists(&conn, &tomorrow);
    let previous_date = previous_date(&conn, today);
    let button = if has_today { "tomorrow" } else { "today" };

    HttpResponse::Ok().json(DailyStatus {
        local_today: today.to_string(),
        has_today,
        has_tomorrow,
        button: button.to_string(),
        previous_date,
    })
}

#[derive(serde::Deserialize)]
pub struct DailyListQuery {
    pub date: String,
}

pub async fn list_daily(pool: web::Data<DbPool>, query: web::Query<DailyListQuery>) -> HttpResponse {
    let date = query.date.trim();
    if !valid_date(date) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid date"}));
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };
    match list_for_date(&conn, date) {
        Ok(todos) => HttpResponse::Ok().json(todos),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

pub async fn create_daily(
    pool: web::Data<DbPool>,
    body: web::Json<CreateDailyRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let today = body.local_today.trim();
    if !valid_date(today) {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid local_today"}));
    }
    let Some(tomorrow) = add_one_day(today) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid local_today"}));
    };

    let for_day = body.for_day.trim();
    if for_day != "today" && for_day != "tomorrow" {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "for must be today or tomorrow"}));
    }

    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    };

    let has_today = day_exists(&conn, today);

    // Enforce button rules: create today only if missing; tomorrow only if today exists
    if for_day == "today" && has_today {
        let todos = list_for_date(&conn, today).unwrap_or_default();
        return HttpResponse::Ok().json(serde_json::json!({
            "date": today,
            "created": false,
            "todos": todos,
        }));
    }
    if for_day == "tomorrow" && !has_today {
        return HttpResponse::Conflict().json(serde_json::json!({"error": "Create todos for today first"}));
    }
    if for_day == "tomorrow" && day_exists(&conn, &tomorrow) {
        let todos = list_for_date(&conn, &tomorrow).unwrap_or_default();
        return HttpResponse::Ok().json(serde_json::json!({
            "date": tomorrow,
            "created": false,
            "todos": todos,
        }));
    }

    let result = (|| -> rusqlite::Result<(String, bool)> {
        if for_day == "today" {
            insert_day(&conn, today)?;
            if let Some(prior) = previous_date(&conn, today) {
                carry_incomplete(&conn, &prior, today)?;
            }
            Ok((today.to_string(), true))
        } else {
            insert_day(&conn, &tomorrow)?;
            carry_incomplete(&conn, today, &tomorrow)?;
            Ok((tomorrow, true))
        }
    })();

    match result {
        Ok((date, created)) => {
            broadcaster.send();
            let todos = list_for_date(&conn, &date).unwrap_or_default();
            HttpResponse::Ok().json(serde_json::json!({
                "date": date,
                "created": created,
                "todos": todos,
            }))
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

pub async fn set_todo_daily(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetTodoDailyRequest>,
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

    match &body.date {
        None => {
            if let Err(e) = conn.execute(
                "UPDATE todos SET daily_date = NULL, carried_from = NULL, updated_at = datetime('now') WHERE id = ?1",
                params![id],
            ) {
                return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()}));
            }
        }
        Some(date) => {
            let date = date.trim();
            if !valid_date(date) {
                return HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid date"}));
            }
            // Spec: pull requires today's board. Client should pass local today.
            // We accept any date that exists in daily_days, but 409 if that day board missing.
            if !day_exists(&conn, date) {
                return HttpResponse::Conflict().json(serde_json::json!({"error": "Daily board does not exist for date; create today first"}));
            }
            if let Err(e) = conn.execute(
                "UPDATE todos SET daily_date = ?1, carried_from = NULL, updated_at = datetime('now') WHERE id = ?2",
                params![date, id],
            ) {
                return HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()}));
            }
        }
    }

    broadcaster.send();
    let sql = format!("SELECT {SELECT_COLS} FROM todos WHERE id = ?1");
    match conn.query_row(&sql, params![id], row_to_todo) {
        Ok(todo) => HttpResponse::Ok().json(todo),
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::TestDb;

    /// The test database (removed on drop) and its pool; the pool is dropped first.
    fn pool() -> (TestDb, DbPool) {
        let db = TestDb::new("daily");
        let pool = db.pool();
        (db, pool)
    }

    #[test]
    fn add_one_day_month_and_year_boundaries() {
        assert_eq!(add_one_day("2026-07-26").as_deref(), Some("2026-07-27"));
        assert_eq!(add_one_day("2026-01-31").as_deref(), Some("2026-02-01"));
        assert_eq!(add_one_day("2026-12-31").as_deref(), Some("2027-01-01"));
        assert_eq!(add_one_day("2024-02-28").as_deref(), Some("2024-02-29"));
        assert_eq!(add_one_day("2025-02-28").as_deref(), Some("2025-03-01"));
    }

    #[test]
    fn create_today_empty_still_inserts_day() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        insert_day(&conn, "2026-07-26").unwrap();
        assert!(day_exists(&conn, "2026-07-26"));
        assert_eq!(carry_incomplete(&conn, "2026-07-25", "2026-07-26").unwrap(), 0);
    }

    #[test]
    fn carry_moves_incomplete_only() {
        let (_db, pool) = pool();
        let conn = pool.get().unwrap();
        insert_day(&conn, "2026-07-25").unwrap();
        insert_day(&conn, "2026-07-26").unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title, completed, daily_date) VALUES ('a','P','open',0,'2026-07-25')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO todos (id, section, title, completed, daily_date, completed_at) VALUES ('b','P','done',1,'2026-07-25', datetime('now'))",
            [],
        )
        .unwrap();
        assert_eq!(carry_incomplete(&conn, "2026-07-25", "2026-07-26").unwrap(), 1);
        let a_date: String = conn
            .query_row("SELECT daily_date FROM todos WHERE id='a'", [], |r| r.get(0))
            .unwrap();
        let a_from: String = conn
            .query_row("SELECT carried_from FROM todos WHERE id='a'", [], |r| r.get(0))
            .unwrap();
        let b_date: String = conn
            .query_row("SELECT daily_date FROM todos WHERE id='b'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(a_date, "2026-07-26");
        assert_eq!(a_from, "2026-07-25");
        assert_eq!(b_date, "2026-07-25");
    }
}
