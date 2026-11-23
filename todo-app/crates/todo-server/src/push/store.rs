//! SQL for the v4 push tables: devices, settings and mutes.

use rusqlite::{params, Connection, OptionalExtension, Row};
use todo_shared::{
    ApnsEnvironment, ConversationStatus, PushDevice, PushDeviceRequest, PushPlatform, PushSettings,
    PushSettingsUpdate, QuietHours,
};

/// Where and how to send one push.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceTarget {
    pub token: String,
    pub environment: ApnsEnvironment,
    pub bundle_id: String,
    /// `datetime('now')` text (UTC) of the last registration; a 410 older than this is ignored
    pub updated_at: String,
    /// The app skin's sound file for `aps.sound`; `None` sends `"default"`
    pub sound: Option<String>,
}

/// The skin sounds the app bundles. Anything else is refused, so a client can't put an
/// arbitrary string into the APNs payload.
pub const PUSH_SOUNDS: [&str; 4] = [
    "attention-needs-you-neon-noir.caf",
    "attention-needs-you-phosphor.caf",
    "attention-review-neon-noir.caf",
    "attention-review-phosphor.caf",
];

pub fn valid_push_sound(name: &str) -> bool {
    PUSH_SOUNDS.contains(&name)
}

/// What a notification about one todo's conversation needs, read fresh at send time.
#[derive(Debug, Clone, PartialEq)]
pub struct PushContext {
    pub todo_id: String,
    pub title: String,
    pub project_name: Option<String>,
    pub computer_name: Option<String>,
    pub session_id: String,
    pub status: ConversationStatus,
}

/// The first 8 characters: enough to tell devices apart in lists and logs.
pub fn token_prefix(token: &str) -> String {
    token.chars().take(8).collect()
}

const DEVICE_COLS: &str = "token, platform, environment, bundle_id, app_version, device_name,
    created_at, updated_at, last_sent_at, last_error, sound";

fn row_to_device(row: &Row) -> rusqlite::Result<PushDevice> {
    let token: String = row.get(0)?;
    let platform: String = row.get(1)?;
    let environment: String = row.get(2)?;
    Ok(PushDevice {
        token_prefix: token_prefix(&token),
        platform: PushPlatform::parse(&platform).unwrap_or(PushPlatform::Ios),
        environment: ApnsEnvironment::parse(&environment).unwrap_or(ApnsEnvironment::Production),
        bundle_id: row.get(3)?,
        app_version: row.get(4)?,
        device_name: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
        last_sent_at: row.get(8)?,
        last_error: row.get(9)?,
        sound: row.get(10)?,
    })
}

/// Register a token, or refresh an existing registration (which clears its last error).
pub fn upsert_device(conn: &Connection, req: &PushDeviceRequest) -> rusqlite::Result<PushDevice> {
    conn.execute(
        "INSERT INTO push_devices (token, platform, environment, bundle_id, app_version, device_name, sound)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(token) DO UPDATE SET
             platform = excluded.platform, environment = excluded.environment,
             bundle_id = excluded.bundle_id, app_version = excluded.app_version,
             device_name = excluded.device_name, sound = excluded.sound,
             updated_at = datetime('now'), last_error = NULL",
        params![
            req.token,
            req.platform.as_str(),
            req.environment.as_str(),
            req.bundle_id,
            req.app_version,
            req.device_name,
            req.sound
        ],
    )?;
    conn.query_row(&format!("SELECT {DEVICE_COLS} FROM push_devices WHERE token = ?1"), params![req.token], row_to_device)
}

pub fn delete_device(conn: &Connection, token: &str) -> rusqlite::Result<bool> {
    Ok(conn.execute("DELETE FROM push_devices WHERE token = ?1", params![token])? > 0)
}

pub fn list_devices(conn: &Connection) -> rusqlite::Result<Vec<PushDevice>> {
    conn.prepare(&format!("SELECT {DEVICE_COLS} FROM push_devices ORDER BY created_at, token"))?
        .query_map([], row_to_device)?
        .collect()
}

pub fn devices_for_push(conn: &Connection) -> rusqlite::Result<Vec<DeviceTarget>> {
    conn.prepare("SELECT token, environment, bundle_id, updated_at, sound FROM push_devices ORDER BY created_at, token")?
        .query_map([], |row| {
            let environment: String = row.get(1)?;
            Ok(DeviceTarget {
                token: row.get(0)?,
                environment: ApnsEnvironment::parse(&environment).unwrap_or(ApnsEnvironment::Production),
                bundle_id: row.get(2)?,
                updated_at: row.get(3)?,
                sound: row.get(4)?,
            })
        })?
        .collect()
}

