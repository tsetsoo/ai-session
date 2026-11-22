//! Optional bearer-token auth for `/api/*`.
//!
//! Enabled when a full-access token or scoped tokens are configured (otherwise open, for local
//! development). `/api/health` stays open for the Pi updater, and
//! `/api/ws` also accepts `?token=` for WebSocket clients that can't set headers.

use actix_web::body::{EitherBody, MessageBody};
use actix_web::dev::{ServiceRequest, ServiceResponse};
use actix_web::middleware::Next;
use actix_web::{web, Error, HttpMessage, HttpResponse};
use serde::Deserialize;
use std::{collections::{HashMap, HashSet}, io, sync::Arc};

#[derive(Clone)]
pub struct ApiToken(pub Option<String>);

#[derive(Clone, Default)]
pub struct ScopedTokens(HashMap<String, Arc<ResourceScope>>);

#[derive(Clone, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ResourceScope {
    pub project_ids: HashSet<String>,
    pub computer_ids: HashSet<String>,
    pub todo_ids: HashSet<String>,
    pub include_computer_projects: bool,
    helper_computer_id: Option<String>,
}

#[derive(Clone)]
pub struct HelperComputer(pub String);

pub type RequestHelper = Option<web::ReqData<HelperComputer>>;

pub fn authorize_helper_computer(helper: &RequestHelper, id: &str) -> Result<(), HttpResponse> {
    if helper.as_ref().is_some_and(|helper| helper.0 != id) {
        return Err(forbidden("Helper token belongs to another computer"));
    }
    Ok(())
}

pub type RequestScope = Option<web::ReqData<Arc<ResourceScope>>>;

impl ResourceScope {
    // Resolve inherited grants against the same database snapshot as the protected records.
    pub fn resolve_projects(&self, conn: &rusqlite::Connection) -> rusqlite::Result<Self> {
        let mut resolved = self.clone();
        if self.include_computer_projects {
            let mut stmt = conn.prepare(
                "SELECT p.id, sc.computer_id FROM projects p JOIN project_computers sc ON sc.project_id = p.id AND sc.computer_id IS NOT NULL",
            )?;
            let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
            for row in rows {
                let (project, computer) = row?;
                if self.computer_ids.contains(&computer) {
                    resolved.project_ids.insert(project);
                }
            }
        }
        Ok(resolved)
    }

    pub fn allows_todo(&self, id: &str, project_id: Option<&str>) -> bool {
        self.todo_ids.contains(id) || project_id.is_some_and(|id| self.project_ids.contains(id))
    }

    pub fn redact_todo(&self, todo: &mut todo_shared::Todo) {
        if todo.project_id.as_ref().is_some_and(|id| !self.project_ids.contains(id)) {
            todo.project_id = None;
        }
        todo.conversation_status = None;
        todo.scheduled_job_id = None;
        todo.scheduled_run_id = None;
    }

    pub fn redact_project(&self, project: &mut todo_shared::Project) {
        project.sessions = 0;
        project.memories = 0;
        project.last_activity = None;
    }

    pub fn allows_project(&self, project: &todo_shared::Project) -> bool {
        self.computer_ids.contains(&project.computer.id)
            && (self.include_computer_projects || self.project_ids.contains(&project.id))
    }
}

impl ScopedTokens {
    pub fn from_env(admin: &ApiToken) -> io::Result<Self> {
        match std::env::var("TODO_SCOPED_TOKENS_FILE") {
            Ok(path) => Self::parse(&std::fs::read(path)?, admin),
            Err(std::env::VarError::NotPresent) => Ok(Self::default()),
            Err(_) => Err(io::Error::new(io::ErrorKind::InvalidInput, "Invalid TODO_SCOPED_TOKENS_FILE")),
        }
    }

