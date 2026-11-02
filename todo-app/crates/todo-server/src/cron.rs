//! 5-field cron (minute hour day-of-month month day-of-week), evaluated in a time zone.
//!
//! Fields take `*`, numbers, `a-b`, lists `a,b` and steps `*/n` / `a-b/n`. Day of week is 0–7
//! with 0 and 7 both Sunday. When day of month and day of week are both restricted, either
//! matching is enough (as in Vixie cron). Daylight saving: a time that happens twice fires
//! once (the earlier instant); a time that doesn't exist fires at the first valid minute after
//! the gap.

use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc};
use chrono_tz::Tz;

pub(crate) const TZ: Tz = chrono_tz::Europe::Sofia;

/// How far ahead `next_after` looks before giving up.
const SEARCH_DAYS: i64 = 366;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Cron {
    minutes: u64,
    hours: u64,
    days: u64,
    months: u64,
    weekdays: u64,
    days_restricted: bool,
    weekdays_restricted: bool,
}

fn field(text: &str, min: u32, max: u32, name: &str) -> Result<u64, String> {
    let mut bits = 0u64;
    for part in text.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => {
                let step: u32 = s.parse().map_err(|_| format!("{name}: bad step in '{part}'"))?;
                if step == 0 {
                    return Err(format!("{name}: step must be at least 1"));
                }
                (r, step)
            }
            None => (part, 1),
        };
        let (lo, hi) = if range == "*" {
            (min, max)
        } else if let Some((a, b)) = range.split_once('-') {
            let a: u32 = a.parse().map_err(|_| format!("{name}: bad number in '{part}'"))?;
            let b: u32 = b.parse().map_err(|_| format!("{name}: bad number in '{part}'"))?;
            (a, b)
        } else {
            let a: u32 = range.parse().map_err(|_| format!("{name}: bad number in '{part}'"))?;
            (a, if step > 1 { max } else { a })
        };
        if lo < min || hi > max || lo > hi {
            return Err(format!("{name}: '{part}' is outside {min}-{max}"));
        }
        let mut v = lo;
        while v <= hi {
            bits |= 1 << v;
            v += step;
        }
    }
    Ok(bits)
}

pub(crate) fn parse(expr: &str) -> Result<Cron, String> {
    let parts: Vec<&str> = expr.split_whitespace().collect();
    if parts.len() != 5 {
        return Err("cron needs 5 fields: minute hour day-of-month month day-of-week".into());
    }
    let mut weekdays = field(parts[4], 0, 7, "day of week")?;
    if weekdays & (1 << 7) != 0 {
        weekdays |= 1; // 7 is Sunday too
    }
    Ok(Cron {
        minutes: field(parts[0], 0, 59, "minute")?,
        hours: field(parts[1], 0, 23, "hour")?,
        days: field(parts[2], 1, 31, "day of month")?,
        months: field(parts[3], 1, 12, "month")?,
        weekdays,
        days_restricted: parts[2] != "*",
        weekdays_restricted: parts[4] != "*",
    })
}

impl Cron {
    fn day_matches(&self, date: NaiveDate) -> bool {
        if self.months & (1 << date.month()) == 0 {
            return false;
        }
        let dom = self.days & (1 << date.day()) != 0;
        let dow = self.weekdays & (1 << date.weekday().num_days_from_sunday()) != 0;
        match (self.days_restricted, self.weekdays_restricted) {
            (true, true) => dom || dow,
            (true, false) => dom,
            (false, true) => dow,
            (false, false) => true,
        }
    }

    fn time_matches(&self, t: &NaiveDateTime) -> bool {
        self.hours & (1 << t.hour()) != 0 && self.minutes & (1 << t.minute()) != 0
    }

