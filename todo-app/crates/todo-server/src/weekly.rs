//! The weekly recap: weeks run Monday to Sunday in daily-update days (Sofia 08:00 to 08:00).

#![allow(dead_code)] // used by later weekly recap tasks

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveTime, TimeZone, Utc};

use crate::cron::TZ;
use crate::updates::{day_window, parse_day};

const FALLBACK_HOUR: u32 = 10;

fn fmt(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

fn monday(d: NaiveDate) -> NaiveDate {
    d - Duration::days(i64::from(d.weekday().num_days_from_monday()))
}

/// The Monday of the week that `day` (YYYY-MM-DD) belongs to.
pub(crate) fn week_of_day(day: &str) -> Option<String> {
    Some(fmt(monday(parse_day(day)?)))
}

/// The seven days of the week starting on `week` (which must be a Monday).
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
}
