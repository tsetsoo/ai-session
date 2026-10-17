//! APNs client: ES256 provider JWT, alert payload, HTTP/2 transport and the response table
//! from the design (retry, environment fallback, dead-token removal).

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use todo_shared::{ApnsEnvironment, PushTestResult};

use crate::db::DbPool;
use crate::push::store::{self, token_prefix, DeviceTarget};

pub const PRODUCTION_HOST: &str = "https://api.push.apple.com";
pub const SANDBOX_HOST: &str = "https://api.sandbox.push.apple.com";

/// Apple rejects provider tokens older than an hour; re-sign well before that.
const JWT_MAX_AGE: Duration = Duration::from_secs(40 * 60);
/// Apple answers more frequent re-signing with `TooManyProviderTokenUpdates`.
const JWT_MIN_REFRESH: Duration = Duration::from_secs(20 * 60);
/// Waits before the 2nd, 3rd and 4th attempt after 429/5xx/network errors.
const RETRY_DELAYS: [Duration; 3] = [Duration::from_secs(2), Duration::from_secs(10), Duration::from_secs(30)];
/// How long Apple keeps a push for an offline phone; older than that is stale.
const EXPIRATION_SECS: u64 = 3600;
const TITLE_MAX_CHARS: usize = 120;
pub const CATEGORY: &str = "TODO_CONVERSATION";

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The `.p8` key and its ids, from `APNS_KEY_PATH`, `APNS_KEY_ID` and `APNS_TEAM_ID`.
#[derive(Clone)]
pub struct ApnsConfig {
    pub key_id: String,
    pub team_id: String,
    pub key_pkcs8_der: Vec<u8>,
}

impl std::fmt::Debug for ApnsConfig {
    // Never print the key.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApnsConfig").field("key_id", &self.key_id).field("team_id", &self.team_id).finish_non_exhaustive()
    }
}

impl ApnsConfig {
    /// `Ok(None)` when none of the variables is set (push not configured).
    ///
    /// # Errors
    /// Some but not all variables set, an unreadable key file, or a key that isn't a P-256 PKCS#8 key.
    pub fn from_env() -> Result<Option<Self>, String> {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        match (var("APNS_KEY_PATH"), var("APNS_KEY_ID"), var("APNS_TEAM_ID")) {
            (None, None, None) => Ok(None),
            (Some(path), Some(key_id), Some(team_id)) => {
                let pem = std::fs::read_to_string(&path).map_err(|e| format!("cannot read APNS_KEY_PATH ({path}): {e}"))?;
                Self::from_pem(key_id.trim(), team_id.trim(), &pem).map(Some)
            }
            _ => Err("APNS_KEY_PATH, APNS_KEY_ID and APNS_TEAM_ID must all be set".into()),
        }
    }

    /// # Errors
    /// When `pem` isn't a base64 PKCS#8 P-256 private key.
    pub fn from_pem(key_id: &str, team_id: &str, pem: &str) -> Result<Self, String> {
        let body: String = pem.lines().filter(|l| !l.starts_with("-----")).map(str::trim).collect();
        let der = base64::engine::general_purpose::STANDARD
            .decode(body)
            .map_err(|_| "the APNs key is not a PEM file".to_string())?;
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &SystemRandom::new())
            .map_err(|_| "the APNs key is not a P-256 PKCS#8 private key".to_string())?;
        Ok(Self { key_id: key_id.into(), team_id: team_id.into(), key_pkcs8_der: der })
    }
}

/// Signs and caches the provider token (`authorization: bearer <jwt>`).
pub struct JwtSigner {
    key: EcdsaKeyPair,
    key_id: String,
    team_id: String,
    rng: SystemRandom,
    cached: Option<(String, SystemTime)>,
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

impl JwtSigner {
    /// # Errors
    /// When the key isn't a P-256 PKCS#8 key.
    pub fn new(config: &ApnsConfig) -> Result<Self, String> {
        let rng = SystemRandom::new();
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &config.key_pkcs8_der, &rng)
            .map_err(|_| "the APNs key is not a P-256 PKCS#8 private key".to_string())?;
        Ok(Self { key, key_id: config.key_id.clone(), team_id: config.team_id.clone(), rng, cached: None })
    }

