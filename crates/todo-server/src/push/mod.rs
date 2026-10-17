//! Push notifications: APNs alerts when a todo's conversation needs the user.
//! See docs/superpowers/specs/2026-10-17-push-notifications-design.md.

pub mod apns;
pub mod policy;
pub mod store;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::time::Instant;
use todo_shared::{ConversationStatus, PushTestResult};

use crate::db::DbPool;
use apns::{Alert, ApnsSender, PushKind};
pub use policy::Transition;
use policy::{decide, Ctx, Event, TurnTracker};

/// How long a client counts as viewing a conversation without refreshing.
const PRESENCE_TTL: Duration = Duration::from_secs(90);
const QUEUE: usize = 256;

/// Which conversation each client is showing, in memory (`POST /api/push/presence`).
#[derive(Clone, Default)]
pub struct Presence {
    clients: Arc<Mutex<HashMap<String, (String, Instant)>>>,
}

impl Presence {
    pub fn set(&self, client_id: &str, todo_id: Option<String>) {
        let mut clients = self.clients.lock().unwrap();
        let now = Instant::now();
        clients.retain(|_, (_, seen)| now.duration_since(*seen) < PRESENCE_TTL);
        match todo_id {
            Some(todo) => clients.insert(client_id.to_string(), (todo, now)),
            None => clients.remove(client_id),
        };
    }

    pub fn viewing(&self, todo_id: &str) -> bool {
        let now = Instant::now();
        self.clients
            .lock()
            .unwrap()
            .values()
            .any(|(todo, seen)| todo == todo_id && now.duration_since(*seen) < PRESENCE_TTL)
    }
}

enum Msg {
    Transition(Transition),
    /// A push for `event` reached at least one device.
    Sent(String, Event),
}

/// Takes status transitions from the hook endpoint and decides, delays and sends pushes on
/// a background task, so the endpoint never waits on Apple.
#[derive(Clone)]
pub struct PushNotifier {
    tx: Option<mpsc::Sender<Msg>>,
    sender: Option<Arc<ApnsSender>>,
}

impl PushNotifier {
    /// Spawn the background task. `sender` is `None` when APNs isn't configured: events are
    /// still decided and logged, nothing is sent.
    pub fn start(pool: DbPool, sender: Option<ApnsSender>, presence: Presence) -> Self {
        let (tx, rx) = mpsc::channel(QUEUE);
        let sender = sender.map(Arc::new);
        tokio::spawn(run(rx, tx.clone(), pool, sender.clone(), presence));
        Self { tx: Some(tx), sender }
    }

    /// No task, nothing sent: for tests that don't exercise push.
    pub fn disabled() -> Self {
        Self { tx: None, sender: None }
    }

    /// Hand over one accepted status post. Never blocks: a full queue drops the event.
    pub fn notify(&self, transition: Transition) {
        if let Some(tx) = &self.tx {
            if tx.try_send(Msg::Transition(transition)).is_err() {
                println!("push: queue full, dropped a status event");
            }
        }
    }

    pub fn configured(&self) -> bool {
        self.sender.is_some()
    }

    pub fn last_error(&self) -> Option<String> {
        self.sender.as_ref().and_then(|s| s.last_error())
    }

    pub fn last_sent_at(&self) -> Option<String> {
        self.sender.as_ref().and_then(|s| s.last_sent_at())
    }

    /// Send `alert` to every registered device (or only `token`). Empty when not configured.
    pub async fn send_to_devices(&self, pool: &DbPool, alert: &Alert, token: Option<&str>) -> Vec<PushTestResult> {
        match &self.sender {
            Some(sender) => send_all(sender, pool, alert, token).await,
            None => Vec::new(),
        }
    }
}

async fn send_all(sender: &ApnsSender, pool: &DbPool, alert: &Alert, only: Option<&str>) -> Vec<PushTestResult> {
    let targets = match pool.get().map_err(|e| e.to_string()).and_then(|c| store::devices_for_push(&c).map_err(|e| e.to_string())) {
        Ok(targets) => targets,
        Err(e) => {
            println!("push: loading devices failed: {e}");
            return Vec::new();
        }
    };
    let mut results = Vec::new();
    for target in targets.iter().filter(|t| only.is_none_or(|token| t.token == token)) {
        results.push(sender.send(pool, target, alert).await);
    }
    results
}

/// The alert for `event` about `ctx`'s todo. Never includes the hook's status message.
fn alert_for(ctx: &store::PushContext, kind: PushKind, passive: bool) -> Alert {
    let subtitle = match &ctx.computer_name {
        Some(computer) => format!("{} · {computer}", ctx.section),
        None => ctx.section.clone(),
    };
    Alert {
        todo_id: Some(ctx.todo_id.clone()),
        session_id: Some(ctx.session_id.clone()),
        title: ctx.title.clone(),
        subtitle,
        kind,
        passive,
    }
}

