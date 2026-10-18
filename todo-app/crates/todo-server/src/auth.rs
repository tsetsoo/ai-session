//! Optional bearer-token auth for `/api/*`.
//!
//! Enabled only when `TODO_API_TOKEN` is set (unset means open, for local
//! development). `/api/health` stays open for the Pi updater, and
//! `/api/ws` also accepts `?token=` for WebSocket clients that can't set headers.

use actix_web::body::{EitherBody, MessageBody};
use actix_web::dev::{ServiceRequest, ServiceResponse};
use actix_web::middleware::Next;
use actix_web::{web, Error, HttpResponse};

#[derive(Clone)]
pub struct ApiToken(pub Option<String>);

impl ApiToken {
    pub fn from_env() -> Self {
        Self(std::env::var("TODO_API_TOKEN").ok().filter(|t| !t.trim().is_empty()))
    }
}

/// Compare without short-circuiting on the first differing byte.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Every token the request presents: the Bearer header, plus `?token=` on `/api/ws`.
fn presented_tokens(req: &ServiceRequest, path: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    if let Some((scheme, value)) = req
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split_once(' '))
    {
        if scheme.eq_ignore_ascii_case("bearer") {
            tokens.push(value.trim().to_string());
        }
    }
    if path == "/api/ws" {
        if let Some(t) = web::Query::<std::collections::HashMap<String, String>>::from_query(req.query_string())
            .ok()
            .and_then(|q| q.get("token").cloned())
        {
            tokens.push(t);
        }
    }
    tokens
}

fn is_allowed(req: &ServiceRequest) -> bool {
    let Some(expected) = req.app_data::<web::Data<ApiToken>>().and_then(|t| t.0.clone()) else {
        return true;
    };
    // The router matches on the percent-decoded path, so check that one: the raw
    // `req.path()` would let `/%61pi/todos` through to `/api/todos`.
    let path = req.match_info().as_str();
    if !path.starts_with("/api/") || path == "/api/health" {
        return true;
    }
    presented_tokens(req, path)
        .iter()
        .any(|t| constant_time_eq(t.as_bytes(), expected.as_bytes()))
}

pub async fn require_token<B: MessageBody + 'static>(
    req: ServiceRequest,
    next: Next<B>,
) -> Result<ServiceResponse<EitherBody<B>>, Error> {
    if is_allowed(&req) {
        return next.call(req).await.map(ServiceResponse::map_into_left_body);
    }
    let response = HttpResponse::Unauthorized().json(serde_json::json!({"error": "Missing or invalid API token"}));
    Ok(req.into_response(response).map_into_right_body())
}

pub async fn health() -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({"ok": true}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::{middleware::from_fn, test, App};

    async fn ok() -> HttpResponse {
        HttpResponse::Ok().finish()
    }

    fn app(token: Option<&str>) -> App<
        impl actix_web::dev::ServiceFactory<
            ServiceRequest,
            Config = (),
            Response = ServiceResponse<impl MessageBody>,
            Error = Error,
            InitError = (),
        >,
    > {
        App::new()
            .wrap(from_fn(require_token))
            .app_data(web::Data::new(ApiToken(token.map(str::to_string))))
            .route("/api/health", web::get().to(health))
            .route("/api/todos", web::get().to(ok))
            .route("/api/ws", web::get().to(ok))
            .route("/", web::get().to(ok))
    }

    async fn status(token: Option<&str>, req: test::TestRequest) -> u16 {
        let svc = test::init_service(app(token)).await;
        test::call_service(&svc, req.to_request()).await.status().as_u16()
    }

    #[actix_web::test]
    async fn open_when_no_token_configured() {
        assert_eq!(status(None, test::TestRequest::get().uri("/api/todos")).await, 200);
    }

    #[actix_web::test]
    async fn enforced_when_token_configured() {
        let t = Some("s3cret");
        assert_eq!(status(t, test::TestRequest::get().uri("/api/todos")).await, 401);
        assert_eq!(
            status(t, test::TestRequest::get().uri("/api/todos").insert_header(("Authorization", "Bearer wrong"))).await,
            401
        );
        assert_eq!(
            status(t, test::TestRequest::get().uri("/api/todos").insert_header(("Authorization", "Bearer s3cret"))).await,
            200
        );
        assert_eq!(status(t, test::TestRequest::get().uri("/api/ws?token=s3cret")).await, 200);
        assert_eq!(status(t, test::TestRequest::get().uri("/api/todos?token=s3cret")).await, 401);
        assert_eq!(status(t, test::TestRequest::get().uri("/api/health")).await, 200);
        assert_eq!(status(t, test::TestRequest::get().uri("/")).await, 200);
    }

    #[actix_web::test]
    async fn percent_encoded_api_path_still_needs_token() {
        let t = Some("s3cret");
        assert_eq!(status(t, test::TestRequest::get().uri("/%61pi/todos")).await, 401);
        assert_eq!(status(t, test::TestRequest::get().uri("/api/%74odos")).await, 401);
        assert_eq!(status(None, test::TestRequest::get().uri("/%61pi/todos")).await, 200);
    }

    #[actix_web::test]
    async fn any_valid_token_is_accepted() {
        let t = Some("s3cret");
        assert_eq!(
            status(t, test::TestRequest::get().uri("/api/todos").insert_header(("Authorization", "bearer s3cret"))).await,
            200
        );
        assert_eq!(
            status(
                t,
                test::TestRequest::get().uri("/api/ws?token=s3cret").insert_header(("Authorization", "Bearer stale"))
            )
            .await,
            200
        );
    }
}