    /// The cached token, re-signed once it is 40 minutes old.
    pub fn token(&mut self, now: SystemTime) -> String {
        match &self.cached {
            Some((jwt, signed)) if now.duration_since(*signed).unwrap_or_default() < JWT_MAX_AGE => jwt.clone(),
            _ => self.sign(now),
        }
    }

    /// Re-sign after Apple rejected the token; `false` (nothing changes) within 20 minutes
    /// of the last signing.
    pub fn force_refresh(&mut self, now: SystemTime) -> bool {
        if let Some((_, signed)) = &self.cached {
            if now.duration_since(*signed).unwrap_or_default() < JWT_MIN_REFRESH {
                return false;
            }
        }
        self.sign(now);
        true
    }

    fn sign(&mut self, now: SystemTime) -> String {
        let iat = now.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let header = serde_json::json!({"alg": "ES256", "kid": self.key_id});
        let claims = serde_json::json!({"iss": self.team_id, "iat": iat});
        let message = format!("{}.{}", b64url(header.to_string().as_bytes()), b64url(claims.to_string().as_bytes()));
        let signature = self.key.sign(&self.rng, message.as_bytes()).expect("ECDSA signing failed");
        let jwt = format!("{message}.{}", b64url(signature.as_ref()));
        self.cached = Some((jwt.clone(), now));
        jwt
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushKind {
    Waiting,
    Done { minutes: u32 },
    Test,
}

impl PushKind {
    fn as_str(self) -> &'static str {
        match self {
            PushKind::Waiting => "waiting",
            PushKind::Done { .. } => "done",
            PushKind::Test => "test",
        }
    }

    fn body(self) -> String {
        match self {
            PushKind::Waiting => "Needs you".into(),
            PushKind::Done { minutes } => format!("Done after {minutes} min"),
            PushKind::Test => "Test notification".into(),
        }
    }
}

/// One notification. Never carries conversation content.
#[derive(Debug, Clone, PartialEq)]
pub struct Alert {
    /// `None` only for test pushes
    pub todo_id: Option<String>,
    pub session_id: Option<String>,
    pub title: String,
    /// `<section> · <computer name>`
    pub subtitle: String,
    pub kind: PushKind,
    /// Quiet hours: no sound, no lighting up
    pub passive: bool,
}

fn truncate_title(title: &str) -> String {
    if title.chars().count() <= TITLE_MAX_CHARS {
        return title.to_string();
    }
    let mut short: String = title.chars().take(TITLE_MAX_CHARS - 1).collect();
    short.push('…');
    short
}

pub fn build_payload(alert: &Alert) -> serde_json::Value {
    let mut aps = serde_json::json!({
        "alert": {"title": truncate_title(&alert.title), "subtitle": alert.subtitle, "body": alert.kind.body()},
        "category": CATEGORY,
        "interruption-level": if alert.passive { "passive" } else { "active" },
    });
    if !alert.passive {
        aps["sound"] = "default".into();
    }
    if let Some(todo_id) = &alert.todo_id {
        aps["thread-id"] = todo_id.as_str().into();
    }
    let mut payload = serde_json::json!({"aps": aps, "kind": alert.kind.as_str()});
    if let Some(todo_id) = &alert.todo_id {
        payload["todo_id"] = todo_id.as_str().into();
    }
    if let Some(session_id) = &alert.session_id {
        payload["session_id"] = session_id.as_str().into();
    }
    payload
}

/// Every header but `authorization`, which the sender adds.
pub fn headers(alert: &Alert, bundle_id: &str, now: SystemTime) -> Vec<(&'static str, String)> {
    let expiration = now.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()) + EXPIRATION_SECS;
    let mut headers = vec![
        ("apns-push-type", "alert".to_string()),
        ("apns-topic", bundle_id.to_string()),
        ("apns-priority", if alert.passive { "5" } else { "10" }.to_string()),
        ("apns-expiration", expiration.to_string()),
    ];
    if let Some(todo_id) = &alert.todo_id {
        // Same identity as the app's local alerts, so a newer alert for a todo replaces the older.
        headers.push(("apns-collapse-id", format!("todo-{todo_id}")));
    }
    headers
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApnsResponse {
    pub status: u16,
    pub reason: Option<String>,
    /// 410 only: when the token stopped being valid (ms since the epoch)
    pub timestamp_ms: Option<i64>,
}

/// POSTs one push. A trait so tests never reach Apple.
pub trait PushTransport: Send + Sync {
    fn post<'a>(
        &'a self,
        env: ApnsEnvironment,
        token: &'a str,
        headers: Vec<(&'static str, String)>,
        body: Vec<u8>,
    ) -> BoxFuture<'a, Result<ApnsResponse, String>>;
}

/// reqwest over HTTP/2 (ALPN) with rustls; one client, so one kept-alive connection per host.
pub struct HttpTransport {
    client: reqwest::Client,
    production_base: String,
    sandbox_base: String,
}

impl HttpTransport {
    #[must_use]
    pub fn new(production_base: String, sandbox_base: String) -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(15))
            .build()
            .expect("Failed to build the APNs HTTP client");
        Self { client, production_base, sandbox_base }
    }

    #[must_use]
    pub fn apple() -> Self {
        Self::new(PRODUCTION_HOST.into(), SANDBOX_HOST.into())
    }
}

