//! Resume a conversation once its usage limit resets.
//!
//! Claude continues on its own after a session limit (its `autoContinueAtUsageLimit`), so only
//! Codex conversations are resumed automatically here. Either tool gets the one-tap Resume
//! after a weekly or unknown limit.
//!
//! The computer's status service decides when; the hub keeps what must agree across apps,
//! processes and computers: the per-conversation toggle, the attempt count (at most 3
//! automatic resumes in 24 hours), the planned time the apps show, the one-tap offer, and a
//! lease so exactly one sender types the message. Nothing here sends a push.
//!
//! `resume_at`, `resume_offer` and the lease belong to one pause: `set_status_db` clears them
//! when a new pause arrives or the pause ends.

use actix_web::{web, HttpResponse};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use todo_shared::{
    ConversationResumeRequest, ConversationResumeState, ConversationStatus, LimitPause, SetConversationResumeRequest,
};

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, load_conversation_by_id, not_found, server_error};
use crate::db::DbPool;

/// Automatic resumes allowed per conversation in `ATTEMPT_WINDOW`.
pub(crate) const MAX_ATTEMPTS: usize = 3;
const ATTEMPT_WINDOW: Duration = Duration::hours(24);
/// A limit hit this soon after a resume counts as another attempt: the resume didn't help.
const QUICK_REHIT: Duration = Duration::minutes(10);
/// How long a claim holds the conversation: enough to reopen a session (up to 2 min), wait
/// for its prompt (90 s) and type, with room to spare.
const LEASE: Duration = Duration::minutes(6);

fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn parse(at: Option<&str>) -> Option<DateTime<Utc>> {
    at.and_then(|at| DateTime::parse_from_rfc3339(at).ok()).map(|at| at.with_timezone(&Utc))
}

/// The attempts still inside the window, oldest first.
fn recent_attempts(stored: Option<&str>, now: DateTime<Utc>) -> Vec<DateTime<Utc>> {
    let list: Vec<String> = stored.and_then(|s| serde_json::from_str(s).ok()).unwrap_or_default();
    let mut times: Vec<_> = list.iter().filter_map(|s| parse(Some(s))).filter(|at| now - *at < ATTEMPT_WINDOW).collect();
    times.sort();
    times
}

fn attempts_json(times: &[DateTime<Utc>]) -> String {
    serde_json::to_string(&times.iter().map(|at| iso(*at)).collect::<Vec<_>>()).unwrap_or_else(|_| "[]".into())
}