    /// The first matching wall-clock minute strictly after `after`, in `tz`.
    pub(crate) fn next_after(&self, after: DateTime<Utc>, tz: Tz) -> Option<DateTime<Utc>> {
        let start = after.with_timezone(&tz).naive_local();
        let mut t = start.with_second(0)?.with_nanosecond(0)? + Duration::minutes(1);
        let end = start + Duration::days(SEARCH_DAYS);
        // A matching minute that falls in a spring-forward gap: fire at the first valid minute.
        let mut pending_gap = false;
        while t <= end {
            if !pending_gap && !self.day_matches(t.date()) {
                t = t.date().succ_opt()?.and_hms_opt(0, 0, 0)?;
                continue;
            }
            let matches = pending_gap || self.time_matches(&t);
            if matches {
                match tz.from_local_datetime(&t) {
                    LocalResult::Single(dt) if dt.with_timezone(&Utc) > after => return Some(dt.with_timezone(&Utc)),
                    LocalResult::Ambiguous(early, _) if early.with_timezone(&Utc) > after => {
                        return Some(early.with_timezone(&Utc))
                    }
                    LocalResult::None => pending_gap = true,
                    _ => {}
                }
            }
            t += Duration::minutes(1);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(y, mo, d, h, mi, 0).unwrap()
    }

    fn sofia(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> DateTime<Utc> {
        TZ.with_ymd_and_hms(y, mo, d, h, mi, 0).single().unwrap().with_timezone(&Utc)
    }

    #[test]
    fn parse_rejects_bad_fields() {
        for bad in ["60 * * * *", "* * *", "a * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "*/0 * * * *", "5-1 * * * *"] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        assert!(parse("*/15 1-5,7 1,15 * 1-5/2").is_ok());
    }

    #[test]
    fn next_after_every_15_minutes() {
        let c = parse("*/15 * * * *").unwrap();
        assert_eq!(c.next_after(sofia(2026, 11, 2, 10, 7), TZ), Some(sofia(2026, 11, 2, 10, 15)));
        assert_eq!(c.next_after(sofia(2026, 11, 2, 10, 15), TZ), Some(sofia(2026, 11, 2, 10, 30)), "strictly after");
    }

    #[test]
    fn next_after_weekday_morning() {
        let c = parse("0 8 * * 1-5").unwrap();
        // 2026-11-07 is a Saturday.
        assert_eq!(c.next_after(sofia(2026, 11, 7, 9, 0), TZ), Some(sofia(2026, 11, 9, 8, 0)));
    }

    #[test]
    fn dom_or_dow_either_matches() {
        // The 1st of the month OR any Friday. 2026-11-06 is a Friday.
        let c = parse("0 9 1 * 5").unwrap();
        assert_eq!(c.next_after(sofia(2026, 11, 2, 0, 0), TZ), Some(sofia(2026, 11, 6, 9, 0)));
        assert_eq!(c.next_after(sofia(2026, 11, 27, 10, 0), TZ), Some(sofia(2026, 12, 1, 9, 0)));
    }

    #[test]
    fn sunday_is_0_and_7() {
        // 2026-11-08 is a Sunday.
        for expr in ["0 10 * * 0", "0 10 * * 7"] {
            assert_eq!(parse(expr).unwrap().next_after(sofia(2026, 11, 7, 12, 0), TZ), Some(sofia(2026, 11, 8, 10, 0)), "{expr}");
        }
    }

    #[test]
    fn cron_dst_fall_back_fires_once() {
        // 2026-10-25: 04:00 EEST becomes 03:00 EET, so 03:30 happens twice.
        let c = parse("30 3 * * *").unwrap();
        let first = c.next_after(utc(2026, 10, 24, 12, 0), TZ).unwrap();
        assert_eq!(first, utc(2026, 10, 25, 0, 30), "the earlier 03:30 (EEST)");
        let second = c.next_after(first, TZ).unwrap();
        assert_eq!(second, utc(2026, 10, 26, 1, 30), "next day, not the repeated hour");
    }

    #[test]
    fn cron_dst_spring_forward_skips_to_next_valid() {
        // 2026-03-29: 03:00 EET becomes 04:00 EEST, so 03:30 doesn't exist.
        let c = parse("30 3 * * *").unwrap();
        let fire = c.next_after(utc(2026, 3, 28, 12, 0), TZ).unwrap();
        assert_eq!(fire, utc(2026, 3, 29, 1, 0), "04:00 EEST, the first valid minute");
        assert_eq!(c.next_after(fire, TZ).unwrap(), utc(2026, 3, 30, 0, 30), "once");
    }
}
