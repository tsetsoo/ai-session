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
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            mcp_default TEXT
        );",
    )
    .expect("Failed to create computers table");

    migrate(&conn, db_path).expect("Failed to migrate the database schema");

    conn.execute_batch(&format!(
        "{};\n{};\n{};\n{};\n{};",
        section_computers_ddl("section_computers"),
        conversations_ddl("conversations"),
        "CREATE INDEX IF NOT EXISTS conversations_todo ON conversations(todo_id)",
        "CREATE INDEX IF NOT EXISTS conversations_session_id ON conversations(session_id)",
        "CREATE UNIQUE INDEX IF NOT EXISTS conversations_tool_session ON conversations(tool, session_id) WHERE session_id IS NOT NULL"
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
            computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT
        )"
    )
}

/// v2 shape, kept only so the v1 → v2 rebuild still copies cwd and tool for v5 to retire.
fn section_computers_v2_ddl(table: &str) -> String {
    format!(
        "CREATE TABLE {table} (
            section     TEXT PRIMARY KEY CHECK(section IN ('Sp','I','Si','P')),
            computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd         TEXT NOT NULL,
            tool        TEXT NOT NULL DEFAULT 'claude' CHECK(tool IN {TOOLS_SQL})
        )"
    )
}

/// The conversation table before v6: one row per todo, no `id` or `label`.
/// v1→v2 and the v5 session-id rebuild insert into this shape. v6 is `conversations_ddl`.
fn conversations_pre_v6_ddl(table: &str) -> String {
    format!(
        "CREATE TABLE {table} (
            todo_id           TEXT PRIMARY KEY REFERENCES todos(id) ON DELETE CASCADE,
            computer_id       TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd               TEXT NOT NULL,
            tool              TEXT NOT NULL CHECK(tool IN {TOOLS_SQL}),
            tmux_name         TEXT NOT NULL UNIQUE,
            session_id        TEXT,
            status            TEXT NOT NULL DEFAULT 'unknown'
                              CHECK(status IN ('busy','waiting','idle','unknown','closed')),
            status_message    TEXT,
            status_updated_at TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now'))
        )"
    )
}

fn conversations_ddl(table: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {table} (
            id                TEXT PRIMARY KEY NOT NULL DEFAULT (lower(hex(randomblob(16)))),
            todo_id           TEXT NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
            computer_id       TEXT NOT NULL REFERENCES computers(id) ON DELETE RESTRICT,
            cwd               TEXT NOT NULL,
            tool              TEXT NOT NULL CHECK(tool IN {TOOLS_SQL}),
            tmux_name         TEXT NOT NULL UNIQUE,
            session_id        TEXT,
            status            TEXT NOT NULL DEFAULT 'unknown'
                              CHECK(status IN ('busy','waiting','idle','unknown','closed')),
            status_message    TEXT,
            status_updated_at TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now')),
            label             TEXT,
            mcp_servers       TEXT,
            status_revision   INTEGER NOT NULL DEFAULT 0,
            reviewed          INTEGER NOT NULL DEFAULT 0
        )"
    )
}

pub(crate) fn projects_ddl() -> &'static str {
        "CREATE TABLE IF NOT EXISTS projects (
        id             TEXT PRIMARY KEY,
        name           TEXT NOT NULL,
        section        TEXT NOT NULL CHECK(section IN ('Sp','I','Si','P')),
        folder         TEXT NOT NULL,
        repo_url       TEXT,
        digest_enabled INTEGER NOT NULL DEFAULT 1,
        created_at     TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at     TEXT NOT NULL DEFAULT (datetime('now')),
        mcp_default    TEXT,
        UNIQUE(section, folder)
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
/// - v5: a project belongs to a section; section folder and tool are dropped; conversation
///   session ids may be null until Codex or Cursor reports one; every todo has a project
/// - v6: a conversation has its own `id`; `todo_id` is no longer the primary key; `label`
///   is an optional name for a duplicate
/// - v7: `conversations.mcp_servers`, `projects.mcp_default`, `computers.mcp_default`: JSON
///   arrays of MCP server names, NULL when nothing was chosen (additive)
/// - v8: an idle result's reviewed flag and status revision (additive)
///
/// Add a new version by bumping this and adding a numbered step to `migrate`.
pub const SCHEMA_VERSION: i64 = 8;

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
    if conversations.as_deref().is_some_and(|sql| sql.contains("reviewed")) {
        return Ok(8);
    }
    if conversations.as_deref().is_some_and(|sql| sql.contains("mcp_servers")) {
        return Ok(7);
    }
    if conversations.as_deref().is_some_and(|sql| sql.contains("label")) {
        return Ok(6);
    }
    if table_sql(conn, "projects")?.is_some_and(|sql| sql.contains("section") && !sql.contains("computer_id")) {
        return Ok(5);
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
            backed_up = true;
        }
        create_v4_objects(conn)?;
        version = 4;
    }
    if version == 4 {
        if !backed_up {
            backup_before_migration(conn, db_path, 5)?;
            backed_up = true;
        }
        migrate_v4_to_v5(conn)?;
        version = 5;
    }
    if version == 5 {
        if !backed_up {
            backup_before_migration(conn, db_path, 6)?;
            backed_up = true;
        }
        migrate_v5_to_v6(conn)?;
        version = 6;
    }
    if version == 6 {
        if !backed_up {
            backup_before_migration(conn, db_path, 7)?;
            backed_up = true;
        }
        migrate_v6_to_v7(conn)?;
        version = 7;
    }
    if version == 7 {
        if !backed_up {
            backup_before_migration(conn, db_path, 8)?;
        }
        let tx = conn.unchecked_transaction()?;
        if !column_exists(&tx, "conversations", "status_revision")? {
            tx.execute_batch("ALTER TABLE conversations ADD COLUMN status_revision INTEGER NOT NULL DEFAULT 0;")?;
        }
        if !column_exists(&tx, "conversations", "reviewed")? {
            tx.execute_batch("ALTER TABLE conversations ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0;")?;
        }
        tx.commit()?;
    }
    Ok(())
}

