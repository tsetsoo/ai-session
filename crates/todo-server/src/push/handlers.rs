//! `/api/push/*` and `/api/todos/{id}/push-mute`.

use actix_web::{web, HttpResponse};
use todo_shared::{PresenceRequest, PushDeviceRequest, PushSettingsUpdate, PushStatus, PushTestRequest};

use crate::broadcast::Broadcaster;
use crate::conversations::{bad_request, error, not_found, server_error};
use crate::db::DbPool;
use crate::push::apns::{Alert, PushKind};
use crate::push::policy::validate_quiet_hours;
use crate::push::{store, Presence, PushNotifier};

/// APNs tokens are 32 bytes today; Apple allows them to grow, so accept up to 100 bytes.
fn valid_token(token: &str) -> bool {
    (64..=200).contains(&token.len()) && token.len().is_multiple_of(2) && token.bytes().all(|b| b.is_ascii_hexdigit())
}

fn blank(s: &str) -> bool {
    s.trim().is_empty()
}

pub async fn put_device(
    pool: web::Data<DbPool>,
    body: web::Json<PushDeviceRequest>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let mut req = body.into_inner();
    req.token = req.token.trim().to_ascii_lowercase();
    if !valid_token(&req.token) {
        return bad_request("token must be the APNs device token in hex");
    }
    if blank(&req.bundle_id) || blank(&req.app_version) {
        return bad_request("bundle_id and app_version are required");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match store::upsert_device(&conn, &req) {
        Ok(device) => {
            broadcaster.send();
            HttpResponse::Ok().json(device)
        }
        Err(e) => server_error(e),
    }
}

pub async fn list_devices(pool: web::Data<DbPool>) -> HttpResponse {
    match pool.get().map_err(|e| e.to_string()).and_then(|c| store::list_devices(&c).map_err(|e| e.to_string())) {
        Ok(devices) => HttpResponse::Ok().json(devices),
        Err(e) => server_error(e),
    }
}

pub async fn delete_device(
    pool: web::Data<DbPool>,
    path: web::Path<String>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    let token = path.into_inner().to_ascii_lowercase();
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match store::delete_device(&conn, &token) {
        Ok(true) => {
            broadcaster.send();
            HttpResponse::NoContent().finish()
        }
        Ok(false) => not_found("Device not registered"),
        Err(e) => server_error(e),
    }
}

pub async fn get_settings(pool: web::Data<DbPool>) -> HttpResponse {
    match pool.get().map_err(|e| e.to_string()).and_then(|c| store::load_settings(&c).map_err(|e| e.to_string())) {
        Ok(settings) => HttpResponse::Ok().json(settings),
        Err(e) => server_error(e),
    }
}

pub async fn put_settings(
    pool: web::Data<DbPool>,
    body: web::Json<PushSettingsUpdate>,
    broadcaster: web::Data<Broadcaster>,
) -> HttpResponse {
    if let Some(quiet) = &body.quiet_hours {
        if let Err(msg) = validate_quiet_hours(quiet) {
            return bad_request(&msg);
        }
    }
    if body.grace_seconds > 300 {
        return bad_request("grace_seconds must be at most 300");
    }
    if body.done_after_minutes.is_some_and(|m| !(1..=600).contains(&m)) {
        return bad_request("done_after_minutes must be between 1 and 600");
    }
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match store::save_settings(&conn, &body).and_then(|()| store::load_settings(&conn)) {
        Ok(settings) => {
            broadcaster.send();
            HttpResponse::Ok().json(settings)
        }
        Err(e) => server_error(e),
    }
}

async fn set_mute(pool: &DbPool, todo_id: &str, muted: bool, broadcaster: &Broadcaster) -> HttpResponse {
    let conn = match pool.get() {
        Ok(c) => c,
        Err(e) => return server_error(e),
    };
    match store::set_todo_muted(&conn, todo_id, muted) {
        Ok(true) => {
            broadcaster.send();
            HttpResponse::NoContent().finish()
        }
        Ok(false) => not_found("Todo not found"),
        Err(e) => server_error(e),
    }
}

pub async fn mute_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    set_mute(&pool, &path, true, &broadcaster).await
}

pub async fn unmute_todo(pool: web::Data<DbPool>, path: web::Path<String>, broadcaster: web::Data<Broadcaster>) -> HttpResponse {
    set_mute(&pool, &path, false, &broadcaster).await
}