/// Called in `set_status_db`'s transaction when a new pause is stored. A pause that soon
/// after a resume counts as an attempt; at the cap the toggle goes off, with the reason.
pub(crate) fn note_limit_hit(tx: &Transaction, conversation_id: &str, now: DateTime<Utc>) -> rusqlite::Result<()> {
    let (last, stored, on): (Option<String>, Option<String>, bool) = tx.query_row(
        "SELECT resume_last_at, resume_attempts, resume_on_reset FROM conversations WHERE id = ?1",
        params![conversation_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let mut attempts = recent_attempts(stored.as_deref(), now);
    if parse(last.as_deref()).is_some_and(|last| now - last < QUICK_REHIT) {
        attempts.push(now);
    }
    let capped = on && attempts.len() >= MAX_ATTEMPTS;
    tx.execute(
        "UPDATE conversations SET resume_attempts = ?2,
             resume_on_reset = CASE WHEN ?3 THEN 0 ELSE resume_on_reset END,
             resume_off_reason = CASE WHEN ?3 THEN 'cap' ELSE resume_off_reason END
         WHERE id = ?1",
        params![conversation_id, attempts_json(&attempts), capped],
    )?;
    Ok(())
}

struct Row {
    id: String,
    tmux_name: String,
    cwd: String,
    status: ConversationStatus,
    paused_kind: Option<String>,
    paused_until: Option<String>,
    reviewed: bool,
    on: bool,
    off_reason: Option<String>,
    attempts: Option<String>,
    resume_at: Option<String>,
    offer: bool,
    token: Option<String>,
    lease_until: Option<String>,
}

fn load(tx: &Transaction, tool: &str, session_id: &str) -> rusqlite::Result<Option<Row>> {
    tx.query_row(
        "SELECT id, tmux_name, cwd, status, paused_kind, paused_until, reviewed, resume_on_reset, resume_off_reason,
                resume_attempts, resume_at, resume_offer, resume_token, resume_lease_until
         FROM conversations WHERE tool = ?1 AND session_id = ?2",
        params![tool, session_id],
        |r| {
            let status: String = r.get(3)?;
            Ok(Row {
                id: r.get(0)?,
                tmux_name: r.get(1)?,
                cwd: r.get(2)?,
                status: ConversationStatus::parse(&status).unwrap_or(ConversationStatus::Unknown),
                paused_kind: r.get(4)?,
                paused_until: r.get(5)?,
                reviewed: r.get(6)?,
                on: r.get(7)?,
                off_reason: r.get(8)?,
                attempts: r.get(9)?,
                resume_at: r.get(10)?,
                offer: r.get(11)?,
                token: r.get(12)?,
                lease_until: r.get(13)?,
            })
        },
    )
    .optional()
}

impl Row {
    fn paused(&self) -> bool {
        self.status == ConversationStatus::Idle && self.paused_kind.is_some()
    }

    fn state(&self, granted: bool, reason: Option<&str>) -> ConversationResumeState {
        ConversationResumeState {
            conversation_id: self.id.clone(),
            tmux_name: self.tmux_name.clone(),
            cwd: self.cwd.clone(),
            status: self.status,
            paused: self.paused_kind.clone().filter(|_| self.paused()).map(|kind| LimitPause {
                kind,
                resets_at: self.paused_until.clone(),
                resume_at: self.resume_at.clone(),
                offer: self.offer,
            }),
            reviewed: self.reviewed,
            resume_on_reset: self.on,
            resume_off_reason: self.off_reason.clone(),
            granted,
            reason: reason.map(Into::into),
        }
    }

    /// Why this claim can't have the conversation now, if anything.
    fn refusal(&self, req: &ConversationResumeRequest, now: DateTime<Utc>) -> Option<&'static str> {
        if self.status == ConversationStatus::Closed {
            return Some("closed");
        }
        if !self.paused() {
            return Some("not_paused");
        }
        let held = self.token.is_some()
            && self.token.as_deref() != req.token.as_deref()
            && parse(self.lease_until.as_deref()).is_some_and(|until| until > now);
        if held {
            return Some("leased");
        }
        if req.manual {
            return None;
        }
        if req.tool.trim() == "claude" {
            return Some("claude_continues");
        }
        if !self.on {
            return Some("toggle_off");
        }
        if self.paused_kind.as_deref() != Some("session") {
            return Some("not_session");
        }
        if self.reviewed {
            return Some("reviewed");
        }
        if recent_attempts(self.attempts.as_deref(), now).len() >= MAX_ATTEMPTS {
            return Some("cap");
        }
        None
    }
}

pub(crate) enum ResumeError {
    NotFound,
    Bad(&'static str),
    Db(rusqlite::Error),
}

impl From<rusqlite::Error> for ResumeError {
    fn from(e: rusqlite::Error) -> Self {
        ResumeError::Db(e)
    }
}

/// Apply one action from the computer. Returns the state after it and whether anything the
/// apps show changed.
pub(crate) fn resume_action_db(
    conn: &Connection,
    req: &ConversationResumeRequest,
    now: DateTime<Utc>,
) -> Result<(ConversationResumeState, bool), ResumeError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    let Some(mut row) = load(&tx, req.tool.trim(), req.session_id.trim())? else {
        return Err(ResumeError::NotFound);
    };
    let before = (row.on, row.off_reason.clone(), row.resume_at.clone(), row.offer);
    let mut granted = false;
    let mut reason = None;
    let token_matches = row.token.is_some() && row.token.as_deref() == req.token.as_deref();
    match req.action.as_str() {
        "state" => {}
        "arm" => {
            let at = match req.resume_at.as_deref() {
                Some(at) => Some(parse(Some(at)).map(iso).ok_or(ResumeError::Bad("resume_at must be an RFC 3339 time"))?),
                None => None,
            };
            let keep = row.paused() && row.on && row.paused_kind.as_deref() == Some("session") && req.tool.trim() != "claude";
            row.resume_at = at.filter(|_| keep);
        }
        "disarm" => row.resume_at = None,
        "offer" => {
            if row.paused() {
                row.offer = true;
                row.resume_at = None;
            } else {
                reason = Some("not_paused");
            }
        }
        "claim" => {
            if req.token.as_deref().is_none_or(|t| t.is_empty() || t.len() > 100) {
                return Err(ResumeError::Bad("claim needs a token"));
            }
            match row.refusal(req, now) {
                Some("cap") => {
                    // Quietly stop trying; the user can still tap Resume.
                    row.on = false;
                    row.off_reason = Some("cap".into());
                    row.resume_at = None;
                    row.offer = true;
                    reason = Some("cap");
                }
                Some(why) => reason = Some(why),
                None => {
                    granted = true;
                    row.token = req.token.clone();
                    row.lease_until = Some(iso(now + LEASE));
                    row.resume_at = None;
                    row.offer = false;
                    if !req.manual {
                        let mut attempts = recent_attempts(row.attempts.as_deref(), now);
                        attempts.push(now);
                        row.attempts = Some(attempts_json(&attempts));
                    }
                }
            }
        }
        "sent" => {
            if token_matches {
                granted = true;
                tx.execute("UPDATE conversations SET resume_last_at = ?2 WHERE id = ?1", params![row.id, iso(now)])?;
            } else {
                reason = Some("leased");
            }
        }
        "release" => {
            if token_matches {
                granted = true;
                // Nothing was typed: the claim's attempt doesn't count toward the cap.
                if let Some(claimed) = parse(row.lease_until.as_deref()).map(|until| until - LEASE) {
                    let mut attempts = recent_attempts(row.attempts.as_deref(), now);
                    if let Some(i) = attempts.iter().rposition(|at| *at == claimed) {
                        attempts.remove(i);
                        row.attempts = Some(attempts_json(&attempts));
                    }
                }
                row.token = None;
                row.lease_until = None;
            } else {
                reason = Some("leased");
            }
        }
        _ => return Err(ResumeError::Bad("action must be state, arm, disarm, offer, claim, sent or release")),
    }
    tx.execute(
        "UPDATE conversations SET resume_on_reset = ?2, resume_off_reason = ?3, resume_attempts = ?4, resume_at = ?5,
             resume_offer = ?6, resume_token = ?7, resume_lease_until = ?8
         WHERE id = ?1",
        params![row.id, row.on, row.off_reason, row.attempts, row.resume_at, row.offer, row.token, row.lease_until],
    )?;
    tx.commit()?;
    let changed = before != (row.on, row.off_reason.clone(), row.resume_at.clone(), row.offer);
    Ok((row.state(granted, reason), changed))
}

/// Switch the toggle. On starts a fresh count; off cancels a planned resume.
pub(crate) fn set_resume_db(conn: &Connection, id: &str, on: bool) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE conversations SET resume_on_reset = ?2, resume_off_reason = NULL,
             resume_attempts = CASE WHEN ?2 THEN NULL ELSE resume_attempts END,
             resume_at = CASE WHEN ?2 THEN resume_at ELSE NULL END
         WHERE id = ?1",
        params![id, on],
    )
}

