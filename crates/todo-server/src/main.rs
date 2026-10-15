// The self-describing API in describe.rs is one large json! literal.
#![recursion_limit = "256"]

mod auth;
mod broadcast;
mod conversations;
mod daily;
mod db;
mod describe;
mod handlers;
mod models;

use actix_cors::Cors;
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

    // Determine frontend dist path
    let frontend_dir = std::env::var("FRONTEND_DIR")
        .unwrap_or_else(|_| "./frontend-dist".to_string());

    println!("Serving frontend from: {frontend_dir}");
    println!("Starting server at http://{}", args.addr);

    let frontend_dir_clone = frontend_dir.clone();
    let broadcaster_clone = broadcaster.clone();

    HttpServer::new(move || {
        let cors = Cors::default()
            .allow_any_origin()
            .allow_any_method()
            .allow_any_header()
            .max_age(3600);

        let mut app = App::new()
            .wrap(middleware::from_fn(auth::require_token))
            .wrap(cors)
            .wrap(middleware::Logger::default())
            .app_data(web::Data::new(pool.clone()))
            .app_data(web::Data::new(broadcaster_clone.clone()))
            .app_data(web::Data::new(api_token.clone()))
            // API routes
            .route("/api/health", web::get().to(auth::health))
            .route("/api/ws", web::get().to(handlers::ws_handler))
            .route("/api/describe", web::get().to(describe::describe))
            .route("/api/sections", web::get().to(handlers::get_sections))
            .route("/api/todos", web::get().to(handlers::list_todos))
            .route("/api/todos", web::post().to(handlers::create_todo))
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
            .route("/api/todos/{id}/conversation/close", web::post().to(conversations::close_conversation));

        // Serve frontend static files if the directory exists
        let fe_path = std::path::Path::new(&frontend_dir_clone);
        if fe_path.exists() {
            app = app.service(
                actix_files::Files::new("/", &frontend_dir_clone)
                    .index_file("index.html")
                    .default_handler(
                        actix_files::NamedFile::open(fe_path.join("index.html"))
                            .expect("frontend-dist/index.html not found"),
                    ),
            );
        }

        app
    })
    .bind(&args.addr)?
    .run()
    .await
}