/// v6 → v7. MCP server selections: three nullable JSON columns. A step that rebuilt a
/// table from the current DDL may already have a column, so each is added only if missing.
fn migrate_v6_to_v7(conn: &Connection) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    for (table, column) in [("conversations", "mcp_servers"), ("projects", "mcp_default"), ("computers", "mcp_default")] {
        if !column_exists(&tx, table, column)? {
            tx.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} TEXT;"))?;
        }
    }
    tx.commit()
}

/// v5 → v6. A todo can have many conversations. Each row gets its own id. Existing
/// rows have no label.
fn migrate_v5_to_v6(conn: &Connection) -> rusqlite::Result<()> {
    if column_exists(conn, "conversations", "id")? {
        return Ok(());
    }
    conn.execute_batch("PRAGMA foreign_keys=OFF;")?;
    let result = migrate_v5_to_v6_in(conn);
    conn.execute_batch("PRAGMA foreign_keys=ON;")?;
    result
}

fn migrate_v5_to_v6_in(conn: &Connection) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    type Row = (
        String,
        String,
        String,
        String,
        String,
        Option<String>,
        String,
        Option<String>,
        Option<String>,
        String,
    );
    let rows: Vec<Row> = {
        let mut stmt = tx.prepare(
            "SELECT todo_id, computer_id, cwd, tool, tmux_name, session_id, status,
                    status_message, status_updated_at, created_at FROM conversations",
        )?;
        let mapped = stmt.query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
                r.get(8)?,
                r.get(9)?,
            ))
        })?;
        mapped.collect::<rusqlite::Result<Vec<_>>>()?
    };
    tx.execute_batch(&format!(
        "{};
         DROP TABLE conversations;
         ALTER TABLE conversations_new RENAME TO conversations;
         CREATE INDEX IF NOT EXISTS conversations_todo ON conversations(todo_id);
         CREATE INDEX IF NOT EXISTS conversations_session_id ON conversations(session_id);
         CREATE UNIQUE INDEX IF NOT EXISTS conversations_tool_session
             ON conversations(tool, session_id) WHERE session_id IS NOT NULL;",
        conversations_ddl("conversations_new").replace("CREATE TABLE IF NOT EXISTS", "CREATE TABLE")
    ))?;
    for (todo_id, computer_id, cwd, tool, tmux_name, session_id, status, status_message, status_updated_at, created_at) in
        rows
    {
        tx.execute(
            "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id,
                                         status, status_message, status_updated_at, created_at, label)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, NULL)",
            params![
                uuid::Uuid::new_v4().to_string(),
                todo_id,
                computer_id,
                cwd,
                tool,
                tmux_name,
                session_id,
                status,
                status_message,
                status_updated_at,
                created_at
            ],
        )?;
    }
    tx.commit()
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

const SECTION_ORDER: [&str; 4] = ["Sp", "I", "Si", "P"];

fn section_rank(section: &str) -> usize {
    SECTION_ORDER.iter().position(|s| *s == section).unwrap_or(SECTION_ORDER.len())
}

fn last_path_segment(path: &str) -> String {
    let trimmed = path.trim().trim_end_matches('/');
    let segment = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if segment.is_empty() || segment == "~" { "inbox".into() } else { segment.into() }
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
    conn.prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = ?1"))?
        .exists(params![column])
}

/// v4 → v5. Projects belong to a section. Section cwd and tool are copied onto projects
/// where a todo still needs a folder, then dropped.
fn migrate_v4_to_v5(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch("PRAGMA foreign_keys=OFF;")?;
    let result = migrate_v4_to_v5_in(conn);
    conn.execute_batch("PRAGMA foreign_keys=ON;")?;
    result
}