/// `PUT /api/conversations/{id}/resume`: the app's toggle.
pub async fn set_conversation_resume_by_id(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    body: web::Json<SetConversationResumeRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    let id = path.into_inner();
    match set_resume_db(&conn, &id, body.resume_on_reset) {
        Ok(0) => return not_found("Conversation not found"),
        Ok(_) => {}
        Err(e) => return server_error(e),
    }
    broadcaster.send();
    match load_conversation_by_id(&conn, &id) {
        Ok(Some(c)) => HttpResponse::Ok().json(c),
        Ok(None) => not_found("Conversation not found"),
        Err(e) => server_error(e),
    }
}

/// `POST /api/conversations/resume`: the computer's status service, by tool and session id.
pub async fn post_conversation_resume(
    pool: web::Data<DbPool>,
    body: web::Json<ConversationResumeRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match resume_action_db(&conn, &body, Utc::now()) {
        Ok((state, changed)) => {
            if changed {
                broadcaster.send();
            }
            HttpResponse::Ok().json(state)
        }
        Err(ResumeError::NotFound) => not_found("Unknown session_id"),
        Err(ResumeError::Bad(message)) => bad_request(message),
        Err(ResumeError::Db(e)) => server_error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversations::{open_conversation_db, set_status_db};
    use crate::test_support::{pool, post, put};
    use todo_shared::ConversationStatusRequest;

    const TODO: &str = "0f3a9c21-aaaa-4bbb-8ccc-123456789abc";

    fn seed(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO computers (id, name, hostname, username) VALUES ('m1', 'Mac', 'mac.tailnet', 'me');
             INSERT INTO section_computers (section, computer_id) VALUES ('I', 'm1');
             INSERT INTO projects (id, name, section, folder) VALUES ('p1', 'programming', 'I', '~/programming');
             INSERT INTO todos (id, section, title, project_id) VALUES ('0f3a9c21-aaaa-4bbb-8ccc-123456789abc', 'I', 'Resume', 'p1');",
        )
        .unwrap();
    }

    /// Minutes after a start 15 hours ago: pauses are stamped with the real clock.
    fn at(minutes: i64) -> DateTime<Utc> {
        Utc::now() - Duration::hours(15) + Duration::minutes(minutes)
    }

    fn request(session: &str, action: &str) -> ConversationResumeRequest {
        ConversationResumeRequest { tool: "codex".into(), session_id: session.into(), action: action.into(), ..Default::default() }
    }

    fn claim(session: &str, token: &str, manual: bool) -> ConversationResumeRequest {
        ConversationResumeRequest { token: Some(token.into()), manual, ..request(session, "claim") }
    }

    fn pause(conn: &Connection, session: &str, kind: &str) {
        let pause = LimitPause { kind: kind.into(), resets_at: Some("2026-11-06T21:00:00Z".into()), ..Default::default() };
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, turn_started_ns: Some(1), ..Default::default() };
        set_status_db(conn, "codex", session, &busy).unwrap();
        let idle = ConversationStatusRequest { status: ConversationStatus::Idle, paused: Some(pause), ..Default::default() };
        set_status_db(conn, "codex", session, &idle).unwrap();
    }

    fn new_turn(conn: &Connection, session: &str, turn: i64) {
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, turn_started_ns: Some(turn), ..Default::default() };
        set_status_db(conn, "codex", session, &busy).unwrap();
    }

    fn setup(name: &str) -> (crate::db::TestDb, DbPool, String, String) {
        let (db, pool) = pool(name);
        let conn = pool.get().unwrap();
        seed(&conn);
        let conv = open_conversation_db(&conn, TODO, "claude", None, false).unwrap();
        // Codex: Claude continues on its own, so only Codex is resumed automatically.
        conn.execute("UPDATE conversations SET tool = 'codex' WHERE id = ?1", [&conv.id]).unwrap();
        (db, pool, conv.id, conv.session_id)
    }

    #[test]
    fn automatic_resume_needs_the_toggle_a_session_pause_and_no_one_else_holding_it() {
        let (_db, pool, id, session) = setup("resume-claim");
        let conn = pool.get().unwrap();
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(0)).ok().unwrap();
        assert_eq!((state.granted, state.reason.as_deref()), (false, Some("not_paused")));
        pause(&conn, &session, "session");
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(0)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("toggle_off"));
        set_resume_db(&conn, &id, true).unwrap();
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(0)).ok().unwrap();
        assert!(state.granted, "{state:?}");
        assert!(!state.tmux_name.is_empty());
        // Another process or computer is refused while the lease lasts, and may take it after.
        let (state, _) = resume_action_db(&conn, &claim(&session, "b", false), at(1)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("leased"));
        let (state, _) = resume_action_db(&conn, &claim(&session, "b", true), at(1)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("leased"), "a tap waits for the lease too");
        let (state, _) = resume_action_db(&conn, &claim(&session, "b", false), at(7)).ok().unwrap();
        assert!(state.granted);
        let count = |conn: &Connection| -> usize {
            let stored: Option<String> = conn.query_row("SELECT resume_attempts FROM conversations WHERE id = ?1", [&id], |r| r.get(0)).unwrap();
            recent_attempts(stored.as_deref(), at(7)).len()
        };
        assert_eq!(count(&conn), 2);
        // A released lease is free at once, and its attempt doesn't count: nothing was typed.
        let (state, _) = resume_action_db(&conn, &ConversationResumeRequest { token: Some("b".into()), ..request(&session, "release") }, at(8)).ok().unwrap();
        assert!(state.granted);
        assert_eq!(count(&conn), 1);
        let (state, _) = resume_action_db(&conn, &claim(&session, "c", true), at(8)).ok().unwrap();
        assert!(state.granted);
    }

    #[test]
    fn a_weekly_pause_is_never_resumed_automatically_but_a_tap_may() {
        let (_db, pool, id, session) = setup("resume-weekly");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        pause(&conn, &session, "weekly");
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(0)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("not_session"));
        // Arming is ignored for it, and the offer is raised.
        let arm = ConversationResumeRequest { resume_at: Some("2026-11-06T21:02:00Z".into()), ..request(&session, "arm") };
        let (state, _) = resume_action_db(&conn, &arm, at(0)).ok().unwrap();
        assert_eq!(state.paused.as_ref().unwrap().resume_at, None);
        let (state, changed) = resume_action_db(&conn, &request(&session, "offer"), at(0)).ok().unwrap();
        assert!(changed && state.paused.unwrap().offer);
        let shown = load_conversation_by_id(&conn, &id).unwrap().unwrap();
        assert!(shown.paused.unwrap().offer);
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", true), at(0)).ok().unwrap();
        assert!(state.granted);
        assert!(!state.paused.unwrap().offer, "a claimed offer is gone");
    }

    #[test]
    fn a_new_turn_or_another_pause_clears_the_plan_and_the_offer() {
        let (_db, pool, id, session) = setup("resume-clear");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        pause(&conn, &session, "session");
        let arm = ConversationResumeRequest { resume_at: Some("2026-11-06T23:02:00+02:00".into()), ..request(&session, "arm") };
        let (state, changed) = resume_action_db(&conn, &arm, at(0)).ok().unwrap();
        assert!(changed);
        assert_eq!(state.paused.unwrap().resume_at.as_deref(), Some("2026-11-06T21:02:00Z"));
        assert_eq!(load_conversation_by_id(&conn, &id).unwrap().unwrap().paused.unwrap().resume_at.as_deref(), Some("2026-11-06T21:02:00Z"));
        // An idle heartbeat keeps it.
        let idle = ConversationStatusRequest { status: ConversationStatus::Idle, ..Default::default() };
        set_status_db(&conn, "codex", &session, &idle).unwrap();
        assert!(load_conversation_by_id(&conn, &id).unwrap().unwrap().paused.unwrap().resume_at.is_some());
        // Typing (a new turn) ends the pause and everything planned for it.
        new_turn(&conn, &session, 5);
        let (state, _) = resume_action_db(&conn, &request(&session, "state"), at(0)).ok().unwrap();
        assert_eq!(state.paused, None);
        let raw: (Option<String>, bool, Option<String>) = conn
            .query_row("SELECT resume_at, resume_offer, resume_token FROM conversations WHERE id = ?1", [&id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap();
        assert_eq!(raw, (None, false, None));
        // So does a fresh pause: its offer starts unraised.
        pause(&conn, &session, "weekly");
        resume_action_db(&conn, &request(&session, "offer"), at(0)).ok().unwrap();
        new_turn(&conn, &session, 9);
        pause(&conn, &session, "weekly");
        assert!(!load_conversation_by_id(&conn, &id).unwrap().unwrap().paused.unwrap().offer);
    }

    #[test]
    fn three_automatic_resumes_a_day_then_the_toggle_turns_off_quietly() {
        let (_db, pool, id, session) = setup("resume-cap");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        for (n, minute) in [0, 300, 600].into_iter().enumerate() {
            pause(&conn, &session, "session");
            let token = format!("t{n}");
            let (state, _) = resume_action_db(&conn, &claim(&session, &token, false), at(minute)).ok().unwrap();
            assert!(state.granted, "attempt {n}: {state:?}");
            new_turn(&conn, &session, 10 + n as i64);
        }
        // The fourth limit hit finds 3 resumes in 24 h: the toggle goes off now, quietly.
        pause(&conn, &session, "session");
        let shown = load_conversation_by_id(&conn, &id).unwrap().unwrap();
        assert!(!shown.resume_on_reset);
        assert_eq!(shown.resume_off_reason.as_deref(), Some("cap"));
        let (state, _) = resume_action_db(&conn, &claim(&session, "t3", false), at(900)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("toggle_off"));
        // A claim that finds the cap (the toggle still on) turns it off and offers the tap.
        conn.execute("UPDATE conversations SET resume_on_reset = 1, resume_off_reason = NULL WHERE id = ?1", [&id]).unwrap();
        let (state, changed) = resume_action_db(&conn, &claim(&session, "t3", false), at(900)).ok().unwrap();
        assert!(changed);
        assert_eq!(state.reason.as_deref(), Some("cap"));
        assert!(!state.resume_on_reset);
        assert_eq!(state.resume_off_reason.as_deref(), Some("cap"));
        assert!(state.paused.unwrap().offer, "the tap is still there");
        // Switching it back on starts a fresh count.
        set_resume_db(&conn, &id, true).unwrap();
        let shown = load_conversation_by_id(&conn, &id).unwrap().unwrap();
        assert!(shown.resume_on_reset && shown.resume_off_reason.is_none());
    }

    #[test]
    fn a_limit_hit_soon_after_a_resume_counts_as_an_attempt() {
        let (_db, pool, id, session) = setup("resume-rehit");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        // Each resume is followed by another limit hit 2 minutes later.
        let now = Utc::now();
        conn.execute(
            "UPDATE conversations SET resume_attempts = ?2, resume_last_at = ?3 WHERE id = ?1",
            params![id, attempts_json(&[now - Duration::minutes(2)]), iso(now - Duration::minutes(2))],
        )
        .unwrap();
        pause(&conn, &session, "session");
        let stored: String = conn.query_row("SELECT resume_attempts FROM conversations WHERE id = ?1", [&id], |r| r.get(0)).unwrap();
        assert_eq!(recent_attempts(Some(&stored), now + Duration::seconds(1)).len(), 2);
        // The third (another re-hit after a resume) reaches the cap at once.
        conn.execute("UPDATE conversations SET resume_last_at = ?2 WHERE id = ?1", params![id, iso(Utc::now())]).unwrap();
        new_turn(&conn, &session, 7);
        pause(&conn, &session, "session");
        let shown = load_conversation_by_id(&conn, &id).unwrap().unwrap();
        assert!(!shown.resume_on_reset);
        assert_eq!(shown.resume_off_reason.as_deref(), Some("cap"));
    }

    #[test]
    fn the_same_pause_reported_twice_keeps_the_plan_and_counts_once() {
        let (_db, pool, id, session) = setup("resume-repeat");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        conn.execute("UPDATE conversations SET resume_last_at = ?2 WHERE id = ?1", params![id, iso(Utc::now())]).unwrap();
        pause(&conn, &session, "session");
        let arm = ConversationResumeRequest { resume_at: Some("2026-11-06T21:02:00Z".into()), ..request(&session, "arm") };
        resume_action_db(&conn, &arm, at(0)).ok().unwrap();
        let same = LimitPause { kind: "session".into(), resets_at: Some("2026-11-06T21:00:00Z".into()), ..Default::default() };
        let idle = ConversationStatusRequest { status: ConversationStatus::Idle, paused: Some(same), ..Default::default() };
        let change = set_status_db(&conn, "codex", &session, &idle).unwrap().unwrap();
        assert!(change.paused, "still no done push");
        let shown = load_conversation_by_id(&conn, &id).unwrap().unwrap();
        assert_eq!(shown.paused.unwrap().resume_at.as_deref(), Some("2026-11-06T21:02:00Z"));
        let stored: String = conn.query_row("SELECT resume_attempts FROM conversations WHERE id = ?1", [&id], |r| r.get(0)).unwrap();
        assert_eq!(recent_attempts(Some(&stored), Utc::now()).len(), 1, "the quick re-hit counted once");
    }

    #[test]
    fn claude_is_left_to_continue_on_its_own_but_a_tap_still_works() {
        let (_db, pool, id, session) = setup("resume-claude");
        let conn = pool.get().unwrap();
        conn.execute("UPDATE conversations SET tool = 'claude' WHERE id = ?1", [&id]).unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        let pause = LimitPause { kind: "session".into(), resets_at: Some("2026-11-06T21:00:00Z".into()), ..Default::default() };
        let busy = ConversationStatusRequest { status: ConversationStatus::Busy, turn_started_ns: Some(1), ..Default::default() };
        set_status_db(&conn, "claude", &session, &busy).unwrap();
        let idle = ConversationStatusRequest { status: ConversationStatus::Idle, paused: Some(pause), ..Default::default() };
        set_status_db(&conn, "claude", &session, &idle).unwrap();
        let claude = |action: &str| ConversationResumeRequest { tool: "claude".into(), ..request(&session, action) };
        let auto = ConversationResumeRequest { token: Some("a".into()), ..claude("claim") };
        assert_eq!(resume_action_db(&conn, &auto, at(0)).ok().unwrap().0.reason.as_deref(), Some("claude_continues"));
        let arm = ConversationResumeRequest { resume_at: Some("2026-11-06T21:02:00Z".into()), ..claude("arm") };
        assert_eq!(resume_action_db(&conn, &arm, at(0)).ok().unwrap().0.paused.unwrap().resume_at, None);
        let tap = ConversationResumeRequest { manual: true, ..auto };
        assert!(resume_action_db(&conn, &tap, at(0)).ok().unwrap().0.granted);
    }

    #[test]
    fn switching_the_toggle_off_cancels_the_plan() {
        let (_db, pool, id, session) = setup("resume-off");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        pause(&conn, &session, "session");
        let arm = ConversationResumeRequest { resume_at: Some("2026-11-06T21:02:00Z".into()), ..request(&session, "arm") };
        resume_action_db(&conn, &arm, at(0)).ok().unwrap();
        set_resume_db(&conn, &id, false).unwrap();
        let (state, _) = resume_action_db(&conn, &request(&session, "state"), at(0)).ok().unwrap();
        assert_eq!(state.paused.unwrap().resume_at, None);
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(1)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("toggle_off"));
    }

    #[test]
    fn a_reviewed_or_closed_conversation_is_left_alone() {
        let (_db, pool, id, session) = setup("resume-reviewed");
        let conn = pool.get().unwrap();
        set_resume_db(&conn, &id, true).unwrap();
        pause(&conn, &session, "session");
        conn.execute("UPDATE conversations SET reviewed = 1 WHERE id = ?1", [&id]).unwrap();
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", false), at(0)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("reviewed"));
        conn.execute("UPDATE conversations SET status = 'closed' WHERE id = ?1", [&id]).unwrap();
        let (state, _) = resume_action_db(&conn, &claim(&session, "a", true), at(0)).ok().unwrap();
        assert_eq!(state.reason.as_deref(), Some("closed"));
    }

    #[actix_web::test]
    async fn routes() {
        let (_db, pool, id, session) = setup("resume-routes");
        {
            let conn = pool.get().unwrap();
            pause(&conn, &session, "session");
        }
        let (status, body) = put(&pool, &format!("/api/conversations/{id}/resume"), serde_json::json!({"resume_on_reset": true})).await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["resume_on_reset"], true);
        let (status, body) = put(&pool, "/api/conversations/missing/resume", serde_json::json!({"resume_on_reset": true})).await;
        assert_eq!(status, 404, "{body}");
        let (status, body) = post(
            &pool,
            "/api/conversations/resume",
            serde_json::json!({"tool": "codex", "session_id": session, "action": "arm", "resume_at": "2026-11-06T21:02:00Z"}),
        )
        .await;
        assert_eq!(status, 200, "{body}");
        assert_eq!(body["paused"]["resume_at"], "2026-11-06T21:02:00Z");
        assert_eq!(body["granted"], false);
        let (status, _) = post(&pool, "/api/conversations/resume", serde_json::json!({"tool": "codex", "session_id": session, "action": "dance"})).await;
        assert_eq!(status, 400);
        let (status, _) = post(&pool, "/api/conversations/resume", serde_json::json!({"tool": "codex", "session_id": session, "action": "claim"})).await;
        assert_eq!(status, 400, "a claim needs a token");
        let (status, _) = post(&pool, "/api/conversations/resume", serde_json::json!({"tool": "codex", "session_id": "nope", "action": "state"})).await;
        assert_eq!(status, 404);
        let (status, body) = post(
            &pool,
            "/api/conversations/resume",
            serde_json::json!({"tool": "codex", "session_id": session, "action": "claim", "token": "x"}),
        )
        .await;
        assert_eq!((status.as_u16(), body["granted"].as_bool()), (200, Some(true)), "{body}");
        let (_, list) = crate::test_support::get(&pool, "/api/conversations").await;
        assert_eq!(list[0]["resume_on_reset"], true);
    }
}
