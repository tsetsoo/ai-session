//! Today: reminders, people's dates, the morning briefing's settings, and the assistant that
//! adds them. Times are Europe/Sofia wall-clock times (`cron::TZ`); a reminder keeps its wall
//! time across DST.

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, TimeZone, Utc, Weekday};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, not_found, server_error};
use crate::cron::TZ;
use crate::db::DbPool;
use crate::scheduler::{parse_sql_time, sql_time};

pub(crate) const REPEATS: [&str; 6] = ["none", "daily", "weekdays", "weekly", "monthly", "yearly"];
pub(crate) const KINDS: [&str; 3] = ["birthday", "anniversary", "other"];
const LOCAL_FMT: &str = "%Y-%m-%d %H:%M";

pub(crate) enum TodayError {
    BadRequest(&'static str),
    NotFound(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for TodayError {
    fn from(e: rusqlite::Error) -> Self {
        TodayError::Db(e)
    }
}

pub(crate) fn respond(e: TodayError) -> HttpResponse {
    match e {
        TodayError::BadRequest(m) => bad_request(m),
        TodayError::NotFound(m) => not_found(m),
        TodayError::Db(e) => server_error(e),
    }
}

// --- Time ---------------------------------------------------------------------------

/// A Sofia wall-clock time as UTC. A time skipped by DST moves an hour later; a repeated one
/// takes the first.
pub(crate) fn local_to_utc(local: NaiveDateTime) -> DateTime<Utc> {
    TZ.from_local_datetime(&local)
        .earliest()
        .or_else(|| TZ.from_local_datetime(&(local + Duration::hours(1))).earliest())
        .map(|t| t.with_timezone(&Utc))
        .unwrap_or_else(|| Utc.from_utc_datetime(&local))
}

fn last_day(year: i32, month: u32) -> u32 {
    let (y, m) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    NaiveDate::from_ymd_opt(y, m, 1).and_then(|d| d.pred_opt()).map(|d| d.day()).unwrap_or(28)
}

/// `day` of that month, or the month's last day when it has fewer.
fn clamped(year: i32, month: u32, day: u32) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(year, month, day.min(last_day(year, month)))
}

/// The occurrence after `local` (one step), keeping `anchor_day` for monthly and yearly repeats
/// (the 31st stays the 31st where the month has one; 29 Feb is 28 Feb in other years).
fn step(repeat: &str, local: NaiveDateTime, anchor_day: u32, anchor_month: u32) -> Option<NaiveDateTime> {
    let time = local.time();
    let date = local.date();
    let next = match repeat {
        "daily" => date.succ_opt()?,
        "weekdays" => {
            let mut d = date.succ_opt()?;
            while matches!(d.weekday(), Weekday::Sat | Weekday::Sun) {
                d = d.succ_opt()?;
            }
            d
        }
        "weekly" => date + Duration::days(7),
        "monthly" => {
            let (y, m) = if date.month() == 12 { (date.year() + 1, 1) } else { (date.year(), date.month() + 1) };
            clamped(y, m, anchor_day)?
        }
        "yearly" => clamped(date.year() + 1, anchor_month, anchor_day)?,
        _ => return None,
    };
    Some(next.and_time(time))
}

/// The first occurrence strictly after `after`, stepping from `local` (Sofia wall time).
pub(crate) fn next_after(repeat: &str, local: NaiveDateTime, anchor_day: u32, anchor_month: u32, after: DateTime<Utc>) -> Option<NaiveDateTime> {
    let mut cur = local;
    for _ in 0..20_000 {
        cur = step(repeat, cur, anchor_day, anchor_month)?;
        if local_to_utc(cur) > after {
            return Some(cur);
        }
    }
    None
}

fn parse_local(at: &str) -> Option<NaiveDateTime> {
    NaiveDateTime::parse_from_str(at.trim(), LOCAL_FMT).ok()
}

/// Today's date in Sofia.
pub(crate) fn sofia_today(now: DateTime<Utc>) -> NaiveDate {
    now.with_timezone(&TZ).date_naive()
}

// --- Reminders ------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Reminder {
    pub id: String,
    pub title: String,
    pub notes: String,
    /// Sofia wall time, `YYYY-MM-DD HH:MM`.
    pub at: String,
    /// RFC 3339 UTC.
    pub next_at: String,
    pub repeat: String,
    /// `upcoming`, `due` or `done`.
    pub state: String,
    pub source: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct ReminderRequest {
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    /// Sofia wall time, `YYYY-MM-DD HH:MM`.
    #[serde(default)]
    pub at: Option<String>,
    #[serde(default)]
    pub repeat: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

const REMINDER_COLS: &str = "id, title, notes, local_at, next_at, repeat, state, source, created_at, updated_at";

fn row_to_reminder(r: &Row) -> rusqlite::Result<Reminder> {
    let next: String = r.get(4)?;
    Ok(Reminder {
        id: r.get(0)?,
        title: r.get(1)?,
        notes: r.get(2)?,
        at: r.get(3)?,
        next_at: parse_sql_time(&next).map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)).unwrap_or(next),
        repeat: r.get(5)?,
        state: r.get(6)?,
        source: r.get(7)?,
        created_at: r.get(8)?,
        updated_at: r.get(9)?,
    })
}

pub(crate) fn load_reminder(conn: &Connection, id: &str) -> rusqlite::Result<Option<Reminder>> {
    conn.query_row(&format!("SELECT {REMINDER_COLS} FROM reminders WHERE id = ?1"), params![id], row_to_reminder).optional()
}

/// Upcoming and due reminders, soonest first (due first), plus done ones from the last 7 days.
pub(crate) fn list_reminders_db(conn: &Connection) -> rusqlite::Result<Vec<Reminder>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {REMINDER_COLS} FROM reminders
         WHERE state != 'done' OR updated_at >= datetime('now', '-7 days')
         ORDER BY CASE state WHEN 'due' THEN 0 WHEN 'upcoming' THEN 1 ELSE 2 END, next_at"
    ))?;
    let rows = stmt.query_map([], row_to_reminder)?;
    rows.collect()
}

