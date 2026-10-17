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

    // A fresh database gets the v3 objects here; existing ones got them in `migrate`.
    create_v3_objects(&conn).expect("Failed to create project, session and memory tables");
    create_v4_objects(&conn).expect("Failed to create push notification tables");

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

pub(crate) fn projects_ddl() -> &'static str {
    "CREATE TABLE IF NOT EXISTS projects (
        id             TEXT PRIMARY KEY,
        name           TEXT NOT NULL,
        computer_id    TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
        folder         TEXT NOT NULL,
        repo_url       TEXT,
        digest_enabled INTEGER NOT NULL DEFAULT 1,
        created_at     TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(computer_id, folder)
    )"
}

/// A Claude/Codex conversation known from a computer's transcripts (linked to a todo or not).
pub(crate) fn sessions_ddl() -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS sessions (
            tool                  TEXT NOT NULL CHECK(tool IN {TOOLS_SQL}),
            session_id            TEXT NOT NULL,
            computer_id           TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
            cwd                   TEXT NOT NULL,
            title                 TEXT,
            repo_root             TEXT,
            repo_url              TEXT,
            project_id            TEXT REFERENCES projects(id) ON DELETE SET NULL,
            project_override      INTEGER NOT NULL DEFAULT 0,
            prompts               INTEGER NOT NULL DEFAULT 0,
            assistant_turns       INTEGER NOT NULL DEFAULT 0,
            input_tokens          INTEGER,
            output_tokens         INTEGER,
            cache_read_tokens     INTEGER,
            cache_creation_tokens INTEGER,
            active_seconds        INTEGER NOT NULL DEFAULT 0,
            first_activity        TEXT,
            last_activity         TEXT,
            files_touched         TEXT NOT NULL DEFAULT '[]',
            models                TEXT NOT NULL DEFAULT '[]',
            stats_updated_at      TEXT,
            created_at            TEXT NOT NULL DEFAULT (datetime('now')),
            PRIMARY KEY (tool, session_id)
        )"
    )
}

pub(crate) fn session_days_ddl() -> &'static str {
    "CREATE TABLE IF NOT EXISTS session_days (
        tool                  TEXT NOT NULL,
        session_id            TEXT NOT NULL,
        day                   TEXT NOT NULL,
        prompts               INTEGER NOT NULL DEFAULT 0,
        assistant_turns       INTEGER NOT NULL DEFAULT 0,
        input_tokens          INTEGER,
        output_tokens         INTEGER,
        cache_read_tokens     INTEGER,
        cache_creation_tokens INTEGER,
        active_seconds        INTEGER NOT NULL DEFAULT 0,
        files_touched         INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (tool, session_id, day),
        FOREIGN KEY (tool, session_id) REFERENCES sessions(tool, session_id) ON DELETE CASCADE
    )"
}

pub(crate) fn memories_ddl() -> &'static str {
    "CREATE TABLE IF NOT EXISTS memories (
        id          TEXT PRIMARY KEY,
        project_id  TEXT REFERENCES projects(id) ON DELETE SET NULL,
        todo_id     TEXT REFERENCES todos(id) ON DELETE SET NULL,
        computer_id TEXT REFERENCES computers(id) ON DELETE SET NULL,
        tool        TEXT,
        session_id  TEXT,
        kind        TEXT NOT NULL CHECK(kind IN ('decision','gotcha','open_thread','done','files_changed')),
        text        TEXT NOT NULL,
        text_key    TEXT NOT NULL,
        files       TEXT NOT NULL DEFAULT '[]',
        confidence  REAL,
        source      TEXT NOT NULL DEFAULT 'extracted' CHECK(source IN ('extracted','manual')),
        pinned      INTEGER NOT NULL DEFAULT 0,
        archived    INTEGER NOT NULL DEFAULT 0,
        created_at  TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
    )"
}

const V3_INDEXES: &str = "
    CREATE INDEX IF NOT EXISTS todos_project ON todos(project_id);
    CREATE INDEX IF NOT EXISTS sessions_project ON sessions(project_id);
    CREATE INDEX IF NOT EXISTS sessions_computer ON sessions(computer_id);
    CREATE INDEX IF NOT EXISTS session_days_day ON session_days(day);
    CREATE INDEX IF NOT EXISTS memories_project ON memories(project_id, archived, created_at);
    CREATE INDEX IF NOT EXISTS memories_session ON memories(tool, session_id);
    CREATE INDEX IF NOT EXISTS memories_todo ON memories(todo_id);
    CREATE UNIQUE INDEX IF NOT EXISTS memories_dedup ON memories(tool, session_id, kind, text_key)
        WHERE session_id IS NOT NULL;";