/// After a `BadDeviceToken` fallback succeeded on the other environment.
pub fn update_device_environment(conn: &Connection, token: &str, env: ApnsEnvironment) -> rusqlite::Result<()> {
    conn.execute("UPDATE push_devices SET environment = ?1 WHERE token = ?2", params![env.as_str(), token])?;
    Ok(())
}

/// `None` = delivered (sets `last_sent_at`); `Some(reason)` = the APNs failure reason.
pub fn record_result(conn: &Connection, token: &str, error: Option<&str>) -> rusqlite::Result<()> {
    match error {
        None => conn.execute(
            "UPDATE push_devices SET last_sent_at = datetime('now'), last_error = NULL WHERE token = ?1",
            params![token],
        )?,
        Some(reason) => conn.execute("UPDATE push_devices SET last_error = ?1 WHERE token = ?2", params![reason, token])?,
    };
    Ok(())
}

/// The settings row, or the defaults when it was never saved.
pub fn load_settings(conn: &Connection) -> rusqlite::Result<PushSettings> {
    let mut settings = conn
        .query_row(
            "SELECT notify_waiting, done_after_minutes, grace_seconds, quiet_start, quiet_end, quiet_tz
             FROM push_settings WHERE id = 1",
            [],
            |row| {
                let quiet = match (row.get::<_, Option<String>>(3)?, row.get::<_, Option<String>>(4)?, row.get::<_, Option<String>>(5)?) {
                    (Some(start), Some(end), Some(tz)) => Some(QuietHours { start, end, tz }),
                    _ => None,
                };
                Ok(PushSettings {
                    notify_waiting: row.get(0)?,
                    done_after_minutes: row.get(1)?,
                    grace_seconds: row.get(2)?,
                    quiet_hours: quiet,
                    ..PushSettings::default()
                })
            },
        )
        .optional()?
        .unwrap_or_default();
    settings.muted_project_ids = conn
        .prepare("SELECT project_id FROM push_muted_projects ORDER BY project_id")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    settings.muted_todo_ids = conn
        .prepare("SELECT todo_id FROM push_muted_todos ORDER BY created_at, todo_id")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(settings)
}

/// Replace the settings and project mutes (per-todo mutes are left alone).
pub fn save_settings(conn: &Connection, update: &PushSettingsUpdate) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let quiet = update.quiet_hours.as_ref();
    tx.execute(
        "INSERT INTO push_settings (id, notify_waiting, done_after_minutes, grace_seconds, quiet_start, quiet_end, quiet_tz)
         VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(id) DO UPDATE SET
             notify_waiting = excluded.notify_waiting, done_after_minutes = excluded.done_after_minutes,
             grace_seconds = excluded.grace_seconds, quiet_start = excluded.quiet_start,
             quiet_end = excluded.quiet_end, quiet_tz = excluded.quiet_tz",
        params![
            update.notify_waiting,
            update.done_after_minutes,
            update.grace_seconds,
            quiet.map(|q| &q.start),
            quiet.map(|q| &q.end),
            quiet.map(|q| &q.tz)
        ],
    )?;
    tx.execute("DELETE FROM push_muted_projects", [])?;
    for project_id in &update.muted_project_ids {
        tx.execute(
            "INSERT OR IGNORE INTO push_muted_projects (project_id) SELECT id FROM projects WHERE id = ?1",
            [project_id],
        )?;
    }
    tx.commit()
}

/// Mute or unmute one todo. `false` when the todo doesn't exist.
pub fn set_todo_muted(conn: &Connection, todo_id: &str, muted: bool) -> rusqlite::Result<bool> {
    let exists = conn.prepare("SELECT 1 FROM todos WHERE id = ?1")?.exists(params![todo_id])?;
    if !exists {
        return Ok(false);
    }
    if muted {
        conn.execute("INSERT OR IGNORE INTO push_muted_todos (todo_id) VALUES (?1)", params![todo_id])?;
    } else {
        conn.execute("DELETE FROM push_muted_todos WHERE todo_id = ?1", params![todo_id])?;
    }
    Ok(true)
}

/// The todo or its current project is muted.
pub fn is_muted(conn: &Connection, todo_id: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM push_muted_todos WHERE todo_id = ?1)
             OR EXISTS(SELECT 1 FROM todos t JOIN push_muted_projects m ON m.project_id = t.project_id WHERE t.id = ?1)",
        [todo_id],
        |r| r.get(0),
    )
}

