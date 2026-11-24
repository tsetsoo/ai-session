//! ActivityKit tokens are independent from notification device tokens.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use actix_web::{web, HttpResponse};
use futures_util::{stream, StreamExt};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::Deserialize;
use serde_json::{json, Value};
use todo_shared::ApnsEnvironment;

use super::apns::{ApnsSender, Outcome};
use crate::auth::{resolve_scope, RequestScope};
use crate::conversations::{authorize_conversation_id, bad_request, open_error, server_error};
use crate::db::DbPool;

pub(crate) fn is_permission_prompt(tool: &str, message: Option<&str>) -> bool {
    match (tool, message) {
        ("claude", Some(message)) => {
            message == "Claude needs approval" || message.starts_with("Claude needs approval: ")
        }
        ("codex", Some(message)) => {
            message == "Codex needs approval"
                || message.starts_with("Codex needs your permission to use ")
        }
        _ => false,
    }
}

#[derive(Deserialize)]
pub struct Registration {
    conversation_id: String,
    token: String,
    environment: ApnsEnvironment,
}

fn authorize(conn: &Connection, scope: RequestScope, id: &str) -> Result<(), HttpResponse> {
    if let Some(scope) = resolve_scope(conn, scope)? {
        authorize_conversation_id(conn, &scope, id).map_err(open_error)?;
    }
    Ok(())
}

pub async fn register(
    pool: web::Data<DbPool>,
    id: web::Path<String>,
    body: web::Json<Registration>,
    scope: RequestScope,
) -> HttpResponse {
    if id.len() > 128
        || !(32..=256).contains(&body.token.len())
        || !body.token.len().is_multiple_of(2)
        || !body.token.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return bad_request("Invalid Live Activity registration");
    }
    let result = (|| {
        let conn = pool.get().map_err(server_error)?;
        let tx = Transaction::new_unchecked(&conn, TransactionBehavior::Immediate)
            .map_err(server_error)?;
        authorize(&tx, scope, &body.conversation_id)?;
        tx.execute(
            "DELETE FROM live_activities WHERE expires_at <= unixepoch()",
            [],
        )
        .map_err(server_error)?;
        let updated = tx.execute(
            "INSERT INTO live_activities (id, conversation_id, token, environment, expires_at)
             SELECT ?1, id, ?3, ?4, unixepoch() + 28800 FROM conversations
             WHERE id = ?2
             ON CONFLICT(id) DO UPDATE SET token = excluded.token, environment = excluded.environment
             WHERE live_activities.conversation_id = excluded.conversation_id",
            params![id.as_str(), body.conversation_id, body.token, body.environment.as_str()],
        ).map_err(server_error)?;
        tx.commit().map_err(server_error)?;
        Ok(updated)
    })();
    match result {
        Ok(0) => HttpResponse::Conflict().finish(),
        Ok(_) => HttpResponse::NoContent().finish(),
        Err(response) => response,
    }
}

pub async fn unregister(
    pool: web::Data<DbPool>,
    id: web::Path<String>,
    scope: RequestScope,
) -> HttpResponse {
    let result = (|| {
        let conn = pool.get().map_err(server_error)?;
        let tx = Transaction::new_unchecked(&conn, TransactionBehavior::Immediate)
            .map_err(server_error)?;
        if scope.is_some() {
            let conversation: Option<String> = tx
                .query_row(
                    "SELECT conversation_id FROM live_activities WHERE id = ?1",
                    [id.as_str()],
                    |row| row.get(0),
                )
                .optional()
                .map_err(server_error)?;
            let Some(conversation) = conversation else {
                return Ok(());
            };
            authorize(&tx, scope, &conversation)?;
        }
        tx.execute("DELETE FROM live_activities WHERE id = ?1", [id.as_str()])
            .map_err(server_error)?;
        tx.commit().map_err(server_error)
    })();
    match result {
        Ok(()) => HttpResponse::NoContent().finish(),
        Err(response) => response,
    }
}

#[derive(Clone, PartialEq)]
struct Target {
    id: String,
    token: String,
    environment: ApnsEnvironment,
    tool: String,
    status: String,
    message: Option<String>,
    revision: i64,
    decided: bool,
    identifiable_prompt: bool,
    delivery_unknown: bool,
}

