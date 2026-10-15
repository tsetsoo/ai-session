//! Optional bearer-token auth for `/api/*`.
//!
//! Enabled only when `TODO_API_TOKEN` is set, so the web UI keeps working until
//! the native apps ship. `/api/health` stays open for the Pi updater, and
//! `/api/ws` also accepts `?token=` for WebSocket clients that can't set headers.

use actix_web::body::{EitherBody, MessageBody};
use actix_web::dev::{ServiceRequest, ServiceResponse};
use actix_web::http::Method;
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

fn presented_token(req: &ServiceRequest) -> Option<String> {
    if let Some(bearer) = req
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    {
        return Some(bearer.trim().to_string());
    }
    if req.path() == "/api/ws" {
        return web::Query::<std::collections::HashMap<String, String>>::from_query(req.query_string())
            .ok()
            .and_then(|q| q.get("token").cloned());
    }
    None
}

fn is_allowed(req: &ServiceRequest) -> bool {
    let Some(expected) = req.app_data::<web::Data<ApiToken>>().and_then(|t| t.0.clone()) else {
        return true;
    };
    let path = req.path();
    if !path.starts_with("/api/") || path == "/api/health" || req.method() == Method::OPTIONS {
        return true;
    }
    presented_token(req).is_some_and(|t| constant_time_eq(t.as_bytes(), expected.as_bytes()))
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
}