/// No broadcast: clients refresh every 30 s while viewing, which would be a refresh storm.
pub async fn post_presence(body: web::Json<PresenceRequest>, presence: web::Data<Presence>) -> HttpResponse {
    let client = body.client_id.trim();
    if client.is_empty() || client.len() > 100 {
        return bad_request("client_id is required (at most 100 characters)");
    }
    presence.set(client, body.todo_id.clone().filter(|t| !t.trim().is_empty()));
    HttpResponse::NoContent().finish()
}

pub async fn get_status(pool: web::Data<DbPool>, notifier: web::Data<PushNotifier>) -> HttpResponse {
    let devices = match pool.get().map_err(|e| e.to_string()).and_then(|c| store::list_devices(&c).map_err(|e| e.to_string())) {
        Ok(devices) => devices.len(),
        Err(e) => return server_error(e),
    };
    HttpResponse::Ok().json(PushStatus {
        configured: notifier.configured(),
        last_error: notifier.last_error(),
        last_sent_at: notifier.last_sent_at(),
        devices,
    })
}

/// Send "Test notification" now (no grace, no mutes) to every device or to `token`.
pub async fn post_test(pool: web::Data<DbPool>, notifier: web::Data<PushNotifier>, body: web::Bytes) -> HttpResponse {
    let req: PushTestRequest = if body.is_empty() {
        PushTestRequest::default()
    } else {
        match serde_json::from_slice(&body) {
            Ok(req) => req,
            Err(e) => return bad_request(&e.to_string()),
        }
    };
    if !notifier.configured() {
        return error(actix_web::http::StatusCode::CONFLICT, "Push is not configured on the server (APNS_* settings)");
    }
    let alert = Alert {
        todo_id: None,
        session_id: None,
        title: "Todo server".into(),
        subtitle: String::new(),
        kind: PushKind::Test,
        passive: false,
    };
    let token = req.token.map(|t| t.trim().to_ascii_lowercase());
    HttpResponse::Ok().json(notifier.send_to_devices(&pool, &alert, token.as_deref()).await)
}

#[cfg(test)]
mod tests {
    use crate::push::apns::tests::{test_config, FakeTransport, TOKEN};
    use crate::push::apns::{ApnsSender, JwtSigner};
    use crate::push::{Presence, PushNotifier};
    use crate::test_support::{call_with, delete, get, pool, post, put, seed_computers};
    use actix_web::http::{Method, StatusCode};
    use serde_json::json;

    fn device_body() -> serde_json::Value {
        json!({
            "token": TOKEN.to_uppercase(),
            "platform": "ios",
            "environment": "sandbox",
            "bundle_id": "com.aisessionremote.app",
            "app_version": "1.0 (7)",
            "device_name": "Tsvetelin"
        })
    }