impl PushTransport for HttpTransport {
    fn post<'a>(
        &'a self,
        env: ApnsEnvironment,
        token: &'a str,
        headers: Vec<(&'static str, String)>,
        body: Vec<u8>,
    ) -> BoxFuture<'a, Result<ApnsResponse, String>> {
        Box::pin(async move {
            let base = match env {
                ApnsEnvironment::Production => &self.production_base,
                ApnsEnvironment::Sandbox => &self.sandbox_base,
            };
            let mut request = self.client.post(format!("{base}/3/device/{token}")).body(body);
            for (name, value) in headers {
                request = request.header(name, value);
            }
            let response = request.send().await.map_err(|e| format!("network: {e}"))?;
            let status = response.status().as_u16();
            let bytes = response.bytes().await.map_err(|e| format!("network: {e}"))?;
            let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap_or_default();
            Ok(ApnsResponse {
                status,
                reason: json["reason"].as_str().map(str::to_string),
                timestamp_ms: json["timestamp"].as_i64(),
            })
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Sent,
    Retry,
    RefreshToken,
    WrongEnvironment,
    /// Delete the token, unless it was registered again after `unless_updated_after_ms`
    DeleteDevice { unless_updated_after_ms: Option<i64> },
    Failed(String),
}

/// The design's response table.
pub fn classify(response: &ApnsResponse) -> Outcome {
    let reason = response.reason.as_deref();
    match (response.status, reason) {
        (200, _) => Outcome::Sent,
        (410, _) => Outcome::DeleteDevice { unless_updated_after_ms: response.timestamp_ms },
        (400, Some("BadDeviceToken")) => Outcome::WrongEnvironment,
        (400, Some("DeviceTokenNotForTopic")) => Outcome::DeleteDevice { unless_updated_after_ms: None },
        (403, Some("ExpiredProviderToken" | "InvalidProviderToken")) => Outcome::RefreshToken,
        (429 | 500 | 503, _) => Outcome::Retry,
        (status, reason) => Outcome::Failed(reason.map_or_else(|| format!("HTTP {status}"), str::to_string)),
    }
}

fn now_text() -> String {
    chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string()
}

/// `datetime('now')` text → ms since the epoch.
fn sqlite_time_ms(text: &str) -> Option<i64> {
    chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S").ok().map(|t| t.and_utc().timestamp_millis())
}

#[derive(Default)]
struct SenderState {
    last_error: Option<String>,
    last_sent_at: Option<String>,
}

/// Sends alerts to devices and applies the response table to the device store.
pub struct ApnsSender {
    transport: Arc<dyn PushTransport>,
    signer: Mutex<JwtSigner>,
    state: Mutex<SenderState>,
}

impl ApnsSender {
    pub fn new(transport: Arc<dyn PushTransport>, signer: JwtSigner) -> Self {
        Self { transport, signer: Mutex::new(signer), state: Mutex::new(SenderState::default()) }
    }

    pub fn last_error(&self) -> Option<String> {
        self.state.lock().unwrap().last_error.clone()
    }

    pub fn last_sent_at(&self) -> Option<String> {
        self.state.lock().unwrap().last_sent_at.clone()
    }

    fn finish(&self, pool: &DbPool, target: &DeviceTarget, error: Option<String>) -> PushTestResult {
        let prefix = token_prefix(&target.token);
        if let Ok(conn) = pool.get() {
            if let Err(e) = store::record_result(&conn, &target.token, error.as_deref()) {
                println!("push: recording the result for {prefix}… failed: {e}");
            }
        }
        let mut state = self.state.lock().unwrap();
        match &error {
            None => {
                state.last_sent_at = Some(now_text());
                state.last_error = None;
            }
            Some(reason) => state.last_error = Some(reason.clone()),
        }
        PushTestResult { token_prefix: prefix, ok: error.is_none(), reason: error }
    }

    fn delete(&self, pool: &DbPool, target: &DeviceTarget, reason: &str) -> PushTestResult {
        if let Ok(conn) = pool.get() {
            let _ = store::delete_device(&conn, &target.token);
        }
        println!("push: removed device {}… ({reason})", token_prefix(&target.token));
        self.state.lock().unwrap().last_error = Some(reason.to_string());
        PushTestResult { token_prefix: token_prefix(&target.token), ok: false, reason: Some(reason.to_string()) }
    }

    /// Send `alert` to one device, with retries and the environment fallback.
    pub async fn send(&self, pool: &DbPool, target: &DeviceTarget, alert: &Alert) -> PushTestResult {
        let body = build_payload(alert).to_string().into_bytes();
        let prefix = token_prefix(&target.token);
        let mut env = target.environment;
        let mut tried_other_env = false;
        let mut refreshed = false;
        let mut retries = 0;
        loop {
            let now = SystemTime::now();
            let jwt = self.signer.lock().unwrap().token(now);
            let mut request_headers = headers(alert, &target.bundle_id, now);
            request_headers.push(("authorization", format!("bearer {jwt}")));
            let (outcome, reason) = match self.transport.post(env, &target.token, request_headers, body.clone()).await {
                Ok(response) => {
                    let reason = response.reason.clone().unwrap_or_else(|| format!("HTTP {}", response.status));
                    (classify(&response), reason)
                }
                Err(e) => (Outcome::Retry, e),
            };
            println!("push: {} to {prefix}… ({}): {outcome:?} {reason}", alert.kind.as_str(), env.as_str());
            match outcome {
                Outcome::Sent => {
                    if env != target.environment {
                        if let Ok(conn) = pool.get() {
                            let _ = store::update_device_environment(&conn, &target.token, env);
                        }
                    }
                    return self.finish(pool, target, None);
                }
                Outcome::Retry if retries < RETRY_DELAYS.len() => {
                    tokio::time::sleep(RETRY_DELAYS[retries]).await;
                    retries += 1;
                }
                Outcome::RefreshToken if !refreshed && self.signer.lock().unwrap().force_refresh(SystemTime::now()) => {
                    refreshed = true;
                }
                Outcome::WrongEnvironment if !tried_other_env => {
                    tried_other_env = true;
                    env = env.other();
                }
                Outcome::WrongEnvironment => return self.delete(pool, target, "BadDeviceToken"),
                Outcome::DeleteDevice { unless_updated_after_ms } => {
                    let reregistered = unless_updated_after_ms
                        .zip(sqlite_time_ms(&target.updated_at))
                        .is_some_and(|(invalid_since, updated)| updated > invalid_since);
                    if reregistered {
                        return self.finish(pool, target, Some(reason));
                    }
                    return self.delete(pool, target, &reason);
                }
                Outcome::Retry | Outcome::RefreshToken | Outcome::Failed(_) => return self.finish(pool, target, Some(reason)),
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::push::store;
    use crate::test_support::pool;
    use ring::rand::SystemRandom;
    use ring::signature::{EcdsaKeyPair, KeyPair, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING};
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    use todo_shared::{ApnsEnvironment, PushDeviceRequest, PushPlatform};

    pub(crate) const TOKEN: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    pub(crate) fn test_config() -> ApnsConfig {
        let der = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &SystemRandom::new()).unwrap();
        ApnsConfig { key_id: "KEY1234567".into(), team_id: "233QTK6KCL".into(), key_pkcs8_der: der.as_ref().to_vec() }
    }

    fn b64(part: &str) -> Vec<u8> {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(part).unwrap()
    }

    fn at(secs: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(secs)
    }

    #[derive(Default)]
    pub(crate) struct FakeTransport {
        pub responses: Mutex<VecDeque<Result<ApnsResponse, String>>>,
        pub calls: Mutex<Vec<(ApnsEnvironment, String, Vec<(&'static str, String)>, serde_json::Value)>>,
    }

    impl FakeTransport {
        pub(crate) fn scripted(responses: Vec<Result<ApnsResponse, String>>) -> Arc<Self> {
            Arc::new(Self { responses: Mutex::new(responses.into()), ..Default::default() })
        }

        pub(crate) fn ok() -> ApnsResponse {
            ApnsResponse { status: 200, reason: None, timestamp_ms: None }
        }

        pub(crate) fn reason(status: u16, reason: &str) -> ApnsResponse {
            ApnsResponse { status, reason: Some(reason.into()), timestamp_ms: None }
        }

        pub(crate) fn call_count(&self) -> usize {
            self.calls.lock().unwrap().len()
        }
    }

    impl PushTransport for FakeTransport {
        fn post<'a>(
            &'a self,
            env: ApnsEnvironment,
            token: &'a str,
            headers: Vec<(&'static str, String)>,
            body: Vec<u8>,
        ) -> BoxFuture<'a, Result<ApnsResponse, String>> {
            self.calls.lock().unwrap().push((env, token.to_string(), headers, serde_json::from_slice(&body).unwrap()));
            let next = self.responses.lock().unwrap().pop_front().unwrap_or_else(|| Ok(Self::ok()));
            Box::pin(async move { next })
        }
    }

    pub(crate) fn waiting_alert() -> Alert {
        Alert {
            todo_id: Some("t1".into()),
            session_id: Some("sess-1".into()),
            title: "Fix invoice export".into(),
            subtitle: "Si · tsvetelins-macbook-pro".into(),
            kind: PushKind::Waiting,
            passive: false,
        }
    }

    fn register(conn: &rusqlite::Connection, env: ApnsEnvironment) {
        store::upsert_device(
            conn,
            &PushDeviceRequest {
                token: TOKEN.into(),
                platform: PushPlatform::Ios,
                environment: env,
                bundle_id: "com.aisessionremote.app".into(),
                app_version: "1.0".into(),
                device_name: None,
            },
        )
        .unwrap();
    }

    #[test]
    fn jwt_verifies_with_public_key_and_is_cached() {
        let config = test_config();
        let public = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &config.key_pkcs8_der, &SystemRandom::new())
            .unwrap()
            .public_key()
            .as_ref()
            .to_vec();
        let mut signer = JwtSigner::new(&config).unwrap();
        let jwt = signer.token(at(1_000_000));
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header: serde_json::Value = serde_json::from_slice(&b64(parts[0])).unwrap();
        assert_eq!(header, serde_json::json!({"alg": "ES256", "kid": "KEY1234567"}));
        let claims: serde_json::Value = serde_json::from_slice(&b64(parts[1])).unwrap();
        assert_eq!(claims, serde_json::json!({"iss": "233QTK6KCL", "iat": 1_000_000}));
        let message = format!("{}.{}", parts[0], parts[1]);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public).verify(message.as_bytes(), &b64(parts[2])).unwrap();

        assert_eq!(signer.token(at(1_000_000 + 39 * 60)), jwt, "cached for 40 minutes");
        assert_ne!(signer.token(at(1_000_000 + 40 * 60)), jwt, "re-signed after 40 minutes");
    }

    #[test]
    fn force_refresh_is_rate_limited_to_20_minutes() {
        let mut signer = JwtSigner::new(&test_config()).unwrap();
        let first = signer.token(at(2_000_000));
        assert!(!signer.force_refresh(at(2_000_000 + 19 * 60)));
        assert_eq!(signer.token(at(2_000_000 + 19 * 60)), first);
        assert!(signer.force_refresh(at(2_000_000 + 20 * 60)));
        assert_ne!(signer.token(at(2_000_000 + 20 * 60)), first);
    }

    #[test]
    fn config_reads_pem_and_rejects_garbage() {
        let config = test_config();
        let body = base64::engine::general_purpose::STANDARD.encode(&config.key_pkcs8_der);
        let pem = format!("-----BEGIN PRIVATE KEY-----\n{}\n{}\n-----END PRIVATE KEY-----\n", &body[..64], &body[64..]);
        let parsed = ApnsConfig::from_pem("K", "T", &pem).unwrap();
        assert_eq!(parsed.key_pkcs8_der, config.key_pkcs8_der);
        assert!(ApnsConfig::from_pem("K", "T", "not a key").is_err());
    }

    #[test]
    fn payload_has_ids_thread_category_and_no_message() {
        let payload = build_payload(&waiting_alert());
        assert_eq!(
            payload,
            serde_json::json!({
                "aps": {
                    "alert": {"title": "Fix invoice export", "subtitle": "Si · tsvetelins-macbook-pro", "body": "Needs you"},
                    "sound": "default",
                    "thread-id": "t1",
                    "category": "TODO_CONVERSATION",
                    "interruption-level": "active"
                },
                "todo_id": "t1",
                "session_id": "sess-1",
                "kind": "waiting"
            })
        );
        let done = build_payload(&Alert { kind: PushKind::Done { minutes: 14 }, ..waiting_alert() });
        assert_eq!(done["aps"]["alert"]["body"], "Done after 14 min");
        assert_eq!(done["kind"], "done");
        let headers = headers(&waiting_alert(), "com.aisessionremote.app", at(1_700_000_000));
        let get = |k: &str| headers.iter().find(|(name, _)| *name == k).map(|(_, v)| v.as_str());
        assert_eq!(get("apns-push-type"), Some("alert"));
        assert_eq!(get("apns-topic"), Some("com.aisessionremote.app"));
        assert_eq!(get("apns-priority"), Some("10"));
        assert_eq!(get("apns-expiration"), Some("1700003600"));
        assert_eq!(get("apns-collapse-id"), Some("todo-t1"));
    }

    #[test]
    fn passive_payload_has_no_sound_and_priority_5() {
        let alert = Alert { passive: true, ..waiting_alert() };
        let payload = build_payload(&alert);
        assert_eq!(payload["aps"]["interruption-level"], "passive");
        assert!(payload["aps"].get("sound").is_none());
        let headers = headers(&alert, "b", at(0));
        assert!(headers.contains(&("apns-priority", "5".to_string())));
    }

    #[test]
    fn title_truncated_to_120_chars() {
        let long = "é".repeat(130);
        let payload = build_payload(&Alert { title: long, ..waiting_alert() });
        let title = payload["aps"]["alert"]["title"].as_str().unwrap();
        assert_eq!(title.chars().count(), 120);
        assert!(title.ends_with('…'));
        let short = build_payload(&waiting_alert());
        assert_eq!(short["aps"]["alert"]["title"], "Fix invoice export");
    }

    #[test]
    fn classify_covers_response_table() {
        let r = FakeTransport::reason;
        assert_eq!(classify(&FakeTransport::ok()), Outcome::Sent);
        assert_eq!(
            classify(&ApnsResponse { status: 410, reason: Some("Unregistered".into()), timestamp_ms: Some(42) }),
            Outcome::DeleteDevice { unless_updated_after_ms: Some(42) }
        );
        assert_eq!(classify(&r(400, "BadDeviceToken")), Outcome::WrongEnvironment);
        assert_eq!(classify(&r(400, "DeviceTokenNotForTopic")), Outcome::DeleteDevice { unless_updated_after_ms: None });
        assert_eq!(classify(&r(403, "ExpiredProviderToken")), Outcome::RefreshToken);
        assert_eq!(classify(&r(403, "InvalidProviderToken")), Outcome::RefreshToken);
        for status in [429, 500, 503] {
            assert_eq!(classify(&r(status, "x")), Outcome::Retry, "{status}");
        }
        assert_eq!(classify(&r(413, "PayloadTooLarge")), Outcome::Failed("PayloadTooLarge".into()));
        assert_eq!(
            classify(&ApnsResponse { status: 400, reason: None, timestamp_ms: None }),
            Outcome::Failed("HTTP 400".into())
        );
    }

    #[tokio::test]
    async fn bad_device_token_retries_other_environment_and_stores_it() {
        let (_db, pool) = pool("apns");
        register(&pool.get().unwrap(), ApnsEnvironment::Production);
        let transport = FakeTransport::scripted(vec![Ok(FakeTransport::reason(400, "BadDeviceToken")), Ok(FakeTransport::ok())]);
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        let result = sender.send(&pool, &target, &waiting_alert()).await;
        assert!(result.ok, "{result:?}");
        let calls = transport.calls.lock().unwrap();
        assert_eq!((calls[0].0, calls[1].0), (ApnsEnvironment::Production, ApnsEnvironment::Sandbox));
        assert!(calls[0].2.iter().any(|(k, v)| *k == "authorization" && v.starts_with("bearer ")));
        drop(calls);
        assert_eq!(store::devices_for_push(&pool.get().unwrap()).unwrap()[0].environment, ApnsEnvironment::Sandbox);

        // Bad in both environments: the token is dead.
        let transport = FakeTransport::scripted(vec![
            Ok(FakeTransport::reason(400, "BadDeviceToken")),
            Ok(FakeTransport::reason(400, "BadDeviceToken")),
        ]);
        let sender = ApnsSender::new(transport, JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        assert!(!sender.send(&pool, &target, &waiting_alert()).await.ok);
        assert!(store::devices_for_push(&pool.get().unwrap()).unwrap().is_empty());
    }

    #[tokio::test]
    async fn unregistered_410_deletes_device() {
        let (_db, pool) = pool("apns");
        register(&pool.get().unwrap(), ApnsEnvironment::Sandbox);
        let now_ms = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap();
        let transport = FakeTransport::scripted(vec![Ok(ApnsResponse {
            status: 410,
            reason: Some("Unregistered".into()),
            timestamp_ms: Some(now_ms + 60_000),
        })]);
        let sender = ApnsSender::new(transport, JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        let result = sender.send(&pool, &target, &waiting_alert()).await;
        assert_eq!((result.ok, result.reason.as_deref()), (false, Some("Unregistered")));
        assert!(store::devices_for_push(&pool.get().unwrap()).unwrap().is_empty());
    }

    #[tokio::test]
    async fn unregistered_410_keeps_device_reregistered_later() {
        let (_db, pool) = pool("apns");
        register(&pool.get().unwrap(), ApnsEnvironment::Sandbox);
        // Apple says the token died a day ago; the app registered it again since.
        let day_ago_ms = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap() - 86_400_000;
        let transport = FakeTransport::scripted(vec![Ok(ApnsResponse {
            status: 410,
            reason: Some("Unregistered".into()),
            timestamp_ms: Some(day_ago_ms),
        })]);
        let sender = ApnsSender::new(transport, JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        assert!(!sender.send(&pool, &target, &waiting_alert()).await.ok);
        let devices = store::list_devices(&pool.get().unwrap()).unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].last_error.as_deref(), Some("Unregistered"));
    }

    #[tokio::test(start_paused = true)]
    async fn retries_then_gives_up() {
        let (_db, pool) = pool("apns");
        register(&pool.get().unwrap(), ApnsEnvironment::Sandbox);
        let transport = FakeTransport::scripted(vec![
            Ok(FakeTransport::reason(503, "ServiceUnavailable")),
            Err("connection reset".into()),
            Ok(FakeTransport::reason(429, "TooManyRequests")),
            Ok(FakeTransport::reason(500, "InternalServerError")),
        ]);
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        let started = tokio::time::Instant::now();
        let result = sender.send(&pool, &target, &waiting_alert()).await;
        assert_eq!((result.ok, result.reason.as_deref()), (false, Some("InternalServerError")));
        assert_eq!(transport.call_count(), 4);
        assert_eq!(started.elapsed(), Duration::from_secs(2 + 10 + 30));
        assert_eq!(store::list_devices(&pool.get().unwrap()).unwrap().len(), 1, "kept: not a dead token");
        assert_eq!(sender.last_error().as_deref(), Some("InternalServerError"));
    }

    #[tokio::test]
    async fn expired_provider_token_refreshes_once_then_reports() {
        let (_db, pool) = pool("apns");
        register(&pool.get().unwrap(), ApnsEnvironment::Sandbox);
        let transport = FakeTransport::scripted(vec![
            Ok(FakeTransport::reason(403, "ExpiredProviderToken")),
            Ok(FakeTransport::reason(403, "ExpiredProviderToken")),
        ]);
        // A signer that last signed long ago may refresh once; the second 403 is reported.
        let sender = ApnsSender::new(transport.clone(), JwtSigner::new(&test_config()).unwrap());
        let target = store::devices_for_push(&pool.get().unwrap()).unwrap().remove(0);
        let result = sender.send(&pool, &target, &waiting_alert()).await;
        assert_eq!((result.ok, result.reason.as_deref()), (false, Some("ExpiredProviderToken")));
        assert!(transport.call_count() <= 2);
        assert_eq!(sender.last_error().as_deref(), Some("ExpiredProviderToken"));
    }

    #[tokio::test]
    async fn http_transport_sends_path_headers_body() {
        use std::io::{BufRead, BufReader, Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = Vec::new();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                head.push(line.trim_end().to_string());
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).unwrap();
            let reply = r#"{"reason":"Unregistered","timestamp":1234}"#;
            write!(&stream, "HTTP/1.1 410 Gone\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{reply}", reply.len()).unwrap();
            (head, body)
        });
        let transport = HttpTransport::new(format!("{base}/prod"), base.clone());
        let response = transport
            .post(ApnsEnvironment::Sandbox, TOKEN, vec![("authorization", "bearer x.y.z".into()), ("apns-topic", "b".into())], b"{}".to_vec())
            .await
            .unwrap();
        assert_eq!(response, ApnsResponse { status: 410, reason: Some("Unregistered".into()), timestamp_ms: Some(1234) });
        let (head, body) = server.join().unwrap();
        assert_eq!(head[0], format!("POST /3/device/{TOKEN} HTTP/1.1"));
        let lower: Vec<String> = head.iter().map(|l| l.to_ascii_lowercase()).collect();
        assert!(lower.contains(&"authorization: bearer x.y.z".to_string()), "{head:?}");
        assert!(lower.contains(&"apns-topic: b".to_string()));
        assert_eq!(body, b"{}");
    }
}