fn valid_title(title: &str) -> Result<String, TodayError> {
    let t: String = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        return Err(TodayError::BadRequest("title is required"));
    }
    Ok(t.chars().take(200).collect())
}

fn valid_repeat(repeat: &str) -> Result<String, TodayError> {
    if REPEATS.contains(&repeat) {
        Ok(repeat.to_string())
    } else {
        Err(TodayError::BadRequest("repeat must be none, daily, weekdays, weekly, monthly or yearly"))
    }
}

fn valid_source(source: Option<&str>) -> &'static str {
    if source == Some("agent") { "agent" } else { "manual" }
}

pub(crate) fn create_reminder_db(conn: &Connection, req: &ReminderRequest) -> Result<Reminder, TodayError> {
    let title = valid_title(req.title.as_deref().unwrap_or(""))?;
    let local = req.at.as_deref().and_then(parse_local).ok_or(TodayError::BadRequest("at must be YYYY-MM-DD HH:MM"))?;
    let repeat = valid_repeat(req.repeat.as_deref().unwrap_or("none"))?;
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO reminders (id, title, notes, local_at, anchor_day, anchor_month, next_at, repeat, state, source)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'upcoming', ?9)",
        params![
            id,
            title,
            req.notes.as_deref().unwrap_or("").trim().chars().take(2000).collect::<String>(),
            local.format(LOCAL_FMT).to_string(),
            local.day(),
            local.month(),
            sql_time(local_to_utc(local)),
            repeat,
            valid_source(req.source.as_deref())
        ],
    )?;
    load_reminder(conn, &id)?.ok_or(TodayError::NotFound("Reminder not found"))
}