    #[actix_web::test]
    async fn register_list_unregister_device() {
        let (_db, pool) = pool("push-api");
        let (status, device) = put(&pool, "/api/push/devices", device_body()).await;
        assert_eq!(status, StatusCode::OK, "{device}");
        assert_eq!(device["token_prefix"], "a1b2c3d4", "stored lowercase");
        assert!(device.get("token").is_none());
        let (_, listed) = get(&pool, "/api/push/devices").await;
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert!(!listed.to_string().contains(TOKEN), "the full token is never returned");
        let (status, _) = delete(&pool, &format!("/api/push/devices/{}", TOKEN.to_uppercase())).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (status, _) = delete(&pool, &format!("/api/push/devices/{TOKEN}")).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn register_rejects_bad_token_and_enum() {
        let (_db, pool) = pool("push-api");
        for (field, value) in [
            ("token", json!("xyz")),
            ("token", json!("ab".repeat(16))),
            ("token", json!("a".repeat(202))),
            ("bundle_id", json!(" ")),
            ("app_version", json!("")),
        ] {
            let mut body = device_body();
            body[field] = value;
            let (status, _) = put(&pool, "/api/push/devices", body).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{field}");
        }
        let mut body = device_body();
        body["environment"] = json!("staging");
        let (status, _) = put(&pool, "/api/push/devices", body).await;
        assert!(status.is_client_error());
    }

    #[actix_web::test]
    async fn settings_round_trip_and_bad_tz_400() {
        let (_db, pool) = pool("push-api");
        let (_, defaults) = get(&pool, "/api/push/settings").await;
        assert_eq!(defaults["notify_waiting"], true);
        assert_eq!(defaults["grace_seconds"], 20);
        let body = json!({
            "notify_waiting": true,
            "done_after_minutes": 5,
            "grace_seconds": 20,
            "quiet_hours": {"start": "22:30", "end": "07:30", "tz": "Europe/Sofia"},
            "muted_sections": ["P"]
        });
        let (status, saved) = put(&pool, "/api/push/settings", body.clone()).await;
        assert_eq!(status, StatusCode::OK, "{saved}");
        assert_eq!(saved["muted_sections"], json!(["P"]));
        assert_eq!(saved["quiet_hours"]["tz"], "Europe/Sofia");
        let (_, loaded) = get(&pool, "/api/push/settings").await;
        assert_eq!(loaded, saved);
        for (field, value) in [
            ("quiet_hours", json!({"start": "22:30", "end": "07:30", "tz": "Nowhere/City"})),
            ("quiet_hours", json!({"start": "9:00", "end": "07:30", "tz": "UTC"})),
            ("grace_seconds", json!(301)),
            ("done_after_minutes", json!(0)),
            ("done_after_minutes", json!(601)),
        ] {
            let mut bad = body.clone();
            bad[field] = value;
            let (status, _) = put(&pool, "/api/push/settings", bad).await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{field}");
        }
    }

    #[actix_web::test]
    async fn todo_mute_404_for_unknown_todo() {
        let (_db, pool) = pool("push-api");
        pool.get().unwrap().execute("INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'x')", []).unwrap();
        let (status, _) = put(&pool, "/api/todos/t1/push-mute", json!({})).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (_, settings) = get(&pool, "/api/push/settings").await;
        assert_eq!(settings["muted_todo_ids"], json!(["t1"]));
        let (status, _) = delete(&pool, "/api/todos/t1/push-mute").await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (status, _) = put(&pool, "/api/todos/nope/push-mute", json!({})).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn presence_accepts_and_clears() {
        let (_db, pool) = pool("push-api");
        let presence = Presence::default();
        let notifier = PushNotifier::disabled();
        let (status, _) = call_with(&pool, &notifier, &presence, Method::POST, "/api/push/presence", Some(json!({"client_id": "phone", "todo_id": "t1"}))).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        assert!(presence.viewing("t1"));
        let (status, _) = call_with(&pool, &notifier, &presence, Method::POST, "/api/push/presence", Some(json!({"client_id": "phone", "todo_id": null}))).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        assert!(!presence.viewing("t1"));
        let (status, _) = call_with(&pool, &notifier, &presence, Method::POST, "/api/push/presence", Some(json!({"client_id": " "}))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn unconfigured_notifier_skips_and_status_reports_it() {
        let (_db, pool) = pool("push-api");
        let conn = pool.get().unwrap();
        seed_computers(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'x');
             INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                 VALUES ('t1', 'mac', '~', 'claude', 'ai/claude/todo-t1', 'sess-1', 'busy');",
        )
        .unwrap();
        drop(conn);
        put(&pool, "/api/push/devices", device_body()).await;
        let presence = Presence::default();
        let notifier = PushNotifier::start(pool.clone(), None, presence.clone());
        let (status, _) = call_with(
            &pool,
            &notifier,
            &presence,
            Method::POST,
            "/api/conversations/status",
            Some(json!({"session_id": "sess-1", "status": "waiting"})),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (status, body) = call_with(&pool, &notifier, &presence, Method::GET, "/api/push/status", None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, json!({"configured": false, "last_error": null, "last_sent_at": null, "devices": 1}));
        let (status, _) = call_with(&pool, &notifier, &presence, Method::POST, "/api/push/test", None).await;
        assert_eq!(status, StatusCode::CONFLICT);
    }

    #[actix_web::test]
    async fn test_push_returns_per_device_result() {
        let (_db, pool) = pool("push-api");
        put(&pool, "/api/push/devices", device_body()).await;
        let transport = FakeTransport::scripted(vec![Ok(FakeTransport::ok())]);
        let presence = Presence::default();
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let notifier = PushNotifier::start(pool.clone(), Some(sender), presence.clone());
        let (status, body) = call_with(&pool, &notifier, &presence, Method::POST, "/api/push/test", None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body, json!([{"token_prefix": "a1b2c3d4", "ok": true, "reason": null}]));
        let payload = transport.calls.lock().unwrap()[0].3.clone();
        assert_eq!(payload["kind"], "test");
        assert_eq!(payload["aps"]["alert"]["body"], "Test notification");
        let (_, status_body) = call_with(&pool, &notifier, &presence, Method::GET, "/api/push/status", None).await;
        assert_eq!(status_body["configured"], true);
        assert!(status_body["last_sent_at"].is_string());
        let (status, body) =
            call_with(&pool, &notifier, &presence, Method::POST, "/api/push/test", Some(json!({"token": "ffffffff"}))).await;
        assert_eq!((status, body), (StatusCode::OK, json!([])), "unknown token: nothing sent");
        let _ = post;
    }
}
