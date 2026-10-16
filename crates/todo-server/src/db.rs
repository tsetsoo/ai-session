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

    migrate(&conn, db_path).expect("Failed to migrate the database schema");

    conn.execute_batch(&format!(
        "{};\n{};\n{};",
        section_computers_ddl("section_computers"),
        conversations_ddl("conversations"),
        // Hooks look conversations up by (tool, session_id); UNIQUE(tool, session_id)
        // already covers that, this also serves lookups by id alone.
        "CREATE INDEX IF NOT EXISTS conversations_session_id ON conversations(session_id)"
    ))
    .expect("Failed to create conversation tables");

    let version = schema_version(&conn).expect("Failed to read the schema version");
    if version <= SCHEMA_VERSION {
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)
            .expect("Failed to record the schema version");
    } else {
        println!("Database schema v{version} is newer than this binary (v{SCHEMA_VERSION}); leaving it as is");
    }

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

/// Schema version recorded in `PRAGMA user_version` after startup.
///
/// - v0: no conversation tables (fresh database, or one from before todo-app #1)
/// - v1: todo-app #1: Claude-only `tool` CHECK, conversations keyed by `claude_session_id`
/// - v2: `tool` in claude/codex/cursor, `session_id`, UNIQUE(tool, session_id)
///
/// Add a new version by bumping this and adding a numbered step to `migrate`.
pub const SCHEMA_VERSION: i64 = 2;

/// The database's schema version. Databases written before versioning (user_version 0)
/// are classified once by their table definitions; after startup the number is stored.
fn schema_version(conn: &Connection) -> rusqlite::Result<i64> {
    let stored: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if stored != 0 {
        return Ok(stored);
    }
    let sections = table_sql(conn, "section_computers")?;
    let conversations = table_sql(conn, "conversations")?;
    if sections.is_none() && conversations.is_none() {
        return Ok(0);
    }
    let v1 = sections.as_deref().is_some_and(|sql| !sql.contains("'codex'"))
        || conversations.as_deref().is_some_and(|sql| sql.contains("claude_session_id"));
    Ok(if v1 { 1 } else { 2 })
}

/// Bring an existing database up to `SCHEMA_VERSION`, one numbered step at a time.
/// Each step that rewrites tables first copies the database next to itself, because the
/// Pi's updater can roll back to an older binary that wouldn't understand the new schema.
/// v0 needs no step: `init_pool` creates the current tables directly.
fn migrate(conn: &Connection, db_path: &str) -> rusqlite::Result<()> {
    let version = schema_version(conn)?;
    if version == 1 {
        backup_before_migration(conn, db_path, 2)?;
        migrate_v1_to_v2(conn)?;
    }
    Ok(())
}

/// Copy the database to `<db>.pre-v<N>-<unix seconds>` with `VACUUM INTO`.
fn backup_before_migration(conn: &Connection, db_path: &str, to_version: i64) -> rusqlite::Result<Option<String>> {
    if db_path.is_empty() || db_path == ":memory:" {
        return Ok(None);
    }
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let backup = format!("{db_path}.pre-v{to_version}-{seconds}");
    conn.execute("VACUUM INTO ?1", params![backup])?;
    println!("Backed up the database to {backup} before migrating to schema v{to_version}");
    Ok(Some(backup))
}

/// v1 → v2. SQLite can't alter a CHECK constraint or rename a column's meaning in place,
/// so rebuild both conversation tables, keeping every row.
fn migrate_v1_to_v2(conn: &Connection) -> rusqlite::Result<()> {
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

/// A database file for one test, removed (with its WAL/SHM files and any migration
/// backups) when dropped. Declare it before the pool so the pool closes first.
#[cfg(test)]
pub(crate) struct TestDb {
    pub path: String,
}

#[cfg(test)]
impl TestDb {
    pub fn new(name: &str) -> Self {
        let dir = std::env::temp_dir();
        Self { path: format!("{}/todo-{name}-test-{}.db", dir.display(), uuid::Uuid::new_v4()) }
    }

    pub fn pool(&self) -> DbPool {
        init_pool(&self.path)
    }

    /// Migration backups written next to this database.
    pub fn backups(&self) -> Vec<std::path::PathBuf> {
        let path = Path::new(&self.path);
        let prefix = format!("{}.pre-v", path.file_name().unwrap().to_string_lossy());
        std::fs::read_dir(path.parent().unwrap())
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|e| e.path())
                    .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with(&prefix)))
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(test)]
impl Drop for TestDb {
    fn drop(&mut self) {
        for backup in self.backups() {
            let _ = std::fs::remove_file(backup);
        }
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", self.path));
        }
    }
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

    fn v1_db() -> TestDb {
        let db = TestDb::new("migrate");
        Connection::open(&db.path).unwrap().execute_batch(V1_SCHEMA).unwrap();
        db
    }

    fn user_version(conn: &Connection) -> i64 {
        conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn migrates_v1_conversation_tables_keeping_rows() {
        let db = v1_db();
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1, "a backup is taken before rewriting the tables");
        // Running it again on the migrated file must be a no-op (and take no second backup).
        drop(pool);
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1);
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);

        // The backup is the untouched v1 database.
        let backup = Connection::open(&db.backups()[0]).unwrap();
        assert!(table_sql(&backup, "conversations").unwrap().unwrap().contains("claude_session_id"));

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
    fn fresh_database_gets_the_current_schema_without_a_backup() {
        let db = TestDb::new("migrate");
        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        assert!(db.backups().is_empty());
        let sql = table_sql(&conn, "conversations").unwrap().unwrap();
        assert!(sql.contains("session_id") && !sql.contains("claude_session_id"), "{sql}");
        assert!(table_sql(&conn, "section_computers").unwrap().unwrap().contains("'codex'"));
        let index: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'conversations_session_id'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(index, 1);
    }

    #[test]
    fn unversioned_v2_database_is_recognised_without_migrating() {
        // A database written by an earlier build of this branch: v2 tables, user_version 0.
        let db = TestDb::new("migrate");
        drop(db.pool());
        Connection::open(&db.path).unwrap().pragma_update(None, "user_version", 0).unwrap();
        let pool = db.pool();
        assert!(db.backups().is_empty());
        assert_eq!(user_version(&pool.get().unwrap()), SCHEMA_VERSION);
    }

    #[test]
    fn schema_version_classifies_unversioned_databases() {
        let conn = Connection::open_in_memory().unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 0);
        conn.execute_batch(V1_SCHEMA).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 1);
        conn.pragma_update(None, "user_version", 5).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 5, "a stored version wins over sniffing");
    }
}