pub(crate) fn update_reminder_db(conn: &Connection, id: &str, req: &ReminderRequest) -> Result<Reminder, TodayError> {
    let current = load_reminder(conn, id)?.ok_or(TodayError::NotFound("Reminder not found"))?;
    let title = match &req.title {
        Some(t) => valid_title(t)?,
        None => current.title,
    };
    let repeat = match &req.repeat {
        Some(r) => valid_repeat(r)?,
        None => current.repeat,
    };
    let notes = req.notes.clone().unwrap_or(current.notes);
    if let Some(at) = &req.at {
        let local = parse_local(at).ok_or(TodayError::BadRequest("at must be YYYY-MM-DD HH:MM"))?;
        // A new time starts over: upcoming, pushed again when it comes.
        conn.execute(
            "UPDATE reminders SET local_at = ?2, anchor_day = ?3, anchor_month = ?4, next_at = ?5, state = 'upcoming', pushed_at = NULL
             WHERE id = ?1",
            params![id, local.format(LOCAL_FMT).to_string(), local.day(), local.month(), sql_time(local_to_utc(local))],
        )?;
    }
    conn.execute(
        "UPDATE reminders SET title = ?2, notes = ?3, repeat = ?4, updated_at = datetime('now') WHERE id = ?1",
        params![id, title, notes.trim().chars().take(2000).collect::<String>(), repeat],
    )?;
    load_reminder(conn, id)?.ok_or(TodayError::NotFound("Reminder not found"))
}

/// Done: a one-off is finished; a repeat moves to its next time after now.
pub(crate) fn done_reminder_db(conn: &Connection, id: &str, now: DateTime<Utc>) -> Result<Reminder, TodayError> {
    let (local, repeat, anchor_day, anchor_month): (String, String, u32, u32) = conn
        .query_row("SELECT local_at, repeat, anchor_day, anchor_month FROM reminders WHERE id = ?1", params![id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .optional()?
        .ok_or(TodayError::NotFound("Reminder not found"))?;
    let next = parse_local(&local).and_then(|l| next_after(&repeat, l, anchor_day, anchor_month, now));
    match next {
        Some(next) => conn.execute(
            "UPDATE reminders SET local_at = ?2, next_at = ?3, state = 'upcoming', pushed_at = NULL, updated_at = datetime('now') WHERE id = ?1",
            params![id, next.format(LOCAL_FMT).to_string(), sql_time(local_to_utc(next))],
        )?,
        None => conn.execute("UPDATE reminders SET state = 'done', updated_at = datetime('now') WHERE id = ?1", params![id])?,
    };
    load_reminder(conn, id)?.ok_or(TodayError::NotFound("Reminder not found"))
}

#[derive(Debug, Deserialize)]
pub struct SnoozeRequest {
    /// Sofia wall time, `YYYY-MM-DD HH:MM`.
    pub until: String,
}

/// Snooze: this occurrence moves to `until`; a repeat's later times follow from there.
pub(crate) fn snooze_reminder_db(conn: &Connection, id: &str, req: &SnoozeRequest) -> Result<Reminder, TodayError> {
    let local = parse_local(&req.until).ok_or(TodayError::BadRequest("until must be YYYY-MM-DD HH:MM"))?;
    let changed = conn.execute(
        "UPDATE reminders SET local_at = ?2, next_at = ?3, state = 'upcoming', pushed_at = NULL, updated_at = datetime('now') WHERE id = ?1",
        params![id, local.format(LOCAL_FMT).to_string(), sql_time(local_to_utc(local))],
    )?;
    if changed == 0 {
        return Err(TodayError::NotFound("Reminder not found"));
    }
    load_reminder(conn, id)?.ok_or(TodayError::NotFound("Reminder not found"))
}

// --- People -----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub month: u32,
    pub day: u32,
    pub year: Option<i32>,
    pub notes: String,
    pub source: String,
    /// The next time it falls, today included: `YYYY-MM-DD`.
    pub next_date: String,
    /// The age (or years) on `next_date`, when the year is known.
    pub turns: Option<i32>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Deserialize)]
