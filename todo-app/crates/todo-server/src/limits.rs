//! Usage-limit readings shared by every computer on one tool account, in memory.
//!
//! Each computer's `ai-todo-limits` claims the account's reading first. A fresh one (or one
//! paused by a 429) is answered from here; otherwise one caller gets a short lease to ask the
//! tool's usage endpoint and post the result, so a subscription sees one request per
//! `FRESH`, however many apps and computers poll. The hub stores only the windows the script
//! prints and a hash of the account id, never a token. A restart forgets them: the next claim
//! simply fetches again.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use actix_web::http::StatusCode;
use actix_web::{web, HttpResponse};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::conversations::error;

/// A reading younger than this is reused.
const FRESH: Duration = Duration::from_secs(120);
/// How long the claimer may take to fetch and post before another caller may try.
const LEASE: Duration = Duration::from_secs(30);
/// A reading older than this is not returned, and is forgotten.
const STALE: Duration = Duration::from_secs(3600);
/// A 429 without a usable Retry-After pauses this long.
const DEFAULT_BACKOFF: Duration = Duration::from_secs(300);
const MAX_WINDOWS: usize = 16;

#[derive(Default)]
struct Account {
    windows: Option<Value>,
    fetched: Option<Instant>,
    blocked_until: Option<Instant>,
    lease_until: Option<Instant>,
}

impl Account {
    fn age(&self, now: Instant) -> Option<Duration> {
        self.fetched.map(|at| now.saturating_duration_since(at))
    }

    fn forgettable(&self, now: Instant) -> bool {
        self.age(now).is_none_or(|age| age > STALE)
            && self.blocked_until.is_none_or(|until| until <= now)
            && self.lease_until.is_none_or(|until| until <= now)
    }
}

/// What a claim answers: the latest reading under `STALE` (if any), and whether this caller
/// holds the lease and should fetch.
#[derive(Debug, PartialEq)]
pub struct Claim {
    pub fetch: bool,
    pub windows: Option<Value>,
    pub age: Option<Duration>,
    pub blocked_for: Option<Duration>,
}

/// What the claimer reports after fetching.
pub enum Report {
    Windows(Value),
    RateLimited(Option<u64>),
    Failed,
}

#[derive(Clone, Default)]
pub struct SharedLimits {
    accounts: Arc<Mutex<HashMap<String, Account>>>,
}

impl SharedLimits {
    pub fn claim(&self, key: &str, now: Instant) -> Claim {
        let mut accounts = self.accounts.lock().unwrap();
        accounts.retain(|k, account| k == key || !account.forgettable(now));
        let account = accounts.entry(key.to_string()).or_default();
        let age = account.age(now);
        let fresh = age.is_some_and(|age| age < FRESH);
        let blocked_for = account.blocked_until.filter(|until| *until > now).map(|until| until - now);
        let leased = account.lease_until.is_some_and(|until| until > now);
        let fetch = !fresh && blocked_for.is_none() && !leased;
        if fetch {
            account.lease_until = Some(now + LEASE);
        }
        let recent = age.filter(|age| *age <= STALE);
        Claim {
            fetch,
            windows: recent.and(account.windows.clone()),
            age: recent,
            blocked_for,
        }
    }

    pub fn report(&self, key: &str, report: Report, now: Instant) {
        let mut accounts = self.accounts.lock().unwrap();
        let account = accounts.entry(key.to_string()).or_default();
        account.lease_until = None;
        match report {
            Report::Windows(windows) => {
                account.windows = Some(windows);
                account.fetched = Some(now);
                account.blocked_until = None;
            }
            Report::RateLimited(seconds) => {
                let pause = seconds
                    .filter(|s| *s > 0)
                    .map(|s| Duration::from_secs(s).min(STALE))
                    .unwrap_or(DEFAULT_BACKOFF);
                account.blocked_until = Some(now + pause);
            }
            Report::Failed => {}
        }
    }
}

