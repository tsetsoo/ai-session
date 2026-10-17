// The self-describing API in describe.rs is one large json! literal.
#![recursion_limit = "256"]

mod auth;
mod broadcast;
mod conversations;
mod daily;
mod db;
mod describe;
mod handlers;
mod memories;
mod models;
mod paths;
mod projects;
mod push;
mod sessions;
#[cfg(test)]
mod test_support;

use actix_web::{web, App, HttpServer, middleware};
use clap::Parser;

#[derive(Parser)]
#[command(name = "todo-server")]
struct Args {
    /// Database file path
    #[arg(long, default_value = "./data/todos.db")]
    db: String,

    /// Listen address
    #[arg(long, default_value = "0.0.0.0:8080")]
    addr: String,
}

/// Every `/api` route. Order matters where a literal segment shares a position with a
/// `{id}`: the literal route is registered first.
pub(crate) fn api_routes(cfg: &mut web::ServiceConfig) {
    cfg
        .route("/api/health", web::get().to(auth::health))
        .route("/api/ws", web::get().to(handlers::ws_handler))
        .route("/api/describe", web::get().to(describe::describe))
        .route("/api/sections", web::get().to(handlers::get_sections))
        .route("/api/todos", web::get().to(handlers::list_todos))
        .route("/api/todos", web::post().to(handlers::create_todo))
        // Before /api/todos/{id}, which would otherwise match this path (and answer 405).
        .route("/api/todos/from-conversation", web::post().to(conversations::todo_from_conversation))
        .route("/api/todos/{id}", web::get().to(handlers::get_todo))
        .route("/api/todos/{id}", web::patch().to(handlers::update_todo))
        .route("/api/todos/{id}", web::delete().to(handlers::delete_todo))
        .route("/api/todos/{id}/toggle", web::post().to(handlers::toggle_todo))
        .route("/api/todos/{id}/daily", web::post().to(daily::set_todo_daily))
        .route("/api/daily/status", web::get().to(daily::daily_status))
        .route("/api/daily", web::get().to(daily::list_daily))
        .route("/api/daily/create", web::post().to(daily::create_daily))
        // AI conversations
        .route("/api/computers", web::get().to(conversations::list_computers))
        .route("/api/computers", web::post().to(conversations::create_computer))
        .route("/api/computers/{id}", web::patch().to(conversations::update_computer))
        .route("/api/computers/{id}", web::delete().to(conversations::delete_computer))
        .route("/api/sections/computers", web::get().to(conversations::list_section_computers))
        .route("/api/sections/{code}/computer", web::put().to(conversations::set_section_computer))
        .route("/api/sections/{code}/computer", web::delete().to(conversations::clear_section_computer))
        .route("/api/conversations", web::get().to(conversations::list_conversations))
        .route("/api/conversations/status", web::post().to(conversations::post_conversation_status))
        .route("/api/todos/{id}/conversation", web::get().to(conversations::get_conversation))
        .route("/api/todos/{id}/conversation", web::post().to(conversations::open_conversation))
        .route("/api/todos/{id}/conversation", web::delete().to(conversations::delete_conversation))
        .route("/api/todos/{id}/conversation/close", web::post().to(conversations::close_conversation))
        .route("/api/todos/{id}/conversation/link", web::post().to(conversations::link_conversation))
        // Push notifications
        .route("/api/push/devices", web::put().to(push::handlers::put_device))
        .route("/api/push/devices", web::get().to(push::handlers::list_devices))
        .route("/api/push/devices/unregister", web::post().to(push::handlers::delete_device))
        .route("/api/push/settings", web::get().to(push::handlers::get_settings))
        .route("/api/push/settings", web::put().to(push::handlers::put_settings))
        .route("/api/push/presence", web::post().to(push::handlers::post_presence))
        .route("/api/push/status", web::get().to(push::handlers::get_status))
        .route("/api/push/test", web::post().to(push::handlers::post_test))
        .route("/api/todos/{id}/push-mute", web::put().to(push::handlers::mute_todo))
        .route("/api/todos/{id}/push-mute", web::delete().to(push::handlers::unmute_todo))
        // Projects
        .route("/api/projects", web::get().to(projects::list_projects))
        .route("/api/projects", web::post().to(projects::create_project))
        // Before /api/projects/{id}, which would otherwise match this path.
        .route("/api/projects/suggestions", web::get().to(projects::project_suggestions))
        .route("/api/projects/{id}", web::get().to(projects::get_project))
        .route("/api/projects/{id}", web::patch().to(projects::update_project))
        .route("/api/projects/{id}", web::delete().to(projects::delete_project))
        // Memories
        .route("/api/memories", web::get().to(memories::list_memories))
        .route("/api/memories", web::post().to(memories::create_memory))
        // Before /api/memories/{id}.
        .route("/api/memories/bulk", web::post().to(memories::bulk_memories))
        .route("/api/memories/{id}", web::patch().to(memories::update_memory))
        .route("/api/memories/{id}", web::delete().to(memories::delete_memory))
        // Sessions and stats
        .route("/api/sessions", web::get().to(sessions::list_sessions))
        .route("/api/sessions/stats", web::post().to(sessions::upload_stats))
        .route("/api/sessions/{tool}/{session_id}/project", web::put().to(sessions::set_session_project))
        .route("/api/stats/weekly", web::get().to(sessions::weekly_stats));
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let args = Args::parse();

    println!("Initializing database at: {}", args.db);
    let pool = db::init_pool(&args.db);
    let broadcaster = broadcast::Broadcaster::new();
    let api_token = auth::ApiToken::from_env();
    println!(
        "API token auth: {}",
        if api_token.0.is_some() { "enabled" } else { "disabled (set TODO_API_TOKEN to enable)" }
    );

    // Push notifications. The only outbound calls this server makes: HTTPS to Apple's APNs.
    let presence = push::Presence::default();
    let apns = match push::apns::ApnsConfig::from_env() {
        Ok(Some(config)) => match push::apns::JwtSigner::new(&config) {
            Ok(signer) => {
                println!("Push notifications: enabled (APNs key {})", config.key_id);
                Some(push::apns::ApnsSender::new(std::sync::Arc::new(push::apns::HttpTransport::apple()), signer))
            }
            Err(e) => {
                println!("Push notifications: disabled ({e})");
                None
            }
        },
        Ok(None) => {
            println!("Push notifications: not configured (set APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID)");
            None
        }
        Err(e) => {
            println!("Push notifications: disabled ({e})");
            None
        }
    };
    let notifier = push::PushNotifier::start(pool.clone(), apns, presence.clone());

    println!("Starting server at http://{}", args.addr);

    let broadcaster_clone = broadcaster.clone();

    HttpServer::new(move || {
        // Like the default format, but with the path (%U) instead of the request
        // line (%r), so `/api/ws?token=…` never reaches the logs.
        let logger = middleware::Logger::new(r#"%a "%{method}xi %U" %s %b "%{User-Agent}i" %T"#)
            .custom_request_replace("method", |req| req.method().to_string());

        // API only (the web UI was retired; clients are the native apps and host scripts).
        // No CORS, so other sites can't call the API from the browser.
        App::new()
            .wrap(middleware::from_fn(auth::require_token))
            .wrap(logger)
            .app_data(web::Data::new(pool.clone()))
            .app_data(web::Data::new(broadcaster_clone.clone()))
            .app_data(web::Data::new(api_token.clone()))
            .app_data(web::Data::new(notifier.clone()))
            .app_data(web::Data::new(presence.clone()))
            .configure(api_routes)
    })
    .bind(&args.addr)?
    .run()
    .await
}