/// The todo, its conversation and computer; `None` when either is gone.
pub fn push_context(conn: &Connection, todo_id: &str) -> rusqlite::Result<Option<PushContext>> {
    conn.query_row(
        "SELECT t.id, t.title, p.name, c.name, cv.session_id, cv.status
         FROM todos t
         JOIN conversations cv ON cv.todo_id = t.id
         LEFT JOIN computers c ON c.id = cv.computer_id
         LEFT JOIN projects p ON p.id = t.project_id
         WHERE t.id = ?1",
        params![todo_id],
        |row| {
            let status: String = row.get(5)?;
            Ok(PushContext {
                todo_id: row.get(0)?,
                title: row.get(1)?,
                project_name: row.get(2)?,
                computer_name: row.get(3)?,
                session_id: row.get(4)?,
                status: ConversationStatus::parse(&status).unwrap_or(ConversationStatus::Unknown),
            })
        },
    )
    .optional()
}

#[cfg(test)]
mod tests {

    #[test]
    fn upsert_device_stores_and_clears_sound() {
        let (_db, pool) = pool("push-sound");
        let conn = pool.get().unwrap();
        let mut req = device(TOKEN, ApnsEnvironment::Sandbox);
        req.sound = Some("attention-needs-you-neon-noir.caf".into());
        let stored = upsert_device(&conn, &req).unwrap();
        assert_eq!(stored.sound.as_deref(), Some("attention-needs-you-neon-noir.caf"));
        assert_eq!(devices_for_push(&conn).unwrap()[0].sound.as_deref(), Some("attention-needs-you-neon-noir.caf"));
        req.sound = None;
        upsert_device(&conn, &req).unwrap();
        assert_eq!(devices_for_push(&conn).unwrap()[0].sound, None, "back to Standard clears it");
    }

    #[test]
    fn push_sound_rejects_unknown_names() {
        assert!(!valid_push_sound("default"));
        assert!(!valid_push_sound("../x.caf"));
        assert!(!valid_push_sound("attention-needs-you.caf"));
        assert!(!valid_push_sound(""));
        for ok in [
            "attention-needs-you-neon-noir.caf",
            "attention-needs-you-phosphor.caf",
            "attention-review-neon-noir.caf",
            "attention-review-phosphor.caf",
        ] {
            assert!(valid_push_sound(ok), "{ok}");
        }
    }
    use super::*;
    use crate::test_support::{pool, seed_computers};
    use todo_shared::{ApnsEnvironment, PushDeviceRequest, PushPlatform, PushSettingsUpdate, QuietHours};

    const TOKEN: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    fn device(token: &str, env: ApnsEnvironment) -> PushDeviceRequest {
        PushDeviceRequest {
            token: token.into(),
            platform: PushPlatform::Ios,
            environment: env,
            bundle_id: "com.aisessionremote.app".into(),
            app_version: "1.0".into(),
            device_name: Some("Tsvetelin".into()),
            sound: None,
        }
    }

    fn seed_todo_with_conversation(conn: &Connection) {
        seed_computers(conn);
        conn.execute_batch(
            "INSERT INTO projects (id, name, computer_id, folder) VALUES ('p1', 'Invoices', (SELECT id FROM computers WHERE id = 'mac'), '~/invoices');
             INSERT INTO todos (id, title, project_id) VALUES
                 ('t1', 'Fix invoice export', 'p1'), ('t2', 'plain', NULL);
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                 VALUES ('t1', 'mac', '~/programming', 'claude', 'ai/claude/todo-t1', 'sess-1', 'waiting');",
        )
        .unwrap();
    }

