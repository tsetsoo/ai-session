use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::params;
use std::path::Path;

pub type DbPool = Pool<SqliteConnectionManager>;

pub fn init_pool(db_path: &str) -> DbPool {
    // Ensure parent directory exists
    if let Some(parent) = Path::new(db_path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).expect("Failed to create database directory");
        }
    }

    // foreign_keys is per connection, so every pooled connection must turn it on.
    let manager = SqliteConnectionManager::file(db_path)
        .with_init(|c| c.execute_batch("PRAGMA foreign_keys=ON;"));
    let pool = Pool::builder()
        .max_size(8)
        .build(manager)
        .expect("Failed to create connection pool");

    // Enable WAL mode and create schema
    let conn = pool.get().expect("Failed to get connection from pool");

    conn.execute_batch("PRAGMA journal_mode=WAL;")
        .expect("Failed to enable WAL mode");

    conn.execute(
        "CREATE TABLE IF NOT EXISTS todos (
            id         TEXT PRIMARY KEY,
            section    TEXT NOT NULL CHECK(section IN ('Sp','I','Si','P')),
            title      TEXT NOT NULL,
            completed  INTEGER NOT NULL DEFAULT 0,
            importance TEXT NOT NULL DEFAULT 'medium' CHECK(importance IN ('low','medium','high','critical')),
            due_date   TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            completed_at TEXT
        )",
        params![],
    )
    .expect("Failed to create todos table");

    // Migrate: add columns if they don't exist (for existing databases)
    let cols: Vec<String> = conn
        .prepare("PRAGMA table_info(todos)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    if !cols.iter().any(|c| c == "importance") {
        conn.execute("ALTER TABLE todos ADD COLUMN importance TEXT NOT NULL DEFAULT 'medium'", [])
            .expect("Failed to add importance column");
    }
    if !cols.iter().any(|c| c == "due_date") {
        conn.execute("ALTER TABLE todos ADD COLUMN due_date TEXT", [])
            .expect("Failed to add due_date column");
    }
    if !cols.iter().any(|c| c == "completed_at") {
        conn.execute("ALTER TABLE todos ADD COLUMN completed_at TEXT", [])
            .expect("Failed to add completed_at column");
        conn.execute("UPDATE todos SET completed_at = updated_at WHERE completed = 1 AND completed_at IS NULL", [])
            .expect("Failed to backfill completed_at");
    }
    if !cols.iter().any(|c| c == "daily_date") {
        conn.execute("ALTER TABLE todos ADD COLUMN daily_date TEXT", [])
            .expect("Failed to add daily_date column");
    }
    if !cols.iter().any(|c| c == "carried_from") {
        conn.execute("ALTER TABLE todos ADD COLUMN carried_from TEXT", [])
            .expect("Failed to add carried_from column");
    }

    conn.execute(
        "CREATE TABLE IF NOT EXISTS daily_days (
            date TEXT PRIMARY KEY
        )",
        params![],
    )
    .expect("Failed to create daily_days table");

    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS computers (
            id         TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            hostname   TEXT NOT NULL,
            port       INTEGER NOT NULL DEFAULT 22,
            username   TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS section_computers (
            section     TEXT PRIMARY KEY CHECK(section IN ('Sp','I','Si','P')),
            computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd         TEXT NOT NULL,
            tool        TEXT NOT NULL DEFAULT 'claude' CHECK(tool IN ('claude'))
        );
        CREATE TABLE IF NOT EXISTS conversations (
            todo_id           TEXT PRIMARY KEY REFERENCES todos(id) ON DELETE CASCADE,
            computer_id       TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd               TEXT NOT NULL,
            tool              TEXT NOT NULL,
            tmux_name         TEXT NOT NULL UNIQUE,
            claude_session_id TEXT NOT NULL UNIQUE,
            status            TEXT NOT NULL DEFAULT 'unknown'
                              CHECK(status IN ('busy','waiting','idle','unknown','closed')),
            status_message    TEXT,
            status_updated_at TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now'))
        );",
    )
    .expect("Failed to create conversation tables");

    pool
}
