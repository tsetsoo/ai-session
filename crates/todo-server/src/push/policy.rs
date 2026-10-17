//! Pure push decisions: which status transitions are events, per-turn debounce, suppression
//! and quiet hours. No IO, so every rule is tested here.

use std::collections::HashMap;
use std::time::SystemTime;

use chrono::{DateTime, NaiveTime, Utc};
use todo_shared::{ConversationStatus, PushSettings, QuietHours};

/// One accepted status post: the conversation's status before and after.
#[derive(Debug, Clone, PartialEq)]
pub struct Transition {
    pub todo_id: String,
    pub old: ConversationStatus,
    pub new: ConversationStatus,
    /// The hook saw recent keyboard activity in the conversation's tmux session
    pub attended: bool,
    pub at: SystemTime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// The conversation needs the user
    Waiting,
    /// A busy run went idle after `minutes`
    Done { minutes: u32 },
    /// A repeated `waiting` post saying the user touched the terminal since the prompt
    AttendedRecheck,
}

#[derive(Debug, Default)]
struct TurnState {
    /// `None` when the turn's start wasn't seen (Codex, or a restart mid-turn)
    started_at: Option<SystemTime>,
    waiting_sent: bool,
    done_sent: bool,
}

/// Per-conversation turns: a turn starts at the first `busy` after `idle`/`unknown` and
/// ends at `idle`. Only pushes that were sent (`mark_sent`) use up the turn's one push.
/// In memory: after a restart the worst case is one repeated or missed push.
#[derive(Debug, Default)]
pub struct TurnTracker {
    turns: HashMap<String, TurnState>,
}

impl TurnTracker {
    pub fn on_transition(&mut self, t: &Transition) -> Option<Event> {
        use ConversationStatus::{Busy, Idle, Waiting};
        match (t.old, t.new) {
            (Busy | Waiting, Busy) => {
                self.turns.entry(t.todo_id.clone()).or_default();
                None
            }
            (_, Busy) => {
                self.turns.insert(t.todo_id.clone(), TurnState { started_at: Some(t.at), ..TurnState::default() });
                None
            }
            (Waiting, Waiting) => t.attended.then_some(Event::AttendedRecheck),
            (_, Waiting) => {
                let turn = self.turns.entry(t.todo_id.clone()).or_default();
                (!turn.waiting_sent).then_some(Event::Waiting)
            }
            (Idle, Idle) => None,
            (_, Idle) => {
                let turn = self.turns.remove(&t.todo_id)?;
                let started = turn.started_at.filter(|_| !turn.done_sent)?;
                let secs = t.at.duration_since(started).unwrap_or_default().as_secs();
                Some(Event::Done { minutes: u32::try_from(secs / 60).unwrap_or(u32::MAX) })
            }
            _ => None,
        }
    }

