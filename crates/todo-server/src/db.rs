use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::{params, Connection, OptionalExtension};
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
        );",
    )
    .expect("Failed to create computers table");

    migrate_conversation_tables(&conn).expect("Failed to migrate conversation tables");

    conn.execute_batch(&format!(
        "{};\n{};",
        section_computers_ddl("section_computers"),
        conversations_ddl("conversations")
    ))
    .expect("Failed to create conversation tables");

    pool
}

/// Tools whose conversations can be stored. New conversations started from a todo are
/// Claude-only; the others can only be linked (see conversations.rs).
pub const TOOLS_SQL: &str = "('claude','codex','cursor')";

fn section_computers_ddl(table: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {table} (
            section     TEXT PRIMARY KEY CHECK(section IN ('Sp','I','Si','P')),
            computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd         TEXT NOT NULL,
            tool        TEXT NOT NULL DEFAULT 'claude' CHECK(tool IN {TOOLS_SQL})
        )"
    )
}

fn conversations_ddl(table: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {table} (
            todo_id           TEXT PRIMARY KEY REFERENCES todos(id) ON DELETE CASCADE,
            computer_id       TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd               TEXT NOT NULL,
            tool              TEXT NOT NULL CHECK(tool IN {TOOLS_SQL}),
            tmux_name         TEXT NOT NULL UNIQUE,
            session_id        TEXT NOT NULL,
            status            TEXT NOT NULL DEFAULT 'unknown'
                              CHECK(status IN ('busy','waiting','idle','unknown','closed')),
            status_message    TEXT,
            status_updated_at TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(tool, session_id)
        )"
    )
}

fn table_sql(conn: &Connection, table: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
        params![table],
        |r| r.get(0),
    )
    .optional()
}