fn migrate_v4_to_v5_in(conn: &Connection) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let has_computer = column_exists(&tx, "projects", "computer_id")?;
    let mut sections: Vec<(String, String, Option<String>)> = {
        let cwd = column_exists(&tx, "section_computers", "cwd")?;
        let sql = if cwd {
            "SELECT section, computer_id, cwd FROM section_computers"
        } else {
            "SELECT section, computer_id, NULL FROM section_computers"
        };
        let mut stmt = tx.prepare(sql)?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };

    #[derive(Clone)]
    struct NewProject {
        id: String,
        name: String,
        section: String,
        folder: String,
        repo_url: Option<String>,
        digest_enabled: i64,
        created_at: String,
        updated_at: String,
    }
    let mut projects: Vec<NewProject> = Vec::new();
    let mut todo_project: Vec<(String, String)> = Vec::new();

    if has_computer {
        type OldProjectRow = (String, String, String, String, Option<String>, i64, String, String);
        let old: Vec<OldProjectRow> = {
            let mut stmt = tx.prepare(
                "SELECT id, name, computer_id, folder, repo_url, digest_enabled, created_at, updated_at FROM projects",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?))
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let linked: Vec<(String, String, String)> = {
            let mut stmt = tx.prepare("SELECT id, section, project_id FROM todos WHERE project_id IS NOT NULL")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        for (id, name, computer_id, folder, repo_url, digest, created_at, updated_at) in old {
            let mut used: Vec<String> = linked
                .iter()
                .filter(|(_, _, project_id)| project_id == &id)
                .map(|(_, section, _)| section.clone())
                .collect();
            used.sort_by_key(|s| section_rank(s));
            used.dedup();
            if used.is_empty() {
                if let Some(section) = section_for_computer(&sections, &computer_id, &folder) {
                    used.push(section);
                } else if let Some(section) = claim_unassigned_section(&tx, &mut sections, &computer_id)? {
                    used.push(section);
                } else {
                    return Err(rusqlite::Error::SqliteFailure(
                        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
                        Some(format!(
                            "project {name} is on computer {computer_id}, which is not on a section"
                        )),
                    ));
                }
            }
            for (i, section) in used.iter().enumerate() {
                let new_id = if i == 0 { id.clone() } else { uuid::Uuid::new_v4().to_string() };
                projects.push(NewProject {
                    id: new_id.clone(),
                    name: name.clone(),
                    section: section.clone(),
                    folder: folder.clone(),
                    repo_url: repo_url.clone(),
                    digest_enabled: digest,
                    created_at: created_at.clone(),
                    updated_at: updated_at.clone(),
                });
                for (todo_id, todo_section, project_id) in &linked {
                    if project_id == &id && todo_section == section {
                        todo_project.push((todo_id.clone(), new_id.clone()));
                    }
                }
            }
        }
    } else {
        let mut stmt = tx.prepare(
            "SELECT id, name, section, folder, repo_url, digest_enabled, created_at, updated_at FROM projects",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(NewProject {
                id: r.get(0)?,
                name: r.get(1)?,
                section: r.get(2)?,
                folder: r.get(3)?,
                repo_url: r.get(4)?,
                digest_enabled: r.get(5)?,
                created_at: r.get(6)?,
                updated_at: r.get(7)?,
            })
        })?;
        projects = rows.collect::<rusqlite::Result<Vec<_>>>()?;
    }

    let loose: Vec<(String, String)> = {
        let mut stmt = tx.prepare("SELECT id, section FROM todos WHERE project_id IS NULL")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (todo_id, section) in loose {
        let folder = sections
            .iter()
            .find(|(s, _, _)| s == &section)
            .and_then(|(_, _, cwd)| cwd.clone())
            .unwrap_or_else(|| "~".into());
        let name = last_path_segment(&folder);
        let existing = projects.iter().find(|p| p.section == section && p.folder == folder);
        let id = if let Some(existing) = existing {
            existing.id.clone()
        } else {
            let id = uuid::Uuid::new_v4().to_string();
            projects.push(NewProject {
                id: id.clone(),
                name,
                section: section.clone(),
                folder,
                repo_url: None,
                digest_enabled: 1,
                created_at: String::new(),
                updated_at: String::new(),
            });
            id
        };
        todo_project.push((todo_id, id));
    }

    if has_computer {
        tx.execute_batch("DROP TABLE projects;")?;
        tx.execute_batch(projects_ddl())?;
    }
    for project in &projects {
        let already: bool = tx
            .query_row("SELECT 1 FROM projects WHERE id = ?1", params![project.id], |_| Ok(()))
            .optional()?
            .is_some();
        if already {
            continue;
        }
        tx.execute(
            "INSERT INTO projects (id, name, section, folder, repo_url, digest_enabled, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, COALESCE(NULLIF(?7, ''), datetime('now')), COALESCE(NULLIF(?8, ''), datetime('now')))",
            params![
                project.id,
                project.name,
                project.section,
                project.folder,
                project.repo_url,
                project.digest_enabled,
                project.created_at,
                project.updated_at
            ],
        )?;
    }
    for (todo_id, project_id) in &todo_project {
        tx.execute("UPDATE todos SET project_id = ?1 WHERE id = ?2", params![project_id, todo_id])?;
    }
    if column_exists(&tx, "memories", "id")? {
        tx.execute(
            "UPDATE memories SET project_id = (
                SELECT project_id FROM todos WHERE todos.id = memories.todo_id
             ) WHERE todo_id IS NOT NULL",
            [],
        )?;
    }
    let project_keys: Vec<(String, String, String)> = projects
        .iter()
        .map(|p| (p.id.clone(), p.section.clone(), p.folder.clone()))
        .collect();
    rematch_migrated_sessions(&tx, &project_keys, &sections)?;

    if column_exists(&tx, "section_computers", "cwd")? {
        tx.execute_batch(&format!(
            "{};
             INSERT INTO section_computers_new (section, computer_id)
                 SELECT section, computer_id FROM section_computers;
             DROP TABLE section_computers;
             ALTER TABLE section_computers_new RENAME TO section_computers;",
            section_computers_ddl("section_computers_new").replace("CREATE TABLE IF NOT EXISTS", "CREATE TABLE")
        ))?;
    }
    if column_not_null(&tx, "conversations", "session_id")? {
        tx.execute_batch(&format!(
            "{};
             INSERT INTO conversations_new (todo_id, computer_id, cwd, tool, tmux_name, session_id,
                                            status, status_message, status_updated_at, created_at)
                 SELECT todo_id, computer_id, cwd, tool, tmux_name, session_id,
                        status, status_message, status_updated_at, created_at FROM conversations;
             DROP TABLE conversations;
             ALTER TABLE conversations_new RENAME TO conversations;
             CREATE UNIQUE INDEX IF NOT EXISTS conversations_tool_session
                 ON conversations(tool, session_id) WHERE session_id IS NOT NULL;",
            conversations_pre_v6_ddl("conversations_new")
        ))?;
    }
    // Every todo now has a project. Rebuild so the column cannot go back to null.
    if !column_not_null(&tx, "todos", "project_id")? {
        let nulls: i64 = tx.query_row("SELECT COUNT(*) FROM todos WHERE project_id IS NULL", [], |r| r.get(0))?;
        if nulls > 0 {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
                Some(format!("{nulls} todos still have no project")),
            ));
        }
        tx.execute_batch(
            "CREATE TABLE todos_new (
                id         TEXT PRIMARY KEY,
                section    TEXT NOT NULL CHECK(section IN ('Sp','I','Si','P')),
                title      TEXT NOT NULL,
                completed  INTEGER NOT NULL DEFAULT 0,
                importance TEXT NOT NULL DEFAULT 'medium' CHECK(importance IN ('low','medium','high','critical')),
                due_date   TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                completed_at TEXT,
                daily_date TEXT,
                carried_from TEXT,
                project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT
            );
            INSERT INTO todos_new (id, section, title, completed, importance, due_date, created_at, updated_at,
                                   completed_at, daily_date, carried_from, project_id)
                SELECT id, section, title, completed, importance, due_date, created_at, updated_at,
                       completed_at, daily_date, carried_from, project_id FROM todos;
            DROP TABLE todos;
            ALTER TABLE todos_new RENAME TO todos;
            CREATE INDEX IF NOT EXISTS todos_project ON todos(project_id);",
        )?;
    }
    let violations: i64 = tx.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| r.get(0))?;
    if violations > 0 {
        return Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CONSTRAINT),
            Some(format!("{violations} foreign key violations after migration")),
        ));
    }
    tx.commit()
}