/// `claude-` or `cursor-` and 16–64 lowercase hex characters (a hash of the account id).
fn valid_key(key: &str) -> bool {
    let Some((tool, hash)) = key.split_once('-') else { return false };
    matches!(tool, "claude" | "cursor")
        && (16..=64).contains(&hash.len())
        && hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub async fn claim_limits(shared: web::Data<SharedLimits>, path: web::Path<String>) -> HttpResponse {
    let key = path.into_inner();
    if !valid_key(&key) {
        return error(StatusCode::BAD_REQUEST, "Invalid account key");
    }
    let claim = shared.claim(&key, Instant::now());
    HttpResponse::Ok().json(json!({
        "fetch": claim.fetch,
        "windows": claim.windows,
        "age_seconds": claim.age.map(|age| age.as_secs()),
        "blocked_seconds": claim.blocked_for.map(|d| d.as_secs().max(1)),
    }))
}

#[derive(Deserialize)]
pub struct ReportBody {
    windows: Option<Value>,
    retry_after: Option<u64>,
    #[serde(default)]
    rate_limited: bool,
}

pub async fn report_limits(
    shared: web::Data<SharedLimits>,
    path: web::Path<String>,
    body: web::Json<ReportBody>,
) -> HttpResponse {
    let key = path.into_inner();
    if !valid_key(&key) {
        return error(StatusCode::BAD_REQUEST, "Invalid account key");
    }
    let body = body.into_inner();
    let report = match body.windows {
        Some(Value::Array(windows)) if windows.len() <= MAX_WINDOWS => Report::Windows(Value::Array(windows)),
        Some(_) => return error(StatusCode::BAD_REQUEST, "windows must be a list of at most 16"),
        None if body.rate_limited => Report::RateLimited(body.retry_after),
        None => Report::Failed,
    };
    shared.report(&key, report, Instant::now());
    HttpResponse::NoContent().finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::http::Method;

    const KEY: &str = "claude-0123456789abcdef0123456789abcdef";

    #[test]
    fn one_claimer_fetches_and_the_rest_reuse_its_reading() {
        let shared = SharedLimits::default();
        let t0 = Instant::now();
        let first = shared.claim(KEY, t0);
        assert!(first.fetch);
        assert_eq!(first.windows, None);
        // Another computer while the lease is held: no fetch, nothing to show yet.
        let second = shared.claim(KEY, t0 + Duration::from_secs(5));
        assert!(!second.fetch);
        shared.report(KEY, Report::Windows(json!([{"kind": "5h", "used_percent": 40.0}])), t0 + Duration::from_secs(6));
        let reuse = shared.claim(KEY, t0 + Duration::from_secs(60));
        assert!(!reuse.fetch);
        assert_eq!(reuse.windows, Some(json!([{"kind": "5h", "used_percent": 40.0}])));
        assert_eq!(reuse.age, Some(Duration::from_secs(54)));
        // Past FRESH: one caller fetches again and still gets the old reading to show.
        let refetch = shared.claim(KEY, t0 + Duration::from_secs(200));
        assert!(refetch.fetch);
        assert!(refetch.windows.is_some());
        assert!(!shared.claim(KEY, t0 + Duration::from_secs(201)).fetch);
    }

    #[test]
    fn an_abandoned_lease_expires() {
        let shared = SharedLimits::default();
        let t0 = Instant::now();
        assert!(shared.claim(KEY, t0).fetch);
        assert!(!shared.claim(KEY, t0 + Duration::from_secs(29)).fetch);
        assert!(shared.claim(KEY, t0 + Duration::from_secs(31)).fetch);
    }

    #[test]
    fn a_failure_frees_the_lease_and_a_429_pauses_everyone() {
        let shared = SharedLimits::default();
        let t0 = Instant::now();
        assert!(shared.claim(KEY, t0).fetch);
        shared.report(KEY, Report::Failed, t0);
        assert!(shared.claim(KEY, t0).fetch);
        shared.report(KEY, Report::RateLimited(Some(250)), t0);
        let paused = shared.claim(KEY, t0 + Duration::from_secs(100));
        assert!(!paused.fetch);
        assert_eq!(paused.blocked_for, Some(Duration::from_secs(150)));
        assert!(shared.claim(KEY, t0 + Duration::from_secs(251)).fetch);
        // Without a Retry-After the pause is the default.
        shared.report(KEY, Report::RateLimited(None), t0 + Duration::from_secs(251));
        assert!(!shared.claim(KEY, t0 + Duration::from_secs(251 + 299)).fetch);
        assert!(shared.claim(KEY, t0 + Duration::from_secs(251 + 301)).fetch);
    }

    #[test]
    fn readings_past_an_hour_are_not_returned() {
        let shared = SharedLimits::default();
        let t0 = Instant::now();
        shared.claim(KEY, t0);
        shared.report(KEY, Report::Windows(json!([])), t0);
        let old = shared.claim(KEY, t0 + Duration::from_secs(3601));
        assert!(old.fetch);
        assert_eq!(old.windows, None);
        assert_eq!(old.age, None);
    }

    #[test]
    fn accounts_are_separate() {
        let shared = SharedLimits::default();
        let t0 = Instant::now();
        assert!(shared.claim(KEY, t0).fetch);
        assert!(shared.claim("cursor-0123456789abcdef0123456789abcdef", t0).fetch);
    }

    #[test]
    fn keys_are_a_tool_and_a_hex_hash() {
        assert!(valid_key(KEY));
        assert!(valid_key("cursor-0123456789abcdef"));
        assert!(!valid_key("codex-0123456789abcdef"));
        assert!(!valid_key("claude-0123"));
        assert!(!valid_key("claude-0123456789ABCDEF"));
        assert!(!valid_key("claude-../../etc/passwd00"));
        assert!(!valid_key("claude0123456789abcdef"));
    }

    #[actix_web::test]
    async fn claim_and_report_over_http() {
        let (_db, pool) = crate::test_support::pool("limits");
        let uri = format!("/api/limits/{KEY}");
        let (status, claim) = crate::test_support::post(&pool, &format!("{uri}/claim"), json!({})).await;
        assert_eq!(status, StatusCode::OK, "{claim}");
        assert_eq!(claim["fetch"], true);
        assert_eq!(claim["windows"], Value::Null);
        let (status, _) = crate::test_support::put(&pool, &uri, json!({"windows": [{"kind": "5h", "used_percent": 12.0}]})).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (_, claim) = crate::test_support::post(&pool, &format!("{uri}/claim"), json!({})).await;
        assert_eq!(claim["fetch"], false);
        assert_eq!(claim["windows"][0]["used_percent"], 12.0);
        assert_eq!(claim["age_seconds"], 0);

        let (status, _) = crate::test_support::put(&pool, &uri, json!({"windows": "nope"})).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _) = crate::test_support::call(&pool, Method::POST, "/api/limits/claude-xyz/claim", None).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}