pub struct PersonRequest {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub month: Option<u32>,
    #[serde(default)]
    pub day: Option<u32>,
    /// `Some(None)` clears it.
    #[serde(default, deserialize_with = "nullable")]
    pub year: Option<Option<i32>>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

fn nullable<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Option<i32>>, D::Error> {
    Ok(Some(Option::deserialize(d)?))
}

/// When it next falls on or after `today` (29 Feb is 28 Feb in other years).
pub(crate) fn next_date(month: u32, day: u32, today: NaiveDate) -> Option<NaiveDate> {
    let this = clamped(today.year(), month, day)?;
    if this >= today { Some(this) } else { clamped(today.year() + 1, month, day) }
}

const PERSON_COLS: &str = "id, name, kind, month, day, year, notes, source, created_at, updated_at";

fn row_to_person(r: &Row, today: NaiveDate) -> rusqlite::Result<Person> {
    let (month, day, year): (u32, u32, Option<i32>) = (r.get(3)?, r.get(4)?, r.get(5)?);
    let next = next_date(month, day, today);
    Ok(Person {
        id: r.get(0)?,
        name: r.get(1)?,
        kind: r.get(2)?,
        month,
        day,
        year,
        notes: r.get(6)?,
        source: r.get(7)?,
        next_date: next.map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default(),
        turns: match (year, next) {
            (Some(y), Some(d)) if d.year() >= y => Some(d.year() - y),
            _ => None,
        },
        created_at: r.get(8)?,
        updated_at: r.get(9)?,
    })
}

pub(crate) fn load_person(conn: &Connection, id: &str, now: DateTime<Utc>) -> rusqlite::Result<Option<Person>> {
    let today = sofia_today(now);
    conn.query_row(&format!("SELECT {PERSON_COLS} FROM people WHERE id = ?1"), params![id], |r| row_to_person(r, today)).optional()
}

/// Everyone, by next date.
pub(crate) fn list_people_db(conn: &Connection, now: DateTime<Utc>) -> rusqlite::Result<Vec<Person>> {
    let today = sofia_today(now);
    let mut stmt = conn.prepare(&format!("SELECT {PERSON_COLS} FROM people"))?;
    let mut people = stmt.query_map([], |r| row_to_person(r, today))?.collect::<rusqlite::Result<Vec<_>>>()?;
    people.sort_by(|a, b| a.next_date.cmp(&b.next_date).then(a.name.cmp(&b.name)));
    Ok(people)
}

fn valid_date(month: u32, day: u32, year: Option<i32>) -> Result<(), TodayError> {
    // Checked against a leap year, so 29 Feb is allowed; with a year, against that year.
    let check_year = year.unwrap_or(2024);
    if NaiveDate::from_ymd_opt(check_year, month, day).is_none() || year.is_some_and(|y| !(1900..=2100).contains(&y)) {
        return Err(TodayError::BadRequest("not a real date"));
    }
    Ok(())
}

pub(crate) fn create_person_db(conn: &Connection, req: &PersonRequest, now: DateTime<Utc>) -> Result<Person, TodayError> {
    let name = valid_title(req.name.as_deref().unwrap_or("")).map_err(|_| TodayError::BadRequest("name is required"))?;
    let kind = req.kind.clone().unwrap_or_else(|| "birthday".into());
    if !KINDS.contains(&kind.as_str()) {
        return Err(TodayError::BadRequest("kind must be birthday, anniversary or other"));
    }
    let (month, day) = (req.month.unwrap_or(0), req.day.unwrap_or(0));
    let year = req.year.flatten();
    valid_date(month, day, year)?;
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO people (id, name, kind, month, day, year, notes, source) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            id,
            name,
            kind,
            month,
            day,
            year,
            req.notes.as_deref().unwrap_or("").trim().chars().take(2000).collect::<String>(),
            valid_source(req.source.as_deref())
        ],
    )?;
    load_person(conn, &id, now)?.ok_or(TodayError::NotFound("Person not found"))
}