impl Target {
    fn ended(&self) -> bool {
        !matches!(self.status.as_str(), "busy" | "waiting")
    }

    fn payload(&self) -> Value {
        let now = chrono::Utc::now().timestamp();
        let waiting = self.status == "waiting" && !self.decided;
        let message = self
            .message
            .as_ref()
            .map(|message| message.chars().take(250).collect::<String>());
        let step = if self.delivery_unknown {
            Some("Check the conversation to confirm delivery")
        } else if self.decided {
            Some("Response queued")
        } else {
            message.as_deref().or(if self.status == "busy" {
                Some("Working")
            } else {
                None
            })
        };
        let mut aps = json!({
            "timestamp": now,
            "event": if self.ended() { "end" } else { "update" },
            "content-state": {
                "status": self.status,
                "currentStep": step,
                "promptQuestion": if waiting { message.as_deref().or(Some("Waiting for your input")) } else { None },
                "isWaiting": waiting,
                "statusRevision": self.revision,
                "canDecide": waiting && self.identifiable_prompt && is_permission_prompt(&self.tool, self.message.as_deref()),
                "finishedMessage": match self.status.as_str() {
                    "idle" => Some("Turn complete"),
                    "closed" => Some("Session closed"),
                    _ => None
                },
                "updatedAt": now - 978307200
            }
        });
        if self.ended() {
            aps["dismissal-date"] = json!(now + 60);
        }
        json!({"aps": aps})
    }
}

fn targets(pool: &DbPool) -> Result<Vec<Target>, String> {
    let conn = pool.get().map_err(|error| error.to_string())?;
    let mut stmt = conn.prepare(
        "SELECT a.id, a.token, a.environment, coalesce(c.tool, ''), coalesce(c.status, 'closed'),
                c.status_message, coalesce(c.status_revision, 0),
                CASE WHEN json_valid(c.pending_approval) THEN
                    json_extract(c.pending_approval, '$.status_revision') IS NOT NULL
                    AND (json_extract(c.pending_approval, '$.key') IS NULL
                         OR COALESCE(unixepoch(json_extract(c.pending_approval, '$.approved_at')) > unixepoch() - 45, 0)
                         OR COALESCE(json_extract(c.pending_approval, '$.claim_until'), 0) > unixepoch())
                    ELSE 0 END, c.status_prompt_id IS NOT NULL,
                CASE WHEN json_valid(c.pending_approval) THEN
                    coalesce(json_extract(c.pending_approval, '$.delivery') = 'unknown', 0)
                    ELSE 0 END
         FROM live_activities a LEFT JOIN conversations c ON c.id = a.conversation_id
         WHERE a.expires_at > unixepoch()",
    ).map_err(|error| error.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok(Target {
                id: row.get(0)?,
                token: row.get(1)?,
                environment: if row.get::<_, String>(2)? == "sandbox" {
                    ApnsEnvironment::Sandbox
                } else {
                    ApnsEnvironment::Production
                },
                tool: row.get(3)?,
                status: row.get(4)?,
                message: row.get(5)?,
                revision: row.get(6)?,
                decided: row.get(7)?,
                identifiable_prompt: row.get(8)?,
                delivery_unknown: row.get(9)?,
            })
        })
        .map_err(|error| error.to_string())?;
    rows.collect::<rusqlite::Result<_>>()
        .map_err(|error| error.to_string())
}