    fn parse(json: &[u8], admin: &ApiToken) -> io::Result<Self> {
        let tokens: HashMap<String, ResourceScope> = serde_json::from_slice(json)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Invalid scoped token file JSON"))?;
        if tokens.is_empty() || tokens.keys().any(|token| {
            token.len() < 32 || !token.bytes().all(|byte| byte.is_ascii_graphic())
                || admin.0.as_ref().is_some_and(|admin| admin == token)
        }) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Scoped token file must contain non-admin tokens of at least 32 visible ASCII characters"));
        }
        if tokens.values().any(|scope| scope.helper_computer_id.as_ref().is_some_and(|id| {
            id.trim().is_empty() || id.trim() != id || scope.include_computer_projects
                || !scope.project_ids.is_empty() || !scope.computer_ids.is_empty() || !scope.todo_ids.is_empty()
        })) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "A helper token must name exactly one computer and cannot have app grants"));
        }
        Ok(Self(tokens.into_iter().map(|(token, scope)| (token, Arc::new(scope))).collect()))
    }

    pub fn is_configured(&self) -> bool {
        !self.0.is_empty()
    }
}

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

pub fn resolve_scope(conn: &rusqlite::Connection, scope: RequestScope) -> Result<Option<ResourceScope>, HttpResponse> {
    scope.as_ref().map(|scope| scope.resolve_projects(conn)).transpose().map_err(crate::conversations::server_error)
}

pub(crate) fn forbidden(message: &str) -> HttpResponse {
    HttpResponse::Forbidden().json(serde_json::json!({"error": message}))
}

fn scoped_route(method: &actix_web::http::Method, path: &str) -> bool {
    use actix_web::http::Method;
    match (method, path.split('/').collect::<Vec<_>>().as_slice()) {
        (&Method::GET, ["", "api", "todos" | "projects" | "computers" | "conversations"])
        | (&Method::POST, ["", "api", "todos"]) => true,
        (&Method::GET | &Method::PATCH | &Method::DELETE, ["", "api", "todos", id]) =>
            !id.is_empty() && *id != "from-conversation",
        (&Method::GET | &Method::PATCH, ["", "api", "projects", id]) =>
            !id.is_empty() && *id != "suggestions",
        (&Method::PATCH, ["", "api", "computers", id])
        | (&Method::POST, ["", "api", "todos", id, "toggle" | "conversation"])
        | (&Method::POST, ["", "api", "conversations", id, "continue" | "reopen"])
        | (&Method::PUT, ["", "api", "conversations", id, "session"])
        | (&Method::DELETE, ["", "api", "conversations", id]) => !id.is_empty(),
        _ => false,
    }
}

fn helper_route(method: &actix_web::http::Method, path: &str) -> bool {
    use actix_web::http::Method;
    match (method, path.split('/').collect::<Vec<_>>().as_slice()) {
        (&Method::GET, ["", "api", "conversations" | "projects" | "computers" | "memories"])
        | (&Method::GET, ["", "api", "runner", "due"])
        | (&Method::GET, ["", "api", "updates", "runner"])
        | (&Method::POST, ["", "api", "updates", "match" | "summaries" | "reports"])
        | (&Method::POST, ["", "api", "runner", "pull-requests"])
        | (&Method::POST, ["", "api", "sessions", "stats"])
        | (&Method::POST, ["", "api", "memories", "bulk" | "import" | "uses"])
        | (&Method::POST, ["", "api", "conversations", "status" | "mcp" | "resume"]) => true,
        (&Method::PUT, ["", "api", "projects", id, "updates" | "weekly", day]) => !id.is_empty() && !day.is_empty(),
        (&Method::PUT, ["", "api", "conversations", id, "session"])
        | (&Method::POST, ["", "api", "runs", id, "claim" | "wait" | "start" | "finish" | "report"])
        | (&Method::POST, ["", "api", "watch", "issues", id, "resolve-result"])
        | (&Method::PUT, ["", "api", "computers", id, "watchers" | "job-templates" | "tools" | "health"]) => !id.is_empty(),
        _ => false,
    }
}