    /// Record that a push for `event` went out, so the turn sends no other one. A turn that
    /// already ended (the send took a while) is left ended.
    pub fn mark_sent(&mut self, todo_id: &str, event: Event) {
        let Some(turn) = self.turns.get_mut(todo_id) else { return };
        match event {
            Event::Waiting => turn.waiting_sent = true,
            Event::Done { .. } => turn.done_sent = true,
            Event::AttendedRecheck => {}
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Suppress {
    Disabled,
    Muted,
    Attended,
    Viewing,
    DoneBelowThreshold,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Delivery {
    /// Quiet hours: deliver silently
    pub passive: bool,
}

/// What `decide` needs to know, read at decision time.
#[derive(Debug, Clone)]
pub struct Ctx<'a> {
    pub settings: &'a PushSettings,
    /// The todo or its section is muted
    pub muted: bool,
    pub attended: bool,
    /// Some client is showing this conversation
    pub viewing: bool,
    pub now: DateTime<Utc>,
}

pub fn decide(event: Event, ctx: &Ctx) -> Result<Delivery, Suppress> {
    match event {
        Event::Waiting if !ctx.settings.notify_waiting => return Err(Suppress::Disabled),
        Event::Done { minutes } => match ctx.settings.done_after_minutes {
            None => return Err(Suppress::Disabled),
            Some(threshold) if minutes < threshold => return Err(Suppress::DoneBelowThreshold),
            Some(_) => {}
        },
        Event::AttendedRecheck => return Err(Suppress::Attended),
        Event::Waiting => {}
    }
    if ctx.muted {
        return Err(Suppress::Muted);
    }
    if ctx.attended {
        return Err(Suppress::Attended);
    }
    if ctx.viewing {
        return Err(Suppress::Viewing);
    }
    let passive = ctx.settings.quiet_hours.as_ref().is_some_and(|q| in_quiet_hours(q, ctx.now));
    Ok(Delivery { passive })
}

fn parse_hhmm(s: &str) -> Option<NaiveTime> {
    if s.len() != 5 {
        return None;
    }
    NaiveTime::parse_from_str(s, "%H:%M").ok()
}

/// `HH:MM` times and a known IANA timezone.
///
/// # Errors
/// A message naming the bad field.
pub fn validate_quiet_hours(q: &QuietHours) -> Result<(), String> {
    parse_hhmm(&q.start).ok_or("quiet_hours.start must be HH:MM")?;
    parse_hhmm(&q.end).ok_or("quiet_hours.end must be HH:MM")?;
    q.tz.parse::<chrono_tz::Tz>().map_err(|_| "quiet_hours.tz is not a known IANA timezone")?;
    Ok(())
}

/// `now` falls in `[start, end)` in the window's own timezone; `end` before `start` crosses
/// midnight. Invalid settings never count as quiet.
pub fn in_quiet_hours(q: &QuietHours, now: DateTime<Utc>) -> bool {
    let (Some(start), Some(end), Ok(tz)) = (parse_hhmm(&q.start), parse_hhmm(&q.end), q.tz.parse::<chrono_tz::Tz>()) else {
        return false;
    };
    let local = now.with_timezone(&tz).time();
    if start <= end {
        start <= local && local < end
    } else {
        local >= start || local < end
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use std::time::{Duration, UNIX_EPOCH};
    use todo_shared::{ConversationStatus::*, PushSettings, QuietHours};

    fn t(old: ConversationStatus, new: ConversationStatus, secs: u64) -> Transition {
        Transition { todo_id: "t1".into(), old, new, attended: false, at: UNIX_EPOCH + Duration::from_secs(secs) }
    }

    fn ctx(settings: &PushSettings) -> Ctx<'_> {
        Ctx { settings, muted: false, attended: false, viewing: false, now: chrono::Utc.with_ymd_and_hms(2026, 10, 17, 12, 0, 0).unwrap() }
    }

    fn quiet(start: &str, end: &str, tz: &str) -> QuietHours {
        QuietHours { start: start.into(), end: end.into(), tz: tz.into() }
    }

    fn utc(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> chrono::DateTime<chrono::Utc> {
        chrono::Utc.with_ymd_and_hms(y, mo, d, h, mi, 0).unwrap()
    }

    #[test]
    fn busy_then_waiting_pushes_once_per_turn() {
        let mut turns = TurnTracker::default();
        assert_eq!(turns.on_transition(&t(Idle, Busy, 0)), None);
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 10)), Some(Event::Waiting));
        turns.mark_sent("t1", Event::Waiting);
        assert_eq!(turns.on_transition(&t(Waiting, Busy, 20)), None, "answered");
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 30)), None, "second prompt in the same turn");
    }

    #[test]
    fn suppressed_waiting_does_not_use_up_turn() {
        let mut turns = TurnTracker::default();
        turns.on_transition(&t(Idle, Busy, 0));
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 10)), Some(Event::Waiting));
        // Not sent (you were there): no mark_sent.
        turns.on_transition(&t(Waiting, Busy, 20));
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 30)), Some(Event::Waiting));
    }

    #[test]
    fn sent_after_turn_ended_does_not_silence_next_prompt() {
        // Codex (no busy): the push for prompt 1 lands after the turn already went idle.
        let mut turns = TurnTracker::default();
        assert_eq!(turns.on_transition(&t(Unknown, Waiting, 0)), Some(Event::Waiting));
        turns.on_transition(&t(Waiting, Idle, 10));
        turns.mark_sent("t1", Event::Waiting);
        assert_eq!(turns.on_transition(&t(Idle, Waiting, 20)), Some(Event::Waiting));
    }

    #[test]
    fn idle_resets_turn() {
        let mut turns = TurnTracker::default();
        turns.on_transition(&t(Idle, Busy, 0));
        turns.on_transition(&t(Busy, Waiting, 10));
        turns.mark_sent("t1", Event::Waiting);
        turns.on_transition(&t(Waiting, Idle, 20));
        turns.on_transition(&t(Idle, Busy, 30));
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 40)), Some(Event::Waiting), "a new turn");
    }

    #[test]
    fn repeat_waiting_post_is_not_a_transition() {
        let mut turns = TurnTracker::default();
        // After a restart the tracker is empty and the first post may be waiting → waiting.
        assert_eq!(turns.on_transition(&t(Waiting, Waiting, 0)), None);
        assert_eq!(turns.on_transition(&t(Busy, Waiting, 5)), Some(Event::Waiting));
        assert_eq!(turns.on_transition(&t(Waiting, Waiting, 10)), None);
        let recheck = Transition { attended: true, ..t(Waiting, Waiting, 12) };
        assert_eq!(turns.on_transition(&recheck), Some(Event::AttendedRecheck));
    }

    #[test]
    fn done_only_after_threshold_and_never_for_codex_without_busy() {
        let mut turns = TurnTracker::default();
        turns.on_transition(&t(Idle, Busy, 0));
        assert_eq!(turns.on_transition(&t(Busy, Idle, 14 * 60 + 30)), Some(Event::Done { minutes: 14 }));
        assert_eq!(turns.on_transition(&t(Idle, Idle, 15 * 60)), None, "idle_prompt repeat");

        let mut settings = PushSettings::default();
        assert_eq!(decide(Event::Done { minutes: 14 }, &ctx(&settings)), Err(Suppress::Disabled), "off by default");
        settings.done_after_minutes = Some(15);
        assert_eq!(decide(Event::Done { minutes: 14 }, &ctx(&settings)), Err(Suppress::DoneBelowThreshold));
        assert_eq!(decide(Event::Done { minutes: 15 }, &ctx(&settings)), Ok(Delivery { passive: false }));

        // Codex: waiting/idle only, never busy.
        let mut codex = TurnTracker::default();
        assert_eq!(codex.on_transition(&t(Unknown, Waiting, 0)), Some(Event::Waiting));
        assert_eq!(codex.on_transition(&t(Waiting, Idle, 600)), None);
    }

    #[test]
    fn attended_and_viewing_suppress() {
        let settings = PushSettings::default();
        assert_eq!(decide(Event::Waiting, &ctx(&settings)), Ok(Delivery { passive: false }));
        assert_eq!(decide(Event::Waiting, &Ctx { attended: true, ..ctx(&settings) }), Err(Suppress::Attended));
        assert_eq!(decide(Event::Waiting, &Ctx { viewing: true, ..ctx(&settings) }), Err(Suppress::Viewing));
        let off = PushSettings { notify_waiting: false, ..PushSettings::default() };
        assert_eq!(decide(Event::Waiting, &ctx(&off)), Err(Suppress::Disabled));
    }

    #[test]
    fn muted_suppresses() {
        let settings = PushSettings { done_after_minutes: Some(1), ..PushSettings::default() };
        assert_eq!(decide(Event::Waiting, &Ctx { muted: true, ..ctx(&settings) }), Err(Suppress::Muted));
        assert_eq!(decide(Event::Done { minutes: 5 }, &Ctx { muted: true, ..ctx(&settings) }), Err(Suppress::Muted));
    }

    #[test]
    fn quiet_hours_overnight_wrap() {
        let q = quiet("22:30", "07:30", "UTC");
        assert!(in_quiet_hours(&q, utc(2026, 10, 17, 23, 0)));
        assert!(in_quiet_hours(&q, utc(2026, 10, 18, 7, 29)));
        assert!(!in_quiet_hours(&q, utc(2026, 10, 18, 7, 30)));
        assert!(!in_quiet_hours(&q, utc(2026, 10, 17, 12, 0)));
        let day = quiet("12:00", "14:00", "UTC");
        assert!(in_quiet_hours(&day, utc(2026, 10, 17, 13, 0)));
        assert!(!in_quiet_hours(&day, utc(2026, 10, 17, 14, 0)));
        assert!(!in_quiet_hours(&quiet("10:00", "10:00", "UTC"), utc(2026, 10, 17, 10, 0)), "empty window");
    }

    #[test]
    fn quiet_hours_respect_tz_not_pi_tz() {
        // 20:00 UTC is 23:00 in Sofia (EEST): quiet there, not in London or UTC.
        let q = quiet("22:30", "07:30", "Europe/Sofia");
        assert!(in_quiet_hours(&q, utc(2026, 10, 17, 20, 0)));
        assert!(!in_quiet_hours(&quiet("22:30", "07:30", "Europe/London"), utc(2026, 10, 17, 20, 0)));
    }

    #[test]
    fn quiet_hours_dst_day() {
        // Sofia leaves summer time on 2026-10-25: 05:00 UTC is 08:00 the day before, 07:00 that day.
        let q = quiet("22:30", "07:30", "Europe/Sofia");
        assert!(!in_quiet_hours(&q, utc(2026, 10, 24, 5, 0)));
        assert!(in_quiet_hours(&q, utc(2026, 10, 25, 5, 0)));
    }

    #[test]
    fn quiet_hours_mark_passive_not_drop() {
        let settings = PushSettings { quiet_hours: Some(quiet("00:00", "23:59", "UTC")), ..PushSettings::default() };
        assert_eq!(decide(Event::Waiting, &ctx(&settings)), Ok(Delivery { passive: true }));
    }

    #[test]
    fn quiet_hours_validation() {
        assert!(validate_quiet_hours(&quiet("22:30", "07:30", "Europe/Sofia")).is_ok());
        assert!(validate_quiet_hours(&quiet("25:00", "07:30", "UTC")).is_err());
        assert!(validate_quiet_hours(&quiet("22:30", "7.30", "UTC")).is_err());
        assert!(validate_quiet_hours(&quiet("22:30", "07:30", "Mars/Olympus")).is_err());
    }
}