pub async fn run(pool: DbPool, sender: Arc<ApnsSender>) {
    let mut delivered = HashMap::new();
    let mut failed = HashMap::new();
    let mut next_cleanup = tokio::time::Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(3)).await;
        let now = tokio::time::Instant::now();
        if now >= next_cleanup {
            if let Ok(conn) = pool.get() {
                let _ = conn.execute(
                    "DELETE FROM live_activities WHERE expires_at <= unixepoch()",
                    [],
                );
            }
            next_cleanup = now + Duration::from_secs(60);
        }
        failed.retain(|_, retry_at| *retry_at > now);
        let targets = match targets(&pool) {
            Ok(targets) => targets,
            Err(error) => {
                eprintln!("Live Activities: loading registrations failed: {error}");
                continue;
            }
        };
        let mut previous = std::mem::take(&mut delivered);
        let mut pending = Vec::new();
        for target in targets {
            if previous.remove(&target.id).as_ref() == Some(&target) {
                delivered.insert(target.id.clone(), target);
            } else if !failed.contains_key(&target.id) {
                pending.push(target);
            }
        }
        let mut sends = stream::iter(pending)
            .map(|target| {
                let sender = &sender;
                async move {
                    let outcome = sender
                        .send_live(target.environment, &target.token, target.payload())
                        .await;
                    (target, outcome)
                }
            })
            .buffer_unordered(8);
        while let Some((target, outcome)) = sends.next().await {
            match outcome {
                Outcome::Sent if !target.ended() => {
                    delivered.insert(target.id.clone(), target);
                }
                Outcome::Sent | Outcome::DeleteDevice { .. } | Outcome::WrongEnvironment => {
                    if let Ok(conn) = pool.get() {
                        let _ = conn.execute(
                            "DELETE FROM live_activities WHERE id = ?1 AND token = ?2",
                            params![target.id, target.token],
                        );
                    }
                }
                _ => {
                    failed.insert(
                        target.id,
                        tokio::time::Instant::now() + Duration::from_secs(30),
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::apns::tests::{test_config, FakeTransport, TOKEN};
    use crate::push::apns::JwtSigner;

    #[actix_web::test]
    async fn registration_tracks_conversation_until_deleted_or_unregistered() {
        let (_db, pool) = crate::test_support::pool("live-activity");
        let conn = pool.get().unwrap();
        crate::test_support::seed_computers(&conn);
        conn.execute_batch(
            "INSERT INTO todos (id, title) VALUES ('todo', 'Review imports');
             INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, status)
             VALUES ('conversation', 'todo', 'mac', '/tmp', 'claude', 'activity-test', 'idle');",
        )
        .unwrap();
        let body = Registration {
            conversation_id: "conversation".into(),
            token: TOKEN.into(),
            environment: ApnsEnvironment::Sandbox,
        };
        let response = register(
            web::Data::new(pool.clone()),
            web::Path::from("activity".to_string()),
            web::Json(body),
            None,
        )
        .await;
        assert_eq!(response.status(), 204);
        assert!(targets(&pool).unwrap()[0].ended());
        assert_eq!(targets(&pool).unwrap()[0].status, "idle");
        conn.execute("DELETE FROM conversations WHERE id = 'conversation'", [])
            .unwrap();
        assert!(targets(&pool).unwrap()[0].ended());

        let response = unregister(
            web::Data::new(pool.clone()),
            web::Path::from("activity".to_string()),
            None,
        )
        .await;
        assert_eq!(response.status(), 204);
        assert!(targets(&pool).unwrap().is_empty());
    }

    #[tokio::test]
    async fn activity_push_uses_the_activity_topic_and_payload() {
        let transport = FakeTransport::scripted(vec![]);
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let mut target = Target {
            id: "activity".into(),
            token: TOKEN.into(),
            environment: ApnsEnvironment::Sandbox,
            tool: "codex".into(),
            status: "waiting".into(),
            message: Some("Codex needs approval".into()),
            revision: 8,
            decided: false,
            identifiable_prompt: true,
            delivery_unknown: false,
        };
        assert!(matches!(
            sender
                .send_live(target.environment, &target.token, target.payload())
                .await,
            Outcome::Sent
        ));
        let calls = transport.calls.lock().unwrap();
        let (_, _, headers, payload) = &calls[0];
        assert!(headers
            .iter()
            .any(|(key, value)| *key == "apns-push-type" && value == "liveactivity"));
        assert!(
            headers
                .iter()
                .any(|(key, value)| *key == "apns-topic"
                    && value.ends_with(".push-type.liveactivity"))
        );
        assert_eq!(payload["aps"]["event"], "update");
        assert_eq!(payload["aps"]["content-state"]["canDecide"], true);
        assert_eq!(payload["aps"]["content-state"]["statusRevision"], 8);

        target.message = Some("Codex needs your answer".into());
        assert_eq!(target.payload()["aps"]["content-state"]["canDecide"], false);
        target.status = "idle".into();
        let end = target.payload();
        assert_eq!(end["aps"]["event"], "end");
        assert_eq!(
            end["aps"]["content-state"]["finishedMessage"],
            "Turn complete"
        );
    }
}