pub(crate) fn update_person_db(conn: &Connection, id: &str, req: &PersonRequest, now: DateTime<Utc>) -> Result<Person, TodayError> {
    let p = load_person(conn, id, now)?.ok_or(TodayError::NotFound("Person not found"))?;
    let name = match &req.name {
        Some(n) => valid_title(n).map_err(|_| TodayError::BadRequest("name is required"))?,
        None => p.name,
    };
    let kind = req.kind.clone().unwrap_or(p.kind);
    if !KINDS.contains(&kind.as_str()) {
        return Err(TodayError::BadRequest("kind must be birthday, anniversary or other"));
    }
    let (month, day) = (req.month.unwrap_or(p.month), req.day.unwrap_or(p.day));
    let year = req.year.unwrap_or(p.year);
    valid_date(month, day, year)?;
    conn.execute(
        "UPDATE people SET name = ?2, kind = ?3, month = ?4, day = ?5, year = ?6, notes = ?7, updated_at = datetime('now') WHERE id = ?1",
        params![id, name, kind, month, day, year, req.notes.clone().unwrap_or(p.notes).trim().chars().take(2000).collect::<String>()],
    )?;
    load_person(conn, id, now)?.ok_or(TodayError::NotFound("Person not found"))
}

// --- Settings ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TodaySettings {
    pub briefing_enabled: bool,
    /// `HH:MM`, Sofia.
    pub briefing_time: String,
    /// `auto`, `claude` or `codex`.
    pub assistant_model: String,
    pub claude_model: String,
    pub codex_model: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct TodaySettingsRequest {
    pub briefing_enabled: Option<bool>,
    pub briefing_time: Option<String>,
    pub assistant_model: Option<String>,
    pub claude_model: Option<String>,
    pub codex_model: Option<String>,
}

pub(crate) fn settings_db(conn: &Connection) -> rusqlite::Result<TodaySettings> {
    conn.query_row(
        "SELECT briefing_enabled, briefing_time, assistant_model, claude_model, codex_model FROM today_settings WHERE id = 1",
        [],
        |r| {
            Ok(TodaySettings {
                briefing_enabled: r.get::<_, i64>(0)? != 0,
                briefing_time: r.get(1)?,
                assistant_model: r.get(2)?,
                claude_model: r.get(3)?,
                codex_model: r.get(4)?,
            })
        },
    )
}

pub(crate) fn update_settings_db(conn: &Connection, req: &TodaySettingsRequest) -> Result<TodaySettings, TodayError> {
    let mut s = settings_db(conn)?;
    if let Some(on) = req.briefing_enabled {
        s.briefing_enabled = on;
    }
    if let Some(t) = &req.briefing_time {
        if chrono::NaiveTime::parse_from_str(t.trim(), "%H:%M").is_err() {
            return Err(TodayError::BadRequest("briefing_time must be HH:MM"));
        }
        s.briefing_time = t.trim().to_string();
    }
    if let Some(m) = &req.assistant_model {
        if !["auto", "claude", "codex"].contains(&m.as_str()) {
            return Err(TodayError::BadRequest("assistant_model must be auto, claude or codex"));
        }
        s.assistant_model = m.clone();
    }
    for (value, slot) in [(&req.claude_model, &mut s.claude_model), (&req.codex_model, &mut s.codex_model)] {
        if let Some(v) = value {
            let v = v.trim();
            if v.is_empty() || v.len() > 80 || !v.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_')) {
                return Err(TodayError::BadRequest("a model id is letters, digits, dots and dashes"));
            }
            *slot = v.to_string();
        }
    }
    conn.execute(
        "UPDATE today_settings SET briefing_enabled = ?1, briefing_time = ?2, assistant_model = ?3, claude_model = ?4, codex_model = ?5 WHERE id = 1",
        params![s.briefing_enabled, s.briefing_time, s.assistant_model, s.claude_model, s.codex_model],
    )?;
    Ok(s)
}

// --- Handlers ---------------------------------------------------------------------------

macro_rules! conn {
    ($pool:expr) => {
        match $pool.get() {
            Ok(c) => c,
            Err(e) => return server_error(e),
        }
    };
}