pub async fn require_token<B: MessageBody + 'static>(
    req: ServiceRequest,
    next: Next<B>,
) -> Result<ServiceResponse<EitherBody<B>>, Error> {
    let admin = req.app_data::<web::Data<ApiToken>>().and_then(|t| t.0.as_deref());
    let scoped = req.app_data::<web::Data<ScopedTokens>>();
    // Match the router's decoded path, including encoded API prefixes.
    let path = req.match_info().as_str();
    if !path.starts_with("/api/") || path == "/api/health"
        || (admin.is_none() && !scoped.is_some_and(|tokens| tokens.is_configured()))
    {
        return next.call(req).await.map(ServiceResponse::map_into_left_body);
    }
    let tokens = presented_tokens(&req, path);
    if admin.is_some_and(|admin| tokens.iter().any(|t| constant_time_eq(t.as_bytes(), admin.as_bytes()))) {
        return next.call(req).await.map(ServiceResponse::map_into_left_body);
    }
    if let Some(scope) = scoped.and_then(|scoped| scoped.0.iter().find_map(|(key, scope)| {
        tokens.iter().any(|token| constant_time_eq(token.as_bytes(), key.as_bytes())).then(|| scope.clone())
    })) {
        if let Some(id) = &scope.helper_computer_id {
            if helper_route(req.method(), path) {
                req.extensions_mut().insert(HelperComputer(id.clone()));
                return next.call(req).await.map(ServiceResponse::map_into_left_body);
            }
        } else if scoped_route(req.method(), path) {
            req.extensions_mut().insert(scope);
            return next.call(req).await.map(ServiceResponse::map_into_left_body);
        }
        let response = forbidden("API token does not grant access to this endpoint");
        return Ok(req.into_response(response).map_into_right_body());
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

    #[actix_web::test]
    async fn scoped_token_filters_real_routes_and_blocks_other_access() {
        const TOKEN: &str = "test-scoped-token-0000000000000000";
        const CODBEX_TOKEN: &str = "test-scoped-token-1111111111111111";
        let (_db, pool) = crate::test_support::pool("scoped-token");
        {
            let conn = pool.get().unwrap();
            crate::test_support::seed_computers(&conn);
            conn.execute_batch(
                "INSERT INTO projects (id, name, computer_id, folder) VALUES
                     ('allowed', 'Allowed', (SELECT id FROM computers WHERE id = 'spread'), '~/allowed'),
                     ('private', 'Private', (SELECT id FROM computers WHERE id = 'codbex'), '~/private');
                 INSERT INTO todos (id, title, project_id) VALUES
                     ('in-project', 'Project todo', 'allowed'),
                     ('explicit', 'Shared todo', 'private'),
                     ('hidden', 'Private todo', 'private');
                 INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id) VALUES
                     ('visible-chat', 'in-project', 'spread', '/tmp', 'claude', 'visible', 'visible'),
                     ('other-computer', 'in-project', 'codbex', '/tmp', 'claude', 'elsewhere', 'elsewhere'),
                     ('other-todo', 'hidden', 'spread', '/tmp', 'claude', 'private', 'private');"
            ).unwrap();
        }
        let admin = ApiToken(Some("admin".into()));
        let config = serde_json::json!({
            (TOKEN): {"include_computer_projects": true, "computer_ids": ["spread", "mac"], "todo_ids": ["explicit"]},
            (CODBEX_TOKEN): {"include_computer_projects": true, "computer_ids": ["codbex", "mac"]}
        });
        let scoped = ScopedTokens::parse(config.to_string().as_bytes(), &admin).unwrap();
        let app = test::init_service(App::new()
            .wrap(from_fn(require_token))
            .app_data(web::Data::new(admin))
            .app_data(web::Data::new(scoped))
            .app_data(web::Data::new(pool.clone()))
            .app_data(web::Data::new(crate::broadcast::Broadcaster::new()))
            .configure(crate::api_routes)).await;

        let get = |uri: &str| test::TestRequest::get()
            .uri(uri)
            .insert_header(("Authorization", format!("Bearer {TOKEN}")))
            .to_request();
        for (path, expected) in [
            ("/%61pi/todos?show=all", vec!["explicit", "in-project"]),
            ("/api/todos?project_id=private", vec!["explicit"]),
            ("/api/projects", vec!["allowed"]),
            ("/api/computers", vec!["mac", "spread"]),
            ("/api/conversations", vec!["visible-chat"]),
        ] {
            let response = test::call_service(&app, get(path)).await;
            assert_eq!(response.status(), 200, "{path}");
            let rows: Vec<serde_json::Value> = test::read_body_json(response).await;
            let mut ids: Vec<_> = rows.iter().map(|row| row["id"].as_str().unwrap()).collect();
            ids.sort_unstable();
            assert_eq!(ids, expected, "{path}");
        }
        let codbex_get = |path: &str| test::TestRequest::get().uri(path)
            .insert_header(("Authorization", format!("Bearer {CODBEX_TOKEN}"))).to_request();
        assert_eq!(test::call_service(&app, codbex_get("/api/todos/in-project")).await.status(), 404);
        assert_eq!(test::call_service(&app, codbex_get("/api/todos/hidden")).await.status(), 200);
        let explicit: serde_json::Value = test::call_and_read_body_json(&app, get("/api/todos/explicit")).await;
        assert!(explicit.get("project_id").is_none());
        for path in ["/api/todos/hidden", "/api/projects/private"] {
            assert_eq!(test::call_service(&app, get(path)).await.status(), 404, "{path}");
        }
        for path in ["/api/ws", "/api/projects/suggestions", "/api/memories", "/api/todos/explicit/usage"] {
            assert_eq!(test::call_service(&app, get(path)).await.status(), 403, "{path}");
        }
        use actix_web::http::Method;
        let write = |method: Method, path: &str, body: serde_json::Value| test::TestRequest::default()
            .method(method).uri(path)
            .insert_header(("Authorization", format!("Bearer {TOKEN}")))
            .set_json(body).to_request();

        for (method, path, body, status) in [
            (Method::PATCH, "/api/todos/explicit", serde_json::json!({"title": "Renamed share"}), 200),
            (Method::POST, "/api/todos/in-project/toggle", serde_json::json!(null), 200),
            (Method::PATCH, "/api/todos/hidden", serde_json::json!({"title": "blocked"}), 404),
            (Method::PATCH, "/api/todos/in-project", serde_json::json!({"title": "blocked", "project_id": "private"}), 404),
            (Method::POST, "/api/todos", serde_json::json!({"title": "Created", "project_id": "allowed"}), 201),
            (Method::POST, "/api/todos", serde_json::json!({"title": "blocked", "project_id": "private"}), 404),
            (Method::DELETE, "/api/todos/in-project", serde_json::json!(null), 403),
            (Method::DELETE, "/api/todos/explicit", serde_json::json!(null), 200),
            (Method::PATCH, "/api/projects/allowed", serde_json::json!({"name": "Renamed project", "mcp_default": ["filesystem"]}), 200),
            (Method::PATCH, "/api/projects/private", serde_json::json!({"name": "blocked"}), 404),
            (Method::PATCH, "/api/projects/allowed", serde_json::json!({"folder": "~/blocked"}), 403),
            (Method::PATCH, "/api/computers/spread", serde_json::json!({"name": "Renamed computer", "mcp_default": ["filesystem"]}), 200),
            (Method::PATCH, "/api/computers/codbex", serde_json::json!({"name": "blocked"}), 404),
            (Method::PATCH, "/api/computers/spread", serde_json::json!({"hostname": "blocked.tailnet"}), 403),
        ] {
            let request = write(method, path, body);
            let resp = test::call_service(&app, request).await;
            assert_eq!(resp.status(), status, "{path}");
        }
        {
            let conn = pool.get().unwrap();
            conn.execute_batch(
                "INSERT INTO todos (id, title, project_id) VALUES
                    ('start-spread', 'Spread start', 'allowed');
                UPDATE conversations SET status = 'waiting' WHERE id = 'other-computer';"
            ).unwrap();
        }
        let open = |path| write(Method::POST, path, serde_json::json!({"tool": "codex"}));
        for path in [
            "/api/todos/hidden/conversation",
            "/api/todos/in-project/conversation",
        ] {
            assert_eq!(test::call_service(&app, open(path)).await.status(), 404, "{path}");
        }
        let response = test::call_service(&app, open("/api/todos/start-spread/conversation")).await;
        assert_eq!(response.status(), 200);
        let chat: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(chat["computer"]["id"], "spread");
        assert_eq!(chat["created"], true);
        let chat_id = chat["id"].as_str().unwrap();
        {
            let conn = pool.get().unwrap();
            conn.execute("UPDATE conversations SET status = 'closed' WHERE id = ?1", [chat_id]).unwrap();
            conn.execute(
                "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id)
                 VALUES ('spread-sibling', 'start-spread', 'spread', '/tmp', 'claude', 'sibling', 'sibling')",
                [],
            ).unwrap();
        }
        for (id, action, status) in [
            ("other-todo", "reopen", 404),
            ("other-computer", "continue", 404),
            ("visible-chat", "continue", 403),
            (chat_id, "reopen", 200),
            (chat_id, "continue", 200),
        ] {
            let path = format!("/api/conversations/{id}/{action}");
            let request = write(Method::POST, &path, serde_json::Value::Null);
            assert_eq!(test::call_service(&app, request).await.status(), status, "{path}");
        }
        {
            let conn = pool.get().unwrap();
            let sibling_status: String = conn.query_row(
                "SELECT status FROM conversations WHERE id = 'spread-sibling'",
                [], |row| row.get(0),
            ).unwrap();
            assert_eq!(sibling_status, "closed");
        }
        for (id, status) in [("other-computer", 404), ("other-todo", 404), (chat_id, 200)] {
            let path = format!("/api/conversations/{id}/session");
            let request = write(Method::PUT, &path, serde_json::json!({
                "session_id": "new-codex-id", "expected_session_id": ""
            }));
            assert_eq!(test::call_service(&app, request).await.status(), status, "{path}");
        }
        for (id, status) in [("other-computer", 404), ("other-todo", 404), (chat_id, 200)] {
            let path = format!("/api/conversations/{id}");
            let request = write(Method::DELETE, &path, serde_json::Value::Null);
            assert_eq!(test::call_service(&app, request).await.status(), status, "{path}");
        }
        assert_eq!(test::call_service(
            &app, write(Method::DELETE, "/api/todos/start-spread", serde_json::Value::Null),
        ).await.status(), 200);
        let todo: serde_json::Value = test::call_and_read_body_json(&app, get("/api/todos/in-project")).await;
        assert_eq!(todo["title"], "Project todo");
        assert_eq!(todo["completed"], true);

        {
            let conn = pool.get().unwrap();
            conn.execute("UPDATE projects SET computer_id = 'codbex' WHERE computer_id = 'spread'", []).unwrap();
            conn.execute("INSERT INTO projects (id, name, computer_id, folder) VALUES ('new', 'New', (SELECT id FROM computers WHERE id = 'mac'), '~/new')", []).unwrap();
        }
        assert_eq!(test::call_service(&app, get("/api/todos/in-project")).await.status(), 404);
        assert_eq!(test::call_service(&app, get("/api/projects/allowed")).await.status(), 404);
        assert_eq!(test::call_service(&app, get("/api/projects/new")).await.status(), 200);
        assert_eq!(test::call_service(&app, codbex_get("/api/projects/new")).await.status(), 200);
        let new_todo = write(Method::POST, "/api/todos", serde_json::json!({"title": "New todo", "project_id": "new"}));
        assert_eq!(test::call_service(&app, new_todo).await.status(), 201);
        let admin = test::TestRequest::get().uri("/api/todos/hidden")
            .insert_header(("Authorization", "Bearer admin")).to_request();
        assert_eq!(test::call_service(&app, admin).await.status(), 200);
    }

    #[actix_web::test]
    async fn helper_token_is_bound_to_its_computer_for_status_and_jobs() {
        use actix_web::http::Method;
        const TOKEN: &str = "helper-token-00000000000000000000";
        let (_db, pool) = crate::test_support::pool("helper-token");
        {
            let conn = pool.get().unwrap();
            crate::test_support::seed_computers(&conn);
            conn.execute_batch(
                "INSERT INTO projects (id, name, computer_id, folder) VALUES
                     ('spread-project', 'Spread', (SELECT id FROM computers WHERE id = 'spread'), '~/spread'),
                     ('mac-project', 'Mac', (SELECT id FROM computers WHERE id = 'mac'), '~/mac');
                 INSERT INTO todos (id, title, project_id) VALUES
                     ('own', 'Own', 'spread-project'),
                     ('other', 'Other', 'mac-project');
                 INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id) VALUES
                     ('own-chat', 'own', 'spread', '/tmp', 'claude', 'own', 'own-session'),
                     ('other-chat', 'other', 'mac', '/tmp', 'claude', 'other', 'other-session');"
            ).unwrap();
            for (id, project, computer) in [("own", "spread-project", "spread"), ("other", "mac-project", "mac")] {
                let action = serde_json::json!({"kind": "conversation", "project_id": project, "computer_id": computer,
                    "tool": "claude", "prompt": "Run", "priority": "background", "limit": {"mode": "always"}});
                conn.execute("INSERT INTO jobs (id, name, trigger, action) VALUES (?1, ?1, '{\"kind\":\"manual\"}', ?2)",
                    rusqlite::params![id, action.to_string()]).unwrap();
                conn.execute("INSERT INTO job_runs (id, job_id, due_at, state) VALUES (?1, ?1, datetime('now'), 'due')",
                    [id]).unwrap();
            }
        }
        {
            let conn = pool.get().unwrap();
            conn.execute_batch(
                "INSERT INTO memories (id, project_id, computer_id, kind, text, text_key, source) VALUES
                     ('own-memory', 'spread-project', 'spread', 'gotcha', 'Own memory', 'own memory', 'manual'),
                     ('other-memory', 'mac-project', 'mac', 'gotcha', 'Private memory', 'private memory', 'manual');"
            ).unwrap();
        }
        let admin = ApiToken(Some("admin".into()));
        let tokens = serde_json::json!({(TOKEN): {"helper_computer_id": "spread"}});
        let scoped = ScopedTokens::parse(tokens.to_string().as_bytes(), &admin).unwrap();
        let app = test::init_service(App::new()
            .wrap(from_fn(require_token))
            .app_data(web::Data::new(admin))
            .app_data(web::Data::new(scoped))
            .app_data(web::Data::new(pool))
            .app_data(web::Data::new(crate::broadcast::Broadcaster::new()))
            .app_data(web::Data::new(crate::push::PushNotifier::disabled()))
            .configure(crate::api_routes)).await;
        let request = |method: Method, path: &str, body: serde_json::Value| test::TestRequest::default()
            .method(method).uri(path)
            .insert_header(("Authorization", format!("Bearer {TOKEN}")))
            .set_json(body).to_request();
        let list: serde_json::Value = test::call_and_read_body_json(&app,
            request(Method::GET, "/api/conversations", serde_json::Value::Null)).await;
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["id"], "own-chat");
        assert!(list[0].get("cwd").is_none());

        let memories: Vec<serde_json::Value> = test::call_and_read_body_json(&app,
            request(Method::GET, "/api/memories?ids=own-memory,other-memory", serde_json::Value::Null)).await;
        assert_eq!(memories.len(), 1);
        assert_eq!(memories[0]["id"], "own-memory");
        let uses: serde_json::Value = test::call_and_read_body_json(&app, request(
            Method::POST, "/api/memories/uses", serde_json::json!({
                "computer_id": "spread", "day": "2026-11-20", "project_ids": ["spread-project", "mac-project"],
                "uses": [{"id": "own-memory", "signal": "search"}, {"id": "other-memory", "signal": "search"}]
            }))).await;
        assert_eq!(uses["recorded"], 1);
        assert_eq!(uses["unknown"], serde_json::json!(["other-memory"]));
        for (method, path, body, status) in [
            (Method::POST, "/api/sessions/stats", serde_json::json!({"computer_id": "mac", "sessions": []}), 403),
            (Method::POST, "/api/sessions/stats", serde_json::json!({"computer_id": "spread", "sessions": [
                {"tool": "claude", "session_id": "other-session", "cwd": "/tmp"}
            ]}), 404),
            (Method::POST, "/api/sessions/stats", serde_json::json!({"computer_id": "spread", "sessions": [
                {"tool": "claude", "session_id": "own-session", "cwd": "/tmp"}
            ]}), 200),
            (Method::POST, "/api/memories/bulk", serde_json::json!({
                "computer_id": "spread", "tool": "claude", "session_id": "other-session", "cwd": "~/spread", "memories": []
            }), 404),
            (Method::POST, "/api/memories/bulk", serde_json::json!({
                "computer_id": "spread", "tool": "claude", "session_id": "own-session", "cwd": "~/spread", "memories": [
                    {"kind": "decision", "text": "Use the new format"}
                ]
            }), 201),
            (Method::POST, "/api/memories/import", serde_json::json!({
                "computer_id": "spread", "items": [{"source_key": "entry", "project_id": "mac-project", "kind": "decision", "text": "Denied"}]
            }), 404),
            (Method::POST, "/api/memories/import", serde_json::json!({
                "computer_id": "spread", "items": [{"source_key": "entry", "project_id": "spread-project", "kind": "decision", "text": "Allowed"}]
            }), 200),
            (Method::GET, "/api/todos", serde_json::Value::Null, 403),
            (Method::GET, "/api/runner/due?computer_id=mac", serde_json::Value::Null, 403),
            (Method::GET, "/api/runner/due?computer_id=spread", serde_json::Value::Null, 200),
            (Method::POST, "/api/conversations/status", serde_json::json!({"session_id": "other-session", "status": "busy"}), 404),
            (Method::POST, "/api/conversations/status", serde_json::json!({"session_id": "own-session", "status": "busy"}), 204),
            (Method::PUT, "/api/conversations/other-chat/session", serde_json::json!({"session_id": "replacement"}), 404),
            (Method::PUT, "/api/conversations/own-chat/session", serde_json::json!({"session_id": "replacement"}), 204),
            (Method::POST, "/api/runs/other/wait", serde_json::json!({"reason": "blocked"}), 404),
            (Method::POST, "/api/runs/other/claim", serde_json::json!({"computer_id": "mac"}), 403),
            (Method::POST, "/api/runs/other/claim", serde_json::json!({"computer_id": "spread"}), 404),
            (Method::POST, "/api/runs/own/claim", serde_json::json!({"computer_id": "spread"}), 200),
            (Method::POST, "/api/runs/other/finish", serde_json::json!({"state": "done"}), 404),
            (Method::POST, "/api/runs/own/finish", serde_json::json!({"state": "done"}), 200),
        ] {
            assert_eq!(test::call_service(&app, request(method, path, body)).await.status(), status, "{path}");
        }
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