/// Settings, mute and fresh todo context for a decision; `None` when the todo or its
/// conversation is gone.
fn load(pool: &DbPool, todo_id: &str) -> Option<(store::PushContext, todo_shared::PushSettings, bool)> {
    let conn = pool.get().ok()?;
    let ctx = store::push_context(&conn, todo_id).ok()??;
    let settings = store::load_settings(&conn).ok()?;
    let muted = store::is_muted(&conn, todo_id, &ctx.section).ok()?;
    Some((ctx, settings, muted))
}

async fn run(
    mut rx: mpsc::Receiver<Msg>,
    tx: mpsc::Sender<Msg>,
    pool: DbPool,
    sender: Option<Arc<ApnsSender>>,
    presence: Presence,
) {
    let mut turns = TurnTracker::default();
    // Grace-held `waiting` pushes, by todo: set the flag to cancel.
    let mut pending: HashMap<String, Arc<AtomicBool>> = HashMap::new();
    while let Some(msg) = rx.recv().await {
        let transition = match msg {
            Msg::Sent(todo_id, event) => {
                turns.mark_sent(&todo_id, event);
                continue;
            }
            Msg::Transition(t) => t,
        };
        pending.retain(|_, cancelled| Arc::strong_count(cancelled) > 1 && !cancelled.load(Ordering::SeqCst));
        let Some(event) = turns.on_transition(&transition) else { continue };
        let todo_id = transition.todo_id.clone();
        if event == Event::AttendedRecheck {
            if let Some(cancelled) = pending.remove(&todo_id) {
                cancelled.store(true, Ordering::SeqCst);
                println!("push: waiting for {todo_id} cancelled (answered at the terminal)");
            }
            continue;
        }
        let Some((ctx, settings, muted)) = load(&pool, &todo_id) else { continue };
        let decision = decide(
            event,
            &Ctx {
                settings: &settings,
                muted,
                attended: transition.attended,
                viewing: presence.viewing(&todo_id),
                now: chrono::Utc::now(),
            },
        );
        let delivery = match decision {
            Ok(delivery) => delivery,
            Err(why) => {
                println!("push: {event:?} for {todo_id} suppressed ({why:?})");
                continue;
            }
        };
        let Some(sender) = sender.clone() else {
            println!("push: {event:?} for {todo_id}: not configured, skipped");
            continue;
        };
        let (pool, tx, presence) = (pool.clone(), tx.clone(), presence.clone());
        match event {
            Event::Waiting => {
                if pending.contains_key(&todo_id) {
                    continue; // the held push for this prompt will go out
                }
                let cancelled = Arc::new(AtomicBool::new(false));
                pending.insert(todo_id.clone(), cancelled.clone());
                let grace = Duration::from_secs(u64::from(settings.grace_seconds));
                tokio::spawn(async move {
                    tokio::time::sleep(grace).await;
                    if cancelled.load(Ordering::SeqCst) || presence.viewing(&todo_id) {
                        return;
                    }
                    let Some((ctx, _, _)) = load(&pool, &todo_id) else { return };
                    if ctx.status != ConversationStatus::Waiting {
                        return;
                    }
                    let alert = alert_for(&ctx, PushKind::Waiting, delivery.passive);
                    if send_all(&sender, &pool, &alert, None).await.iter().any(|r| r.ok) {
                        let _ = tx.send(Msg::Sent(todo_id, event)).await;
                    }
                    drop(cancelled);
                });
            }
            Event::Done { minutes } => {
                tokio::spawn(async move {
                    let alert = alert_for(&ctx, PushKind::Done { minutes }, delivery.passive);
                    if send_all(&sender, &pool, &alert, None).await.iter().any(|r| r.ok) {
                        let _ = tx.send(Msg::Sent(todo_id, event)).await;
                    }
                });
            }
            Event::AttendedRecheck => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::apns::tests::{test_config, waiting_alert, FakeTransport, TOKEN};
    use crate::push::apns::{ApnsSender, JwtSigner};
    use crate::test_support::{pool, seed_computers};
    use rusqlite::params;
    use std::time::Duration;
    use todo_shared::{ApnsEnvironment, ConversationStatus as S, PushDeviceRequest, PushPlatform};

    struct Harness {
        _db: crate::db::TestDb,
        pool: DbPool,
        transport: Arc<FakeTransport>,
        presence: Presence,
        notifier: PushNotifier,
    }

    fn harness() -> Harness {
        let (db, pool) = pool("notifier");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'Fix invoice export');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                 VALUES ('t1', 'mac', '~/programming', 'claude', 'ai/claude/todo-t1', 'sess-1', 'idle');",
        )
        .unwrap();
        store::upsert_device(
            &conn,
            &PushDeviceRequest {
                token: TOKEN.into(),
                platform: PushPlatform::Ios,
                environment: ApnsEnvironment::Sandbox,
                bundle_id: "com.aisessionremote.app".into(),
                app_version: "1.0".into(),
                device_name: None,
            },
        )
        .unwrap();
        drop(conn);
        let transport = FakeTransport::scripted(vec![]);
        let presence = Presence::default();
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let notifier = PushNotifier::start(pool.clone(), Some(sender), presence.clone());
        Harness { _db: db, pool, transport, presence, notifier }
    }

    impl Harness {
        /// What the status endpoint does: update the row, then hand over the transition.
        fn post(&self, new: S, attended: bool) {
            let conn = self.pool.get().unwrap();
            let old: String = conn.query_row("SELECT status FROM conversations WHERE todo_id = 't1'", [], |r| r.get(0)).unwrap();
            conn.execute("UPDATE conversations SET status = ?1 WHERE todo_id = 't1'", params![new.as_str()]).unwrap();
            self.notifier.notify(Transition {
                todo_id: "t1".into(),
                old: S::parse(&old).unwrap(),
                new,
                attended,
                at: std::time::SystemTime::now(),
            });
        }

        fn sent(&self) -> usize {
            self.transport.call_count()
        }
    }

    async fn wait(secs: u64) {
        tokio::time::sleep(Duration::from_secs(secs)).await;
    }

    #[tokio::test(start_paused = true)]
    async fn waiting_pushes_after_grace() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(19).await;
        assert_eq!(h.sent(), 0, "held for the 20 s grace");
        wait(2).await;
        assert_eq!(h.sent(), 1);
        let calls = h.transport.calls.lock().unwrap();
        let payload = &calls[0].3;
        assert_eq!(payload["kind"], "waiting");
        assert_eq!(payload["todo_id"], "t1");
        assert_eq!(payload["aps"]["alert"], build_alert_json());
    }

    fn build_alert_json() -> serde_json::Value {
        crate::push::apns::build_payload(&waiting_alert())["aps"]["alert"].clone()
    }

    #[tokio::test(start_paused = true)]
    async fn answered_within_grace_sends_nothing() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(5).await;
        h.post(S::Busy, false);
        wait(30).await;
        assert_eq!(h.sent(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn attended_recheck_cancels_pending() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(12).await;
        h.post(S::Waiting, true);
        wait(30).await;
        assert_eq!(h.sent(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn attended_at_prompt_sends_nothing() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, true);
        wait(30).await;
        assert_eq!(h.sent(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn presence_during_grace_cancels() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(3).await;
        h.presence.set("phone", Some("t1".into()));
        wait(30).await;
        assert_eq!(h.sent(), 0);
        // Presence expires after 90 s without a refresh.
        h.post(S::Idle, false);
        wait(100).await;
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(25).await;
        assert_eq!(h.sent(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn todo_deleted_during_grace_sends_nothing() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(5).await;
        h.pool.get().unwrap().execute("DELETE FROM todos WHERE id = 't1'", []).unwrap();
        wait(30).await;
        assert_eq!(h.sent(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn second_waiting_in_turn_is_silent_after_send() {
        let h = harness();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(25).await;
        assert_eq!(h.sent(), 1);
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(30).await;
        assert_eq!(h.sent(), 1);
        // The next turn pushes again.
        h.post(S::Idle, false);
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(25).await;
        assert_eq!(h.sent(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn muted_todo_sends_nothing() {
        let h = harness();
        store::set_todo_muted(&h.pool.get().unwrap(), "t1", true).unwrap();
        h.post(S::Busy, false);
        h.post(S::Waiting, false);
        wait(30).await;
        assert_eq!(h.sent(), 0);
    }

    #[tokio::test(start_paused = true)]
    async fn done_push_after_long_run_when_enabled() {
        let h = harness();
        store::save_settings(
            &h.pool.get().unwrap(),
            &todo_shared::PushSettingsUpdate { done_after_minutes: Some(5), ..Default::default() },
        )
        .unwrap();
        h.post(S::Busy, false);
        wait(4 * 60).await;
        h.post(S::Idle, false);
        wait(1).await;
        assert_eq!(h.sent(), 0, "4 minutes is below the threshold");
        h.post(S::Busy, false);
        // The transition time is wall clock, not tokio's paused clock: backdate the turn.
        h.notifier.notify(Transition {
            todo_id: "t1".into(),
            old: S::Busy,
            new: S::Idle,
            attended: false,
            at: std::time::SystemTime::now() + Duration::from_secs(6 * 60),
        });
        wait(1).await;
        assert_eq!(h.sent(), 1);
        assert_eq!(h.transport.calls.lock().unwrap()[0].3["kind"], "done");
    }
}