fn reply<T: Serialize>(result: Result<T, TodayError>, broadcaster: Option<&Broadcaster>) -> HttpResponse {
    match result {
        Ok(v) => {
            if let Some(b) = broadcaster {
                b.send();
            }
            HttpResponse::Ok().json(v)
        }
        Err(e) => respond(e),
    }
}

pub async fn list_reminders(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    reply(list_reminders_db(&conn).map_err(TodayError::from), None)
}

pub async fn create_reminder(pool: web::Data<DbPool>, body: web::Json<ReminderRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(create_reminder_db(&conn, &body), Some(&b))
}

pub async fn update_reminder(pool: web::Data<DbPool>, path: web::Path<String>, body: web::Json<ReminderRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(update_reminder_db(&conn, &path, &body), Some(&b))
}

pub async fn delete_reminder(pool: web::Data<DbPool>, path: web::Path<String>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    let result = conn
        .execute("DELETE FROM reminders WHERE id = ?1", params![path.as_str()])
        .map_err(TodayError::from)
        .and_then(|n| if n == 0 { Err(TodayError::NotFound("Reminder not found")) } else { Ok(serde_json::json!({"ok": true})) });
    reply(result, Some(&b))
}

pub async fn done_reminder(pool: web::Data<DbPool>, path: web::Path<String>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(done_reminder_db(&conn, &path, Utc::now()), Some(&b))
}

pub async fn snooze_reminder(pool: web::Data<DbPool>, path: web::Path<String>, body: web::Json<SnoozeRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(snooze_reminder_db(&conn, &path, &body), Some(&b))
}

pub async fn list_people(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    reply(list_people_db(&conn, Utc::now()).map_err(TodayError::from), None)
}

pub async fn create_person(pool: web::Data<DbPool>, body: web::Json<PersonRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(create_person_db(&conn, &body, Utc::now()), Some(&b))
}

pub async fn update_person(pool: web::Data<DbPool>, path: web::Path<String>, body: web::Json<PersonRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(update_person_db(&conn, &path, &body, Utc::now()), Some(&b))
}

pub async fn delete_person(pool: web::Data<DbPool>, path: web::Path<String>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    let result = conn
        .execute("DELETE FROM people WHERE id = ?1", params![path.as_str()])
        .map_err(TodayError::from)
        .and_then(|n| if n == 0 { Err(TodayError::NotFound("Person not found")) } else { Ok(serde_json::json!({"ok": true})) });
    reply(result, Some(&b))
}

pub async fn get_settings(pool: web::Data<DbPool>) -> HttpResponse {
    let conn = conn!(pool);
    reply(settings_db(&conn).map_err(TodayError::from), None)
}