fn column_not_null(conn: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
    let notnull: Option<i64> = conn
        .query_row(
            &format!("SELECT \"notnull\" FROM pragma_table_info('{table}') WHERE name = ?1"),
            params![column],
            |r| r.get(0),
        )
        .optional()?;
    Ok(notnull == Some(1))
}

fn section_for_computer(sections: &[(String, String, Option<String>)], computer_id: &str, folder: &str) -> Option<String> {
    let on: Vec<_> = sections.iter().filter(|(_, computer, _)| computer == computer_id).collect();
    if on.is_empty() {
        return None;
    }
    if on.len() == 1 {
        return Some(on[0].0.clone());
    }
    let mut best: Option<(&str, usize)> = None;
    for (section, _, cwd) in &on {
        let Some(cwd) = cwd else { continue };
        if crate::paths::is_within(folder, cwd) {
            let len = cwd.split('/').filter(|s| !s.is_empty()).count();
            if best.map(|(_, n)| len > n).unwrap_or(true) {
                best = Some((section, len));
            }
        }
    }
    if let Some((section, _)) = best {
        return Some(section.into());
    }
    on.into_iter()
        .min_by_key(|(section, _, _)| section_rank(section))
        .map(|(section, _, _)| section.clone())
}

/// Give `computer_id` a section that has no computer yet, in section order. None when every
/// section already has a computer: the project must not move onto a different machine.
fn claim_unassigned_section(
    tx: &Connection,
    sections: &mut Vec<(String, String, Option<String>)>,
    computer_id: &str,
) -> rusqlite::Result<Option<String>> {
    let Some(section) = SECTION_ORDER.iter().copied().find(|code| !sections.iter().any(|(s, _, _)| s == code)) else {
        return Ok(None);
    };
    if column_exists(tx, "section_computers", "cwd")? {
        tx.execute(
            "INSERT INTO section_computers (section, computer_id, cwd, tool) VALUES (?1, ?2, '~', 'claude')",
            params![section, computer_id],
        )?;
    } else {
        tx.execute(
            "INSERT INTO section_computers (section, computer_id) VALUES (?1, ?2)",
            params![section, computer_id],
        )?;
    }
    sections.push((section.to_string(), computer_id.to_string(), Some("~".into())));
    Ok(Some(section.to_string()))
}

