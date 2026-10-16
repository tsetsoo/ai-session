//! Sessions: Claude/Codex conversations known from a computer's transcripts, whether or
//! not a todo links them, with their usage stats.

use rusqlite::{params, Connection, OptionalExtension};

use crate::paths;
use crate::projects::project_for;

/// The computer's username, for normalizing paths to their `~` form.
pub(crate) fn username_of(conn: &Connection, computer_id: &str) -> rusqlite::Result<String> {
    Ok(conn
        .query_row("SELECT username FROM computers WHERE id = ?1", params![computer_id], |r| r.get(0))
        .optional()?
        .unwrap_or_default())
}

/// Make sure a session row exists (a minimal one: cwd only, matched to a project) and
/// return its project. An existing row is left as it is.
pub(crate) fn ensure_session_db(
    conn: &Connection,
    computer_id: &str,
    tool: &str,
    session_id: &str,
    cwd: &str,
) -> rusqlite::Result<Option<String>> {
    let existing: Option<Option<String>> = conn
        .query_row(
            "SELECT project_id FROM sessions WHERE tool = ?1 AND session_id = ?2",
            params![tool, session_id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(project_id) = existing {
        return Ok(project_id);
    }
    let cwd = paths::normalize(cwd, &username_of(conn, computer_id)?);
    let project_id = project_for(conn, computer_id, &cwd)?;
    conn.execute(
        "INSERT INTO sessions (tool, session_id, computer_id, cwd, project_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![tool, session_id, computer_id, cwd, project_id],
    )?;
    Ok(project_id)
}