/// Everything v3 adds: `todos.project_id`, four tables and their indexes. Only adds,
/// so it is safe to run on every start.
fn create_v3_objects(conn: &Connection) -> rusqlite::Result<()> {
    let has_project_id = conn
        .prepare("SELECT 1 FROM pragma_table_info('todos') WHERE name = 'project_id'")?
        .exists([])?;
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(&format!(
        "{};\n{};\n{};\n{};",
        projects_ddl(),
        sessions_ddl(),
        session_days_ddl(),
        memories_ddl()
    ))?;
    if !has_project_id {
        tx.execute_batch("ALTER TABLE todos ADD COLUMN project_id TEXT REFERENCES projects(id) ON DELETE SET NULL;")?;
    }
    tx.execute_batch(V3_INDEXES)?;
    tx.commit()
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
/// - v3: `projects`, `sessions`, `session_days`, `memories`, `todos.project_id` (additive)
/// - v4: `push_devices`, `push_settings`, `push_muted_sections`, `push_muted_todos` (additive)
///
/// Add a new version by bumping this and adding a numbered step to `migrate`.
pub const SCHEMA_VERSION: i64 = 4;

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
    if table_sql(conn, "push_devices")?.is_some() {
        return Ok(4);
    }
    if table_sql(conn, "projects")?.is_some() {
        return Ok(3);
    }
    let v1 = sections.as_deref().is_some_and(|sql| !sql.contains("'codex'"))
        || conversations.as_deref().is_some_and(|sql| sql.contains("claude_session_id"));
    Ok(if v1 { 1 } else { 2 })
}

/// Bring an existing database up to `SCHEMA_VERSION`, one numbered step at a time.
/// Each step that rewrites tables first copies the database next to itself, because the
/// Pi's updater can roll back to an older binary that wouldn't understand the new schema.
/// v0 needs no step: `init_pool` creates the current tables directly.
///
/// One backup per start is enough: it holds the database exactly as the older binary
/// left it, so a v1 database that goes through v2 to v3 is copied once, before v1 → v2.
fn migrate(conn: &Connection, db_path: &str) -> rusqlite::Result<()> {
    let mut version = schema_version(conn)?;
    let mut backed_up = false;
    if version == 1 {
        backup_before_migration(conn, db_path, 2)?;
        backed_up = true;
        migrate_v1_to_v2(conn)?;
        version = 2;
    }
    if version == 2 {
        if !backed_up {
            backup_before_migration(conn, db_path, 3)?;
            backed_up = true;
        }
        migrate_v2_to_v3(conn)?;
        version = 3;
    }
    if version == 3 {
        if !backed_up {
            backup_before_migration(conn, db_path, 4)?;
        }
        create_v4_objects(conn)?;
    }
    Ok(())
}

/// Everything v4 adds: the push notification tables (see push/store.rs). Only creates,
/// so it is safe to run on every start and an older binary after a rollback ignores them.
fn create_v4_objects(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS push_devices (
            token        TEXT PRIMARY KEY,
            platform     TEXT NOT NULL CHECK(platform IN ('ios','macos')),
            environment  TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
            bundle_id    TEXT NOT NULL,
            app_version  TEXT NOT NULL,
            device_name  TEXT,
            created_at   TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at   TEXT NOT NULL DEFAULT (datetime('now')),
            last_sent_at TEXT,
            last_error   TEXT
        );
        CREATE TABLE IF NOT EXISTS push_settings (
            id                 INTEGER PRIMARY KEY CHECK(id = 1),
            notify_waiting     INTEGER NOT NULL DEFAULT 1,
            done_after_minutes INTEGER,
            grace_seconds      INTEGER NOT NULL DEFAULT 20,
            quiet_start        TEXT,
            quiet_end          TEXT,
            quiet_tz           TEXT
        );
        CREATE TABLE IF NOT EXISTS push_muted_sections (
            section TEXT PRIMARY KEY CHECK(section IN ('Sp','I','Si','P'))
        );
        CREATE TABLE IF NOT EXISTS push_muted_todos (
            todo_id    TEXT PRIMARY KEY REFERENCES todos(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );",
    )
}