/// The first conversation schema (todo-app #1) only allowed `tool = 'claude'` and keyed
/// conversations by `claude_session_id`. SQLite can't alter a CHECK constraint or rename
/// a column's meaning in place, so rebuild those two tables, keeping every row.
/// Idempotent: does nothing on a fresh database or one already migrated.
fn migrate_conversation_tables(conn: &Connection) -> rusqlite::Result<()> {
    let sections_old = table_sql(conn, "section_computers")?.is_some_and(|sql| !sql.contains("'codex'"));
    let conversations_old = table_sql(conn, "conversations")?.is_some_and(|sql| sql.contains("claude_session_id"));
    if !sections_old && !conversations_old {
        return Ok(());
    }

    // Dropping a table that rows reference would trip foreign keys mid-rebuild. The pragma
    // is ignored inside a transaction, so switch it off first and verify before committing.
    conn.execute_batch("PRAGMA foreign_keys=OFF;")?;
    let result = (|| {
        let tx = conn.unchecked_transaction()?;
        if sections_old {
            tx.execute_batch(&format!(
                "{};
                 INSERT INTO section_computers_new (section, computer_id, cwd, tool)
                     SELECT section, computer_id, cwd, tool FROM section_computers;
                 DROP TABLE section_computers;
                 ALTER TABLE section_computers_new RENAME TO section_computers;",
                section_computers_ddl("section_computers_new")
            ))?;
        }
        if conversations_old {
            tx.execute_batch(&format!(
                "{};
                 INSERT INTO conversations_new (todo_id, computer_id, cwd, tool, tmux_name, session_id,
                                                status, status_message, status_updated_at, created_at)
                     SELECT todo_id, computer_id, cwd, tool, tmux_name, claude_session_id,
                            status, status_message, status_updated_at, created_at FROM conversations;
                 DROP TABLE conversations;
                 ALTER TABLE conversations_new RENAME TO conversations;",
                conversations_ddl("conversations_new")
            ))?;
        }
        let violations: i64 = tx.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r.get(0))?;
        if violations > 0 {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
                Some(format!("{violations} foreign key violations after migration")),
            ));
        }
        tx.commit()
    })();
    conn.execute_batch("PRAGMA foreign_keys=ON;")?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The conversation schema as shipped in todo-app #1 (what the Pi runs today).
    const V1_SCHEMA: &str = "
        CREATE TABLE todos (
            id TEXT PRIMARY KEY,
            section TEXT NOT NULL CHECK(section IN ('Sp','I','Si','P')),
            title TEXT NOT NULL,
            completed INTEGER NOT NULL DEFAULT 0,
            importance TEXT NOT NULL DEFAULT 'medium' CHECK(importance IN ('low','medium','high','critical')),
            due_date TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            completed_at TEXT,
            daily_date TEXT,
            carried_from TEXT
        );
        CREATE TABLE daily_days (date TEXT PRIMARY KEY);
        CREATE TABLE computers (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, hostname TEXT NOT NULL,
            port INTEGER NOT NULL DEFAULT 22, username TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE section_computers (
            section     TEXT PRIMARY KEY CHECK(section IN ('Sp','I','Si','P')),
            computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd         TEXT NOT NULL,
            tool        TEXT NOT NULL DEFAULT 'claude' CHECK(tool IN ('claude'))
        );
        CREATE TABLE conversations (
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
        );
        INSERT INTO computers (id, name, hostname, username) VALUES
            ('mac', 'this Mac', '100.103.53.126', 'me'),
            ('codbex', 'codbex', '100.107.204.56', 'tsetso'),
            ('spread', 'spread', '100.94.164.63', 'me');
        INSERT INTO section_computers (section, computer_id, cwd) VALUES
            ('Sp', 'spread', '~/Spread/Repository'), ('I', 'codbex', '~/Repositories'),
            ('Si', 'mac', '~/programming'), ('P', 'mac', '~/programming');
        INSERT INTO todos (id, section, title) VALUES ('t1', 'Si', 'linked'), ('t2', 'P', 'plain');
        INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, claude_session_id, status, status_message)
            VALUES ('t1', 'mac', '~/programming', 'claude', 'ai/claude/todo-t1', 'sess-1', 'waiting', 'needs ok');
    ";

    fn v1_db() -> String {
        let path = format!("/tmp/todo-migrate-test-{}.db", uuid::Uuid::new_v4());
        Connection::open(&path).unwrap().execute_batch(V1_SCHEMA).unwrap();
        path
    }

    #[test]
    fn migrates_v1_conversation_tables_keeping_rows() {
        let path = v1_db();
        let pool = init_pool(&path);
        // Running it again on the migrated file must be a no-op.
        drop(pool);
        let pool = init_pool(&path);
        let conn = pool.get().unwrap();

        let mappings: i64 = conn.query_row("SELECT COUNT(*) FROM section_computers", [], |r| r.get(0)).unwrap();
        assert_eq!(mappings, 4);
        let (session, status, message, tmux): (String, String, String, String) = conn
            .query_row(
                "SELECT session_id, status, status_message, tmux_name FROM conversations WHERE todo_id = 't1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!((session.as_str(), status.as_str(), message.as_str(), tmux.as_str()),
                   ("sess-1", "waiting", "needs ok", "ai/claude/todo-t1"));

        // The widened CHECKs accept codex; unknown tools are still rejected.
        conn.execute("UPDATE section_computers SET tool = 'codex' WHERE section = 'I'", []).unwrap();
        assert!(conn.execute("UPDATE section_computers SET tool = 'vim' WHERE section = 'I'", []).is_err());
        conn.execute(
            "INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id)
             VALUES ('t2', 'codbex', '~/Repositories', 'codex', 'ai/codex/todo-t2', 'sess-1')",
            [],
        )
        .unwrap();

        // Foreign keys still hold on the rebuilt tables.
        assert!(conn.execute("DELETE FROM computers WHERE id = 'mac'", []).is_err());
        conn.execute("DELETE FROM todos WHERE id = 't1'", []).unwrap();
        let left: i64 = conn.query_row("SELECT COUNT(*) FROM conversations", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 1, "deleting a todo still cascades to its conversation");
        let fk_on: i64 = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
        assert_eq!(fk_on, 1);
    }

    #[test]
    fn fresh_database_gets_the_new_schema() {
        let path = format!("/tmp/todo-migrate-test-{}.db", uuid::Uuid::new_v4());
        let pool = init_pool(&path);
        let conn = pool.get().unwrap();
        let sql = table_sql(&conn, "conversations").unwrap().unwrap();
        assert!(sql.contains("session_id") && !sql.contains("claude_session_id"), "{sql}");
        assert!(table_sql(&conn, "section_computers").unwrap().unwrap().contains("'codex'"));
    }
}