pub async fn put_settings(pool: web::Data<DbPool>, body: web::Json<TodaySettingsRequest>, b: web::Data<Broadcaster>) -> HttpResponse {
    let conn = conn!(pool);
    reply(update_settings_db(&conn, &body), Some(&b))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::test_support::{patch, pool, post, put};
    use actix_web::http::StatusCode;
    use serde_json::json;

    fn local(s: &str) -> NaiveDateTime {
        parse_local(s).unwrap()
    }

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn next_time_daily_weekdays_weekly() {
        let fri = local("2026-11-06 09:00");
        let after = local_to_utc(fri);
        assert_eq!(next_after("daily", fri, 6, 11, after), Some(local("2026-11-07 09:00")));
        assert_eq!(next_after("weekdays", fri, 6, 11, after), Some(local("2026-11-09 09:00")), "Friday → Monday");
        assert_eq!(next_after("weekly", fri, 6, 11, after), Some(local("2026-11-13 09:00")));
        assert_eq!(next_after("none", fri, 6, 11, after), None);
    }

    #[test]
    fn next_time_month_end_and_leap_day() {
        let jan31 = local("2027-01-31 10:00");
        let feb = next_after("monthly", jan31, 31, 1, local_to_utc(jan31)).unwrap();
        assert_eq!(feb, local("2027-02-28 10:00"));
        assert_eq!(next_after("monthly", feb, 31, 1, local_to_utc(feb)), Some(local("2027-03-31 10:00")), "the 31st comes back");
        let leap = local("2028-02-29 08:00");
        assert_eq!(next_after("yearly", leap, 29, 2, local_to_utc(leap)), Some(local("2029-02-28 08:00")));
        let nonleap = local("2031-02-28 08:00");
        assert_eq!(next_after("yearly", nonleap, 29, 2, local_to_utc(nonleap)), Some(local("2032-02-29 08:00")));
    }

    #[test]
    fn next_time_keeps_wall_clock_across_dst() {
        // Sofia leaves summer time on 2026-10-25.
        let sat = local("2026-10-24 09:00");
        let sun = next_after("daily", sat, 24, 10, local_to_utc(sat)).unwrap();
        assert_eq!(sun, local("2026-10-25 09:00"));
        assert_eq!(local_to_utc(sat).format("%H:%M").to_string(), "06:00");
        assert_eq!(local_to_utc(sun).format("%H:%M").to_string(), "07:00");
    }

    #[actix_web::test]
    async fn reminder_crud_and_validation() {
        let (_db, pool) = pool("today");
        let bad = post(&pool, "/api/reminders", json!({"title": "x", "at": "tomorrow"})).await;
        assert_eq!(bad.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/reminders", json!({"title": "x", "at": "2026-11-06 09:00", "repeat": "hourly"})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/reminders", json!({"title": " ", "at": "2026-11-06 09:00"})).await.0, StatusCode::BAD_REQUEST);
        let (status, r) = post(&pool, "/api/reminders", json!({"title": "Call  the accountant", "at": "2026-11-06 10:00", "repeat": "weekly", "source": "agent"})).await;
        assert_eq!(status, StatusCode::OK, "{r}");
        assert_eq!((&r["title"], &r["at"], &r["next_at"], &r["state"], &r["source"]),
            (&json!("Call the accountant"), &json!("2026-11-06 10:00"), &json!("2026-11-06T08:00:00Z"), &json!("upcoming"), &json!("agent")));
        let id = r["id"].as_str().unwrap();
        let (_, r) = patch(&pool, &format!("/api/reminders/{id}"), json!({"title": "Call accountant", "at": "2026-11-07 11:30"})).await;
        assert_eq!((&r["title"], &r["at"], &r["repeat"]), (&json!("Call accountant"), &json!("2026-11-07 11:30"), &json!("weekly")));
    }

    #[test]
    fn done_moves_repeat_past_now_and_finishes_once() {
        let (_db, pool) = pool("today");
        let conn = pool.get().unwrap();
        let daily = create_reminder_db(&conn, &ReminderRequest { title: Some("Pills".into()), notes: None, at: Some("2026-11-01 08:00".into()), repeat: Some("daily".into()), source: None }).ok().unwrap();
        conn.execute("UPDATE reminders SET state = 'due' WHERE id = ?1", params![daily.id]).unwrap();
        let now = utc("2026-11-04T10:00:00Z");
        let after = done_reminder_db(&conn, &daily.id, now).ok().unwrap();
        assert_eq!((after.at.as_str(), after.state.as_str()), ("2026-11-05 08:00", "upcoming"), "three days late: the next one after now");
        let once = create_reminder_db(&conn, &ReminderRequest { title: Some("Dentist".into()), notes: None, at: Some("2026-11-04 09:00".into()), repeat: None, source: None }).ok().unwrap();
        assert_eq!(done_reminder_db(&conn, &once.id, now).ok().unwrap().state, "done");
    }

    #[actix_web::test]
    async fn snooze_sets_time_and_upcoming() {
        let (_db, pool) = pool("today");
        let (_, r) = post(&pool, "/api/reminders", json!({"title": "Water plants", "at": "2026-11-03 09:00"})).await;
        let id = r["id"].as_str().unwrap().to_string();
        pool.get().unwrap().execute("UPDATE reminders SET state = 'due', pushed_at = datetime('now')", []).unwrap();
        let (status, r) = post(&pool, &format!("/api/reminders/{id}/snooze"), json!({"until": "2026-11-03 18:00"})).await;
        assert_eq!(status, StatusCode::OK, "{r}");
        assert_eq!((&r["at"], &r["state"]), (&json!("2026-11-03 18:00"), &json!("upcoming")));
        assert_eq!(post(&pool, &format!("/api/reminders/{id}/snooze"), json!({"until": "later"})).await.0, StatusCode::BAD_REQUEST);
    }

    #[test]
    fn person_next_date_and_turns() {
        let (_db, pool) = pool("today");
        let conn = pool.get().unwrap();
        let now = utc("2026-11-03T10:00:00Z");
        let req = |name: &str, m: u32, d: u32, y: Option<i32>| PersonRequest {
            name: Some(name.into()), kind: None, month: Some(m), day: Some(d), year: Some(y), notes: None, source: None,
        };
        let maria = create_person_db(&conn, &req("Maria", 3, 14, Some(1991)), now).ok().unwrap();
        assert_eq!((maria.next_date.as_str(), maria.turns), ("2027-03-14", Some(36)));
        let today = create_person_db(&conn, &req("Ivan", 11, 3, None), now).ok().unwrap();
        assert_eq!((today.next_date.as_str(), today.turns), ("2026-11-03", None), "today counts as next");
        let leap = create_person_db(&conn, &req("Leap", 2, 29, None), now).ok().unwrap();
        assert_eq!(leap.next_date, "2027-02-28");
        let names: Vec<String> = list_people_db(&conn, now).unwrap().into_iter().map(|p| p.name).collect();
        assert_eq!(names, vec!["Ivan", "Leap", "Maria"]);
    }

    #[actix_web::test]
    async fn people_validation() {
        let (_db, pool) = pool("today");
        assert_eq!(post(&pool, "/api/people", json!({"name": "X", "month": 2, "day": 30})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/people", json!({"name": "X", "month": 2, "day": 29, "year": 2023})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(post(&pool, "/api/people", json!({"name": "X", "kind": "pet", "month": 1, "day": 1})).await.0, StatusCode::BAD_REQUEST);
        let (status, p) = post(&pool, "/api/people", json!({"name": "Maria", "month": 3, "day": 14, "year": 1991})).await;
        assert_eq!(status, StatusCode::OK, "{p}");
        let id = p["id"].as_str().unwrap();
        let (_, p) = patch(&pool, &format!("/api/people/{id}"), json!({"year": null, "kind": "anniversary"})).await;
        assert_eq!((&p["year"], &p["kind"]), (&Value::Null, &json!("anniversary")));
    }

    use serde_json::Value;

    #[actix_web::test]
    async fn today_settings_defaults_and_update() {
        let (_db, pool) = pool("today");
        let conn = pool.get().unwrap();
        assert_eq!(
            settings_db(&conn).unwrap(),
            TodaySettings {
                briefing_enabled: true,
                briefing_time: "08:00".into(),
                assistant_model: "auto".into(),
                claude_model: "haiku".into(),
                codex_model: "gpt-6.1-terra".into()
            }
        );
        assert_eq!(put(&pool, "/api/today/settings", json!({"briefing_time": "25:00"})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(put(&pool, "/api/today/settings", json!({"assistant_model": "gpt"})).await.0, StatusCode::BAD_REQUEST);
        assert_eq!(put(&pool, "/api/today/settings", json!({"codex_model": "rm -rf"})).await.0, StatusCode::BAD_REQUEST);
        let (status, s) = put(&pool, "/api/today/settings", json!({"briefing_time": "07:30", "assistant_model": "codex"})).await;
        assert_eq!(status, StatusCode::OK, "{s}");
        assert_eq!((&s["briefing_time"], &s["assistant_model"]), (&json!("07:30"), &json!("codex")));
    }
}