fn rematch_migrated_sessions(
    conn: &Connection,
    projects: &[(String, String, String)],
    sections: &[(String, String, Option<String>)],
) -> rusqlite::Result<()> {
    let has_sessions: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'",
        [],
        |r| r.get(0),
    )?;
    if has_sessions == 0 {
        return Ok(());
    }
    let usernames: Vec<(String, String)> = {
        let mut stmt = conn.prepare("SELECT id, username FROM computers")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let sessions: Vec<(String, String, String, String, Option<String>, i64)> = {
        let mut stmt = conn.prepare(
            "SELECT tool, session_id, computer_id, cwd, project_id, project_override FROM sessions",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (tool, session_id, computer_id, cwd, current, override_flag) in sessions {
        if override_flag == 1 && current.as_ref().is_some_and(|id| projects.iter().any(|(pid, _, _)| pid == id)) {
            continue;
        }
        let username = usernames.iter().find(|(id, _)| id == &computer_id).map(|(_, name)| name.as_str()).unwrap_or("");
        let cwd = crate::paths::normalize(&cwd, username);
        let on_computer: Vec<&(String, String, String)> = projects
            .iter()
            .filter(|(_, section, folder)| {
                sections.iter().any(|(s, computer, _)| s == section && computer == &computer_id)
                    && crate::paths::is_within(&cwd, folder)
            })
            .collect();
        let longest = on_computer
            .iter()
            .map(|(_, _, folder)| folder.split('/').filter(|s| !s.is_empty()).count())
            .max()
            .unwrap_or(0);
        let mut matches: Vec<(String, String)> = on_computer
            .iter()
            .filter(|(_, _, folder)| folder.split('/').filter(|s| !s.is_empty()).count() == longest)
            .map(|(id, section, _)| ((*id).clone(), (*section).clone()))
            .collect();
        let chosen = if longest == 0 {
            None
        } else if let Some(todo_project) = session_todo_project(conn, &tool, &session_id)? {
            if matches.iter().any(|(id, _)| id == &todo_project) {
                Some(todo_project)
            } else {
                pick_session_project(&mut matches, current.as_deref())
            }
        } else {
            pick_session_project(&mut matches, current.as_deref())
        };
        if chosen != current {
            conn.execute(
                "UPDATE sessions SET project_id = ?1 WHERE tool = ?2 AND session_id = ?3",
                params![chosen, tool, session_id],
            )?;
        }
    }
    if column_exists(conn, "memories", "session_id")? {
        conn.execute(
            "UPDATE memories SET project_id = (
                SELECT sessions.project_id FROM sessions
                WHERE sessions.tool = memories.tool AND sessions.session_id = memories.session_id
             )
             WHERE todo_id IS NULL AND tool IS NOT NULL AND session_id IS NOT NULL
               AND EXISTS (
                   SELECT 1 FROM sessions
                   WHERE sessions.tool = memories.tool AND sessions.session_id = memories.session_id
                     AND sessions.project_id IS NOT NULL
               )",
            [],
        )?;
    }
    Ok(())
}

fn session_todo_project(conn: &Connection, tool: &str, session_id: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT todos.project_id FROM conversations
         JOIN todos ON todos.id = conversations.todo_id
         WHERE conversations.tool = ?1 AND conversations.session_id = ?2",
        params![tool, session_id],
        |r| r.get::<_, Option<String>>(0),
    )
    .optional()
    .map(Option::flatten)
}