    #[test]
    fn upsert_device_updates_existing_token() {
        let (_db, pool) = pool("push-store");
        let conn = pool.get().unwrap();
        let first = upsert_device(&conn, &device(TOKEN, ApnsEnvironment::Sandbox)).unwrap();
        assert_eq!(first.token_prefix, "a1b2c3d4");
        assert_eq!(first.environment, ApnsEnvironment::Sandbox);
        record_result(&conn, TOKEN, Some("BadDeviceToken")).unwrap();
        let mut again = device(TOKEN, ApnsEnvironment::Production);
        again.app_version = "1.1".into();
        let second = upsert_device(&conn, &again).unwrap();
        assert_eq!((second.environment, second.app_version.as_str()), (ApnsEnvironment::Production, "1.1"));
        assert_eq!(second.last_error, None, "re-registering clears the last error");
        assert_eq!(list_devices(&conn).unwrap().len(), 1);
        let targets = devices_for_push(&conn).unwrap();
        assert_eq!(targets.len(), 1);
        assert_eq!((targets[0].token.as_str(), targets[0].environment), (TOKEN, ApnsEnvironment::Production));
        assert_eq!(targets[0].bundle_id, "com.aisessionremote.app");

        update_device_environment(&conn, TOKEN, ApnsEnvironment::Sandbox).unwrap();
        assert_eq!(devices_for_push(&conn).unwrap()[0].environment, ApnsEnvironment::Sandbox);
        record_result(&conn, TOKEN, None).unwrap();
        assert!(list_devices(&conn).unwrap()[0].last_sent_at.is_some());

        assert!(delete_device(&conn, TOKEN).unwrap());
        assert!(!delete_device(&conn, TOKEN).unwrap());
        assert!(list_devices(&conn).unwrap().is_empty());
    }

    #[test]
    fn deleting_todo_cascades_its_mute() {
        let (_db, pool) = pool("push-store");
        let conn = pool.get().unwrap();
        seed_todo_with_conversation(&conn);
        assert!(set_todo_muted(&conn, "t1", true).unwrap());
        assert!(!set_todo_muted(&conn, "nope", true).unwrap(), "unknown todo");
        assert_eq!(load_settings(&conn).unwrap().muted_todo_ids, vec!["t1".to_string()]);
        conn.execute("DELETE FROM todos WHERE id = 't1'", []).unwrap();
        assert!(load_settings(&conn).unwrap().muted_todo_ids.is_empty());
    }

    #[test]
    fn project_mute_and_todo_mute() {
        let (_db, pool) = pool("push-store");
        let conn = pool.get().unwrap();
        seed_todo_with_conversation(&conn);
        assert!(!is_muted(&conn, "t1").unwrap());
        set_todo_muted(&conn, "t1", true).unwrap();
        assert!(is_muted(&conn, "t1").unwrap());
        set_todo_muted(&conn, "t1", false).unwrap();
        assert!(!is_muted(&conn, "t1").unwrap());
        save_settings(&conn, &PushSettingsUpdate { muted_project_ids: vec!["p1".into()], ..Default::default() }).unwrap();
        assert!(is_muted(&conn, "t1").unwrap());
        assert!(!is_muted(&conn, "t2").unwrap());
    }

    #[test]
    fn settings_default_and_round_trip() {
        let (_db, pool) = pool("push-store");
        let conn = pool.get().unwrap();
        assert_eq!(load_settings(&conn).unwrap(), PushSettings::default());
        seed_todo_with_conversation(&conn);
        let update = PushSettingsUpdate {
            notify_waiting: false,
            done_after_minutes: Some(5),
            grace_seconds: 30,
            quiet_hours: Some(QuietHours { start: "22:30".into(), end: "07:30".into(), tz: "Europe/Sofia".into() }),
            muted_project_ids: vec!["p1".into()],
        };
        save_settings(&conn, &update).unwrap();
        let loaded = load_settings(&conn).unwrap();
        assert!(!loaded.notify_waiting);
        assert_eq!(loaded.done_after_minutes, Some(5));
        assert_eq!(loaded.grace_seconds, 30);
        assert_eq!(loaded.quiet_hours, update.quiet_hours);
        assert_eq!(loaded.muted_project_ids, vec!["p1"]);
        // Replacing drops what's left out.
        save_settings(&conn, &PushSettingsUpdate::default()).unwrap();
        assert_eq!(load_settings(&conn).unwrap(), PushSettings::default());
    }

    #[test]
    fn push_context_joins_todo_conversation_computer() {
        let (_db, pool) = pool("push-store");
        let conn = pool.get().unwrap();
        seed_todo_with_conversation(&conn);
        let ctx = push_context(&conn, "t1").unwrap().unwrap();
        assert_eq!(ctx.title, "Fix invoice export");
        assert_eq!(ctx.project_name.as_deref(), Some("Invoices"));
        assert_eq!(ctx.computer_name.as_deref(), Some("tsvetelins-macbook-pro"));
        assert_eq!(ctx.session_id, "sess-1");
        assert_eq!(ctx.status, ConversationStatus::Waiting);
        assert!(push_context(&conn, "t2").unwrap().is_none(), "no conversation");
        assert!(push_context(&conn, "nope").unwrap().is_none());
    }
}
