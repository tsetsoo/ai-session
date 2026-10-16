//! Folder paths of projects and conversation working directories.
//!
//! Paths are compared as lists of segments, so `~/x` never matches `~/xy`. Both sides
//! are stored in their `~` form; a path under the computer's home directory
//! (`/Users/<username>/…` or `/home/<username>/…`) is rewritten to `~/…` on write.

/// A path split into segments, with whether it is absolute (`/…`).
struct Segments<'a> {
    absolute: bool,
    parts: Vec<&'a str>,
}

fn segments(path: &str) -> Segments<'_> {
    let path = path.trim();
    Segments {
        absolute: path.starts_with('/'),
        parts: path.split('/').filter(|s| !s.is_empty() && *s != ".").collect(),
    }
}

impl Segments<'_> {
    fn join(&self) -> String {
        let joined = self.parts.join("/");
        if self.absolute {
            format!("/{joined}")
        } else {
            joined
        }
    }

    fn starts_with(&self, prefix: &Segments) -> bool {
        self.absolute == prefix.absolute && self.parts.starts_with(&prefix.parts)
    }
}

/// The canonical spelling of a path: `~` for the home directory of `username`, no
/// trailing `/`, no empty or `.` segments. An empty `username` only tidies the spelling.
pub fn normalize(path: &str, username: &str) -> String {
    let mut segs = segments(path);
    let username = username.trim();
    if segs.absolute
        && !username.is_empty()
        && segs.parts.len() >= 2
        && matches!(segs.parts[0], "Users" | "home")
        && segs.parts[1] == username
    {
        segs.parts.splice(0..2, ["~"]);
        segs.absolute = false;
    }
    segs.join()
}

/// Whether `path` is `folder` or lies below it (segment-wise).
pub fn is_within(path: &str, folder: &str) -> bool {
    segments(path).starts_with(&segments(folder))
}

/// The project whose folder is the longest segment prefix of `cwd`.
/// `projects` holds `(id, folder)` pairs of one computer.
pub fn best_project<'a>(cwd: &str, projects: &'a [(String, String)]) -> Option<&'a str> {
    let cwd = segments(cwd);
    projects
        .iter()
        .map(|(id, folder)| (id, segments(folder)))
        .filter(|(_, folder)| cwd.starts_with(folder))
        .max_by_key(|(_, folder)| folder.parts.len())
        .map(|(id, _)| id.as_str())
}

/// The folder suggested as a project for a conversation's `cwd`: everything from a
/// `/.claude/worktrees/` segment pair on is dropped, then the path is cut to two
/// segments below `~`, or three for absolute paths.
pub fn suggestion_folder(cwd: &str) -> String {
    let mut segs = segments(cwd);
    if let Some(i) = segs.parts.windows(2).position(|w| w == [".claude", "worktrees"]) {
        segs.parts.truncate(i);
    }
    // `~` plus two segments, or three segments of an absolute path: three parts either way.
    segs.parts.truncate(3);
    segs.join()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_equates_spellings() {
        for spelling in ["~/x", "/Users/me/x", "~/x/", "~//x", " ~/x ", "/home/me/x", "~/./x"] {
            assert_eq!(normalize(spelling, "me"), "~/x", "{spelling}");
        }
        assert_eq!(normalize("/Users/me", "me"), "~");
        assert_eq!(normalize("/Users/me/", "me"), "~");
        assert_eq!(normalize("/Users/meme/x", "me"), "/Users/meme/x", "another user's home stays absolute");
        assert_eq!(normalize("/Users/other/x", "me"), "/Users/other/x");
        assert_eq!(normalize("/opt//a/", "me"), "/opt/a");
        assert_eq!(normalize("/", "me"), "/");
        assert_eq!(normalize("/Users/me/x", ""), "/Users/me/x", "no username: only the spelling is tidied");
    }

    #[test]
    fn within_respects_segments() {
        assert!(is_within("~/x/y", "~/x"));
        assert!(is_within("~/x", "~/x"));
        assert!(is_within("~/x/", "~//x"));
        assert!(!is_within("~/xy", "~/x"));
        assert!(!is_within("~/x", "~/x/y"));
        assert!(!is_within("/x/y", "~/x"), "absolute and ~ paths never match");
        assert!(!is_within("~/x", "/x"));
        assert!(is_within("/opt/a/b", "/opt"));
        assert!(is_within("~/a/.claude/worktrees/w", "~/a"));
    }

    #[test]
    fn best_project_picks_longest() {
        let projects = vec![
            ("outer".to_string(), "~/programming".to_string()),
            ("inner".to_string(), "~/programming/sigma-revenue".to_string()),
            ("other".to_string(), "~/programming/sigma-revenue-old".to_string()),
        ];
        assert_eq!(
            best_project("~/programming/sigma-revenue/sigma-revenue-backend/.claude/worktrees/x", &projects),
            Some("inner")
        );
        assert_eq!(best_project("~/programming/sigma-revenue-old/a", &projects), Some("other"));
        assert_eq!(best_project("~/programming/todo-app", &projects), Some("outer"));
        assert_eq!(best_project("~/Spread", &projects), None);
        assert_eq!(best_project("~/programming/sigma-revenue/", &projects), Some("inner"));
    }

    #[test]
    fn suggestion_folder_strips_worktrees() {
        assert_eq!(
            suggestion_folder("~/programming/sigma-revenue/sigma-revenue-backend/.claude/worktrees/x"),
            "~/programming/sigma-revenue"
        );
        assert_eq!(suggestion_folder("~/programming/todo-app/.claude/worktrees/x/sub"), "~/programming/todo-app");
        assert_eq!(suggestion_folder("~/programming"), "~/programming");
        assert_eq!(suggestion_folder("~"), "~");
        assert_eq!(suggestion_folder("/opt/a/b/c/d"), "/opt/a/b");
        assert_eq!(suggestion_folder("/opt/a"), "/opt/a");
        assert_eq!(suggestion_folder("~/Spread/Repository/"), "~/Spread/Repository");
        // A folder merely named .claude is kept; only .claude/worktrees is stripped.
        assert_eq!(suggestion_folder("~/x/.claude/rules"), "~/x/.claude");
    }
}