/// v2 → v3. Nothing is rewritten: new tables, a new nullable column and indexes.
fn migrate_v2_to_v3(conn: &Connection) -> rusqlite::Result<()> {
    create_v3_objects(conn)
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

    /// Schema v2 as the Pi runs it before this change (todo-app #2), with rows.
    const V2_SCHEMA: &str = "
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
            tool        TEXT NOT NULL DEFAULT 'claude' CHECK(tool IN ('claude','codex','cursor'))
        );
        CREATE TABLE conversations (
            todo_id           TEXT PRIMARY KEY REFERENCES todos(id) ON DELETE CASCADE,
            computer_id       TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd               TEXT NOT NULL,
            tool              TEXT NOT NULL CHECK(tool IN ('claude','codex','cursor')),
            tmux_name         TEXT NOT NULL UNIQUE,
            session_id        TEXT NOT NULL,
            status            TEXT NOT NULL DEFAULT 'unknown'
                              CHECK(status IN ('busy','waiting','idle','unknown','closed')),
            status_message    TEXT,
            status_updated_at TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now')),
            UNIQUE(tool, session_id)
        );
        CREATE INDEX conversations_session_id ON conversations(session_id);
        INSERT INTO computers (id, name, hostname, username) VALUES
            ('mac', 'this Mac', '100.103.53.126', 'me'),
            ('codbex', 'codbex', '100.107.204.56', 'tsetso');
        INSERT INTO section_computers (section, computer_id, cwd, tool) VALUES
            ('I', 'codbex', '~/Repositories', 'codex'), ('Si', 'mac', '~/programming', 'claude');
        INSERT INTO todos (id, section, title, due_date) VALUES
            ('t1', 'Si', 'linked', '2026-10-20'), ('t2', 'I', 'plain', NULL), ('t3', 'P', 'third', NULL);
        INSERT INTO daily_days (date) VALUES ('2026-10-16');
        INSERT INTO conversations (todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
            VALUES ('t1', 'mac', '~/programming', 'claude', 'ai/claude/todo-t1', 'sess-1', 'idle'),
                   ('t2', 'codbex', '~/Repositories', 'codex', 'ai/codex/todo-t2', 'sess-2', 'busy');
        PRAGMA user_version = 2;
    ";

    const V3_TABLES: [&str; 4] = ["projects", "sessions", "session_days", "memories"];
    const V4_TABLES: [&str; 4] = ["push_devices", "push_settings", "push_muted_sections", "push_muted_todos"];

    /// A v3 database as the projects/memories release leaves it: the v2 fixture plus the v3
    /// objects, one project, and user_version 3.
    fn v3_db() -> TestDb {
        let db = TestDb::new("migrate");
        let conn = Connection::open(&db.path).unwrap();
        conn.execute_batch(V2_SCHEMA).unwrap();
        create_v3_objects(&conn).unwrap();
        conn.execute_batch(
            "INSERT INTO projects (id, name, computer_id, folder) VALUES ('p1', 'todo-app', 'mac', '~/programming/todo-app');
             UPDATE todos SET project_id = 'p1' WHERE id = 't1';
             PRAGMA user_version = 3;",
        )
        .unwrap();
        db
    }

    #[test]
    fn migrates_v3_to_v4_keeping_rows() {
        let db = v3_db();
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1, "one backup before the v4 step");
        assert!(db.backups()[0].to_string_lossy().contains(".pre-v4-"), "{:?}", db.backups());
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), 4);
        for table in V4_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos"), 3);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM conversations"), 2);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM projects"), 1);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos WHERE project_id = 'p1'"), 1);
        let backup = Connection::open(&db.backups()[0]).unwrap();
        assert_eq!(user_version(&backup), 3);
        assert!(table_sql(&backup, "push_devices").unwrap().is_none());
        drop(conn);
        drop(pool);
        drop(db.pool());
        assert_eq!(db.backups().len(), 1, "re-opening a v4 database takes no new backup");
    }

    #[test]
    fn migrates_v2_through_v4_with_one_backup() {
        let db = TestDb::new("migrate");
        Connection::open(&db.path).unwrap().execute_batch(V2_SCHEMA).unwrap();
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1);
        assert!(db.backups()[0].to_string_lossy().contains(".pre-v3-"));
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), 4);
        for table in V3_TABLES.iter().chain(V4_TABLES.iter()) {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
    }

    #[test]
    fn fresh_database_is_v4_without_backup() {
        let db = TestDb::new("migrate");
        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), 4);
        assert!(db.backups().is_empty());
        for table in V4_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
    }

    #[test]
    fn schema_version_sniffs_push_devices_as_4() {
        let db = TestDb::new("migrate");
        drop(db.pool());
        let conn = Connection::open(&db.path).unwrap();
        conn.pragma_update(None, "user_version", 0).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 4);
    }

    fn column_names(conn: &Connection, table: &str) -> Vec<String> {
        conn.prepare(&format!("PRAGMA table_info({table})"))
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    fn count(conn: &Connection, sql: &str) -> i64 {
        conn.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn migrates_v2_to_v3_keeping_rows() {
        let db = TestDb::new("migrate");
        Connection::open(&db.path).unwrap().execute_batch(V2_SCHEMA).unwrap();
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1, "one backup before the v3 step");
        assert!(db.backups()[0].to_string_lossy().contains(".pre-v3-"), "{:?}", db.backups());
        drop(pool);
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1, "re-opening a v3 database takes no new backup");

        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos"), 3);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM conversations"), 2);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM section_computers"), 2);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM daily_days"), 1);
        assert!(column_names(&conn, "todos").contains(&"project_id".to_string()));
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos WHERE project_id IS NOT NULL"), 0);
        for table in V3_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
        // The backup is the untouched v2 database.
        let backup = Connection::open(&db.backups()[0]).unwrap();
        assert!(!column_names(&backup, "todos").contains(&"project_id".to_string()));
        assert_eq!(user_version(&backup), 2);

        // Todos keep working with project_id NULL, through the API's own SELECT.
        let todo = conn
            .query_row(
                &format!("SELECT {} FROM todos WHERE id = 't1'", crate::handlers::SELECT_COLS),
                [],
                crate::models::row_to_todo,
            )
            .unwrap();
        assert_eq!((todo.title.as_str(), todo.due_date.as_deref(), todo.project_id), ("linked", Some("2026-10-20"), None));
    }

    #[test]
    fn fresh_database_is_v3_without_backup() {
        let db = TestDb::new("migrate");
        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        assert!(db.backups().is_empty());
        assert!(column_names(&conn, "todos").contains(&"project_id".to_string()));
        for table in V3_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
        for index in ["todos_project", "sessions_project", "sessions_computer", "session_days_day",
                      "memories_project", "memories_session", "memories_todo", "memories_dedup"] {
            let n = count(&conn, &format!("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = '{index}'"));
            assert_eq!(n, 1, "{index}");
        }
    }

    #[test]
    fn schema_version_reads_stored_3() {
        let db = TestDb::new("migrate");
        drop(db.pool());
        let conn = Connection::open(&db.path).unwrap();
        conn.pragma_update(None, "user_version", 3).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 3);
        // An unversioned database that already has the v3 tables is v3, not v2.
        conn.execute_batch(&V4_TABLES.map(|t| format!("DROP TABLE {t};")).concat()).unwrap();
        conn.pragma_update(None, "user_version", 0).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), 3);
    }

    #[test]
    fn unversioned_v2_database_migrates_to_v3() {
        let db = TestDb::new("migrate");
        let conn = Connection::open(&db.path).unwrap();
        conn.execute_batch(V2_SCHEMA).unwrap();
        conn.pragma_update(None, "user_version", 0).unwrap();
        drop(conn);
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1);
        assert_eq!(user_version(&pool.get().unwrap()), SCHEMA_VERSION);
    }

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
        assert_eq!(db.backups().len(), 1, "one backup (of the untouched v1 file) before rewriting the tables");
        // Running it again on the migrated file must be a no-op (and take no second backup).
        drop(pool);
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1);
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        assert!(column_names(&conn, "todos").contains(&"project_id".to_string()), "v1 goes all the way to v3");

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
    fn unversioned_current_database_is_recognised_without_migrating() {
        // A database with the current tables but user_version 0.
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