fn pick_session_project(matches: &mut [(String, String)], current: Option<&str>) -> Option<String> {
    if let Some(current) = current {
        if let Some((id, _)) = matches.iter().find(|(id, _)| id == current) {
            return Some(id.clone());
        }
    }
    matches.sort_by_key(|(_, section)| section_rank(section));
    matches.first().map(|(id, _)| id.clone())
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
                section_computers_v2_ddl("section_computers_new")
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
                conversations_pre_v6_ddl("conversations_new")
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
            "PRAGMA foreign_keys = OFF;
             DROP TABLE projects;
             CREATE TABLE projects (
                 id TEXT PRIMARY KEY,
                 name TEXT NOT NULL,
                 computer_id TEXT NOT NULL REFERENCES computers(id),
                 folder TEXT NOT NULL,
                 repo_url TEXT,
                 digest_enabled INTEGER NOT NULL DEFAULT 1,
                 created_at TEXT NOT NULL DEFAULT (datetime('now')),
                 updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                 UNIQUE(computer_id, folder)
             );
             INSERT INTO projects (id, name, computer_id, folder) VALUES ('p1', 'todo-app', 'mac', '~/programming/todo-app');
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
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        for table in V4_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos"), 3);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM conversations"), 2);
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM projects"), 3);
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
    fn migrates_v4_to_v5_splits_projects_and_places_loose_todos() {
        let db = TestDb::new("migrate-v5");
        let conn = Connection::open(&db.path).unwrap();
        conn.execute_batch(V2_SCHEMA).unwrap();
        create_v4_objects(&conn).unwrap();
        conn.execute_batch(
            "ALTER TABLE todos ADD COLUMN project_id TEXT;
             CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                computer_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                repo_url TEXT,
                digest_enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(computer_id, folder)
             );
             CREATE TABLE memories (
                id TEXT PRIMARY KEY,
                project_id TEXT,
                todo_id TEXT,
                computer_id TEXT,
                tool TEXT,
                session_id TEXT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                text_key TEXT NOT NULL,
                files TEXT NOT NULL DEFAULT '[]',
                confidence REAL,
                source TEXT NOT NULL DEFAULT 'extracted',
                pinned INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             DELETE FROM section_computers WHERE section = 'I';
             INSERT INTO section_computers (section, computer_id, cwd, tool)
                 VALUES ('P', 'mac', '~/programming', 'claude');
             INSERT INTO projects (id, name, computer_id, folder)
                 VALUES ('p1', 'sigma', 'mac', '~/programming/sigma-revenue');
             UPDATE todos SET project_id = 'p1' WHERE id = 't1';
             UPDATE todos SET section = 'P', project_id = 'p1' WHERE id = 't3';
             INSERT INTO todos (id, section, title) VALUES ('t-loose', 'Si', 'loose');
             INSERT INTO memories (id, project_id, todo_id, kind, text, text_key)
                 VALUES ('m1', 'p1', 't1', 'decision', 'Keep', 'keep');
             PRAGMA user_version = 4;",
        )
        .unwrap();
        drop(conn);

        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        let project_cols = column_names(&conn, "projects");
        assert!(!project_cols.iter().any(|c| c == "computer_id"));
        assert!(project_cols.iter().any(|c| c == "section"));
        let section_cols = column_names(&conn, "section_computers");
        assert!(!section_cols.iter().any(|c| c == "cwd" || c == "tool"));

        let pieces: Vec<(String, String)> = conn
            .prepare("SELECT section, folder FROM projects WHERE name = 'sigma' ORDER BY section")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(
            pieces,
            vec![
                ("P".into(), "~/programming/sigma-revenue".into()),
                ("Si".into(), "~/programming/sigma-revenue".into()),
            ]
        );
        let t1_section: String = conn
            .query_row(
                "SELECT p.section FROM todos t JOIN projects p ON p.id = t.project_id WHERE t.id = 't1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(t1_section, "Si");
        let t3_section: String = conn
            .query_row(
                "SELECT p.section FROM todos t JOIN projects p ON p.id = t.project_id WHERE t.id = 't3'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(t3_section, "P");
        let loose: (String, String, String) = conn
            .query_row(
                "SELECT p.section, p.folder, p.name FROM todos t JOIN projects p ON p.id = t.project_id WHERE t.id = 't-loose'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(loose, ("Si".into(), "~/programming".into(), "programming".into()));
        let sigma_on_si: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM projects WHERE section = 'Si' AND folder = '~/programming/sigma-revenue'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(sigma_on_si, 1, "the nested project still exists under the section folder");
        let session: String = conn
            .query_row("SELECT session_id FROM conversations WHERE todo_id = 't1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(session, "sess-1");
        let memory_section: String = conn
            .query_row(
                "SELECT p.section FROM memories m JOIN projects p ON p.id = m.project_id WHERE m.id = 'm1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(memory_section, "Si");
    }

    fn v4_ready(name: &str) -> (TestDb, Connection) {
        let db = TestDb::new(name);
        let conn = Connection::open(&db.path).unwrap();
        conn.execute_batch(V2_SCHEMA).unwrap();
        create_v4_objects(&conn).unwrap();
        conn.execute_batch(
            "ALTER TABLE todos ADD COLUMN project_id TEXT;
             CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                computer_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                repo_url TEXT,
                digest_enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             INSERT INTO computers (id, name, hostname, username) VALUES ('pi', 'pi', 'pi.local', 'me');
             INSERT INTO projects (id, name, computer_id, folder) VALUES ('p-orphan', 'orphan', 'pi', '~/orphan');
             PRAGMA user_version = 4;",
        )
        .unwrap();
        (db, conn)
    }

    #[test]
    fn migration_refuses_a_project_whose_computer_is_on_no_section() {
        let (_db, conn) = v4_ready("migrate-orphan");
        conn.execute_batch(
            "INSERT INTO section_computers (section, computer_id, cwd, tool) VALUES
                ('Sp', 'mac', '~', 'claude'), ('P', 'mac', '~', 'claude');",
        )
        .unwrap();
        let err = migrate_v4_to_v5(&conn).unwrap_err().to_string();
        assert!(err.contains("not on a section"), "{err}");
        let computer: String = conn
            .query_row("SELECT computer_id FROM projects WHERE id = 'p-orphan'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(computer, "pi", "the project stays on its own computer");
        let stolen: i64 = conn
            .query_row("SELECT COUNT(*) FROM section_computers WHERE computer_id = 'pi'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stolen, 0);
    }

    #[test]
    fn migration_gives_an_unassigned_section_to_the_projects_computer() {
        let (_db, conn) = v4_ready("migrate-claim");
        conn.execute_batch(
            "DELETE FROM section_computers WHERE section = 'I';
             INSERT INTO section_computers (section, computer_id, cwd, tool) VALUES
                ('Sp', 'mac', '~', 'claude'), ('P', 'mac', '~', 'claude');",
        )
        .unwrap();
        migrate_v4_to_v5(&conn).unwrap();
        let section: String = conn.query_row("SELECT section FROM projects WHERE id = 'p-orphan'", [], |r| r.get(0)).unwrap();
        assert_eq!(section, "I");
        let computer: String = conn
            .query_row("SELECT computer_id FROM section_computers WHERE section = 'I'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(computer, "pi");
    }

    #[test]
    fn migrates_v2_through_v4_with_one_backup() {
        let db = TestDb::new("migrate");
        Connection::open(&db.path).unwrap().execute_batch(V2_SCHEMA).unwrap();
        let pool = db.pool();
        assert_eq!(db.backups().len(), 1);
        assert!(db.backups()[0].to_string_lossy().contains(".pre-v3-"));
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        for table in V3_TABLES.iter().chain(V4_TABLES.iter()) {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
    }

    #[test]
    fn migrates_v5_to_v6_allows_a_second_conversation() {
        let db = TestDb::new("migrate-v6");
        let conn = Connection::open(&db.path).unwrap();
        conn.execute_batch(V2_SCHEMA).unwrap();
        create_v4_objects(&conn).unwrap();
        conn.execute_batch(
            "ALTER TABLE todos ADD COLUMN project_id TEXT;
             CREATE TABLE projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                computer_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                repo_url TEXT,
                digest_enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE memories (
                id TEXT PRIMARY KEY,
                project_id TEXT,
                todo_id TEXT,
                computer_id TEXT,
                tool TEXT,
                session_id TEXT,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                text_key TEXT NOT NULL,
                files TEXT NOT NULL DEFAULT '[]',
                confidence REAL,
                source TEXT NOT NULL DEFAULT 'extracted',
                pinned INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             DELETE FROM section_computers WHERE section = 'I';
             INSERT INTO section_computers (section, computer_id, cwd, tool)
                 VALUES ('P', 'mac', '~/programming', 'claude');
             INSERT INTO projects (id, name, computer_id, folder)
                 VALUES ('p1', 'sigma', 'mac', '~/programming/sigma-revenue');
             UPDATE todos SET project_id = 'p1' WHERE id = 't1';
             UPDATE todos SET section = 'P', project_id = 'p1' WHERE id = 't3';
             INSERT INTO todos (id, section, title) VALUES ('t-loose', 'Si', 'loose');
             INSERT INTO memories (id, project_id, todo_id, kind, text, text_key)
                 VALUES ('m1', 'p1', 't1', 'decision', 'Keep', 'keep');
             PRAGMA user_version = 4;",
        )
        .unwrap();
        drop(conn);

        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        let row: (String, String, String, Option<String>, String) = conn
            .query_row(
                "SELECT todo_id, tool, tmux_name, label, id FROM conversations WHERE session_id = 'sess-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(row.0, "t1");
        assert_eq!(row.1, "claude");
        assert_eq!(row.2, "ai/claude/todo-t1");
        assert_eq!(row.3, None);
        assert!(!row.4.is_empty());
        conn.execute(
            "INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, label)
             VALUES ('c2', 't1', 'mac', '~/programming', 'codex', 'ai/codex/todo-t1-b', 'sess-9', 'duplicate')",
            [],
        )
        .unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM conversations WHERE todo_id = 't1'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn migrates_v6_to_v7_adds_null_mcp_columns() {
        let db = TestDb::new("migrate-v7");
        drop(db.pool());
        let conn = Connection::open(&db.path).unwrap();
        // A v6 database: the current tables without the v7 columns.
        conn.execute_batch(
            "ALTER TABLE conversations DROP COLUMN mcp_servers;
             ALTER TABLE projects DROP COLUMN mcp_default;
             ALTER TABLE computers DROP COLUMN mcp_default;
             INSERT INTO computers (id, name, hostname, username) VALUES ('mac', 'Mac', 'mac.tailnet', 'me');
             INSERT INTO projects (id, name, section, folder) VALUES ('p1', 'prog', 'I', '~/programming');
             INSERT INTO todos (id, section, title, project_id) VALUES ('t1', 'I', 'todo', 'p1');
             INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id)
                 VALUES ('c1', 't1', 'mac', '~/programming', 'claude', 'ai/claude/todo-t1', 's1');
             PRAGMA user_version = 6;",
        )
        .unwrap();
        drop(conn);

        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        assert_eq!(db.backups().len(), 1, "migrating backs up first");
        let read = |sql: &str| -> Option<String> { conn.query_row(sql, [], |r| r.get(0)).unwrap() };
        assert_eq!(read("SELECT mcp_servers FROM conversations WHERE id = 'c1'"), None);
        assert_eq!(read("SELECT mcp_default FROM projects WHERE id = 'p1'"), None);
        assert_eq!(read("SELECT mcp_default FROM computers WHERE id = 'mac'"), None);
    }

    #[test]
    fn fresh_database_is_v4_without_backup() {
        let db = TestDb::new("migrate");
        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
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
        assert_eq!(schema_version(&conn).unwrap(), SCHEMA_VERSION);
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
        assert_eq!(count(&conn, "SELECT COUNT(*) FROM todos WHERE project_id IS NOT NULL"), 3);
        for table in V3_TABLES {
            assert!(table_sql(&conn, table).unwrap().is_some(), "{table} exists");
        }
        // The backup is the untouched v2 database.
        let backup = Connection::open(&db.backups()[0]).unwrap();
        assert!(!column_names(&backup, "todos").contains(&"project_id".to_string()));
        assert_eq!(user_version(&backup), 2);

        // A loose todo from v2 now belongs to a project on its section.
        let todo = conn
            .query_row(
                &format!("SELECT {} FROM todos WHERE id = 't1'", crate::handlers::SELECT_COLS),
                [],
                crate::models::row_to_todo,
            )
            .unwrap();
        assert_eq!((todo.title.as_str(), todo.due_date.as_deref()), ("linked", Some("2026-10-20")));
        assert!(todo.project_id.is_some());
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
        // An unversioned database whose projects already belong to a section is v5.
        conn.execute_batch(&V4_TABLES.map(|t| format!("DROP TABLE {t};")).concat()).unwrap();
        conn.pragma_update(None, "user_version", 0).unwrap();
        assert_eq!(schema_version(&conn).unwrap(), SCHEMA_VERSION);
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

        // Unknown tools are still rejected. A section no longer stores one.
        assert!(conn.execute("UPDATE conversations SET tool = 'vim' WHERE todo_id = 't1'", []).is_err());
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
    fn migrates_v7_results_as_unreviewed_and_preserves_conversations() {
        let db = TestDb::new("migrate-v8");
        {
            let pool = db.pool();
            let conn = pool.get().unwrap();
            conn.execute_batch(
                "INSERT INTO computers (id, name, hostname, username) VALUES ('mac', 'Mac', 'mac.local', 'me');
                 INSERT INTO todos (id, section, title) VALUES ('t', 'Sp', 'Existing result');
                 INSERT INTO conversations (id, todo_id, computer_id, cwd, tool, tmux_name, session_id, status)
                     VALUES ('c', 't', 'mac', '~/code', 'claude', 'ai/claude/todo-t', 's', 'idle');
                 ALTER TABLE conversations DROP COLUMN status_revision;
                 ALTER TABLE conversations DROP COLUMN reviewed;
                 PRAGMA user_version = 7;",
            ).unwrap();
        }
        let pool = db.pool();
        let conn = pool.get().unwrap();
        assert_eq!(user_version(&conn), SCHEMA_VERSION);
        let result: (String, i64, bool) = conn.query_row(
            "SELECT status, status_revision, reviewed FROM conversations WHERE id = 'c'", [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).unwrap();
        assert_eq!(result, ("idle".into(), 0, false));
        assert_eq!(db.backups().len(), 1);
        let backup = Connection::open(&db.backups()[0]).unwrap();
        assert_eq!(user_version(&backup), 7);
        assert!(!column_exists(&backup, "conversations", "reviewed").unwrap());
        drop(conn);
        drop(pool);
        drop(db.pool());
        assert_eq!(db.backups().len(), 1, "reopening must not migrate again");
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
        let sections = table_sql(&conn, "section_computers").unwrap().unwrap();
        assert!(!sections.contains("cwd") && !sections.contains("tool"), "{sections}");
        assert!(sql.contains("'codex'"), "{sql}");
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
