use std::collections::BTreeMap;

use serde::{Deserialize, Deserializer, Serialize};

/// For PATCH fields that can be cleared: absent → `None` (unchanged), `null` → `Some(None)`
/// (clear), a value → `Some(Some(v))`. Plain serde reads `null` as absent. Use with
/// `#[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]`.
///
/// # Errors
/// When the value is neither `null` nor a valid `T`.
pub fn double_option<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Section {
    Sp,
    I,
    Si,
    P,
}

impl Section {
    #[must_use] 
    pub fn all() -> &'static [Section] {
        &[Section::Sp, Section::I, Section::Si, Section::P]
    }

    #[must_use] 
    pub fn as_str(&self) -> &'static str {
        match self {
            Section::Sp => "Sp",
            Section::I => "I",
            Section::Si => "Si",
            Section::P => "P",
        }
    }

    #[must_use] 
    pub fn parse(s: &str) -> Option<Section> {
        match s {
            "Sp" => Some(Section::Sp),
            "I" => Some(Section::I),
            "Si" => Some(Section::Si),
            "P" => Some(Section::P),
            _ => None,
        }
    }
}

impl std::fmt::Display for Section {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Importance {
    Low,
    #[default]
    Medium,
    High,
    Critical,
}

impl Importance {
    #[must_use] 
    pub fn all() -> &'static [Importance] {
        &[Importance::Low, Importance::Medium, Importance::High, Importance::Critical]
    }

    #[must_use] 
    pub fn as_str(&self) -> &'static str {
        match self {
            Importance::Low => "low",
            Importance::Medium => "medium",
            Importance::High => "high",
            Importance::Critical => "critical",
        }
    }

    #[must_use] 
    pub fn parse(s: &str) -> Option<Importance> {
        match s {
            "low" => Some(Importance::Low),
            "medium" => Some(Importance::Medium),
            "high" => Some(Importance::High),
            "critical" => Some(Importance::Critical),
            _ => None,
        }
    }

    #[must_use] 
    pub fn label(&self) -> &'static str {
        match self {
            Importance::Low => "Low",
            Importance::Medium => "Medium",
            Importance::High => "High",
            Importance::Critical => "Critical",
        }
    }
}

impl std::fmt::Display for Importance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Todo {
    pub id: String,
    pub section: Section,
    pub title: String,
    pub completed: bool,
    /// Deliberately paused; independent of the AI conversation's status.
    #[serde(default)]
    pub on_hold: bool,
    pub importance: Importance,
    /// Optional due date in YYYY-MM-DD format
    pub due_date: Option<String>,
    /// Optional daily board date in YYYY-MM-DD format
    #[serde(default)]
    pub daily_date: Option<String>,
    /// Previous daily date when carried forward
    #[serde(default)]
    pub carried_from: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
    /// Status of this todo's AI conversation, if it has one
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_status: Option<ConversationStatus>,
    /// The project this todo belongs to, if any
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// Created by this scheduler job (a scheduled todo)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_job_id: Option<String>,
    /// The run that created it
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_run_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreateTodoRequest {
    /// Omitted means the new todo uses its project's section.
    #[serde(default)]
    pub section: Option<Section>,
    pub title: String,
    #[serde(default)]
    pub importance: Option<Importance>,
    #[serde(default)]
    pub due_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct UpdateTodoRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_hold: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub section: Option<Section>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub importance: Option<Importance>,
    /// `null` clears the due date.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub due_date: Option<Option<String>>,
    /// A project. JSON `null` is rejected: a todo keeps a project.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Option<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionCount {
    pub section: Section,
    pub total: usize,
    pub completed: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteResponse {
    pub deleted: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyStatus {
    pub local_today: String,
    pub has_today: bool,
    pub has_tomorrow: bool,
    /// Which create action the UI should offer: "today" or "tomorrow"
    pub button: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDailyRequest {
    pub local_today: String,
    /// "today" or "tomorrow"
    #[serde(rename = "for")]
    pub for_day: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetTodoDailyRequest {
    /// Target daily date, or null to remove from Daily
    pub date: Option<String>,
}

// ---------------------------------------------------------------------------
// AI conversations: computers, section → computer mapping, per-todo conversation
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConversationStatus {
    Busy,
    Waiting,
    Idle,
    #[default]
    Unknown,
    Closed,
}

impl ConversationStatus {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            ConversationStatus::Busy => "busy",
            ConversationStatus::Waiting => "waiting",
            ConversationStatus::Idle => "idle",
            ConversationStatus::Unknown => "unknown",
            ConversationStatus::Closed => "closed",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<ConversationStatus> {
        match s {
            "busy" => Some(ConversationStatus::Busy),
            "waiting" => Some(ConversationStatus::Waiting),
            "idle" => Some(ConversationStatus::Idle),
            "unknown" => Some(ConversationStatus::Unknown),
            "closed" => Some(ConversationStatus::Closed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Computer {
    pub id: String,
    pub name: String,
    /// Tailscale name or IP
    pub hostname: String,
    pub port: u16,
    pub username: String,
    pub created_at: String,
    pub updated_at: String,
    /// MCP server names ticked by default for new conversations on this computer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp_default: Option<Vec<String>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreateComputerRequest {
    pub name: String,
    pub hostname: String,
    #[serde(default)]
    pub port: Option<u16>,
    pub username: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct UpdateComputerRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    /// `null` clears the default.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub mcp_default: Option<Option<Vec<String>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionComputer {
    pub section: Section,
    pub computer: Computer,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SetSectionComputerRequest {
    pub computer_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OpenConversationRequest {
    pub tool: String,
    /// MCP server names for a conversation this call creates; ignored when it already exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp_servers: Option<Vec<String>>,
    /// The app can create worktrees (passes `--worktree` to `ai-todo-open`). Without it, a
    /// new conversation shares the project folder, as before.
    #[serde(default)]
    pub worktrees: bool,
}

/// Replace a conversation's MCP selection. `null` means no selection was made.
#[derive(Debug, Serialize, Deserialize)]
pub struct SetConversationMcpRequest {
    pub mcp_servers: Option<Vec<String>>,
}

/// Switch a conversation's resume after a session limit on or off.
#[derive(Debug, Serialize, Deserialize)]
pub struct SetConversationResumeRequest {
    pub resume_on_reset: bool,
}

/// Sent by the status service on the computer about a paused conversation, found by tool
/// and session id. See `ResumeAction`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConversationResumeRequest {
    pub tool: String,
    pub session_id: String,
    pub action: String,
    /// `arm`: when it will be resumed (RFC 3339).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_at: Option<String>,
    /// `claim`, `sent`, `release`: the lease token the computer made up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    /// `claim`: the user tapped Resume, so the toggle and the cap don't apply.
    #[serde(default)]
    pub manual: bool,
}

/// What the computer needs to resume a paused conversation, and the answer to its action.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversationResumeState {
    pub conversation_id: String,
    pub tmux_name: String,
    pub cwd: String,
    pub status: ConversationStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<LimitPause>,
    pub reviewed: bool,
    pub resume_on_reset: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_off_reason: Option<String>,
    /// `claim`: the lease is this computer's; type the message.
    pub granted: bool,
    /// Why a claim wasn't granted: not_paused, closed, toggle_off, not_session, reviewed,
    /// cap, leased.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Sent by the host script after it starts a conversation: the servers it actually passed.
#[derive(Debug, Serialize, Deserialize)]
pub struct ReportConversationMcpRequest {
    pub tool: String,
    pub session_id: String,
    pub mcp_servers: Vec<String>,
}

/// Copy one conversation of a todo into another (or the same) tool.
#[derive(Debug, Serialize, Deserialize)]
pub struct DuplicateConversationRequest {
    pub source_id: String,
    pub tool: String,
    pub label: String,
    /// Add agent: the new conversation gets its own worktree (when the source has one) instead
    /// of sharing the source's. Older apps don't send it and share, as before.
    #[serde(default)]
    pub own_worktree: bool,
    /// The tool's model; `None`: its default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The commit the new worktree starts from (a snapshot of the source, or its base).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_sha: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SetConversationSessionRequest {
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Conversation {
    /// Stable id of this conversation. Empty when decoded from a server that still
    /// keys a conversation by todo id.
    #[serde(default)]
    pub id: String,
    pub todo_id: String,
    pub computer: Computer,
    pub cwd: String,
    pub tool: String,
    pub tmux_name: String,
    /// The tool's own conversation id: `claude --resume <id>`, `codex resume <id>`, …
    #[serde(default)]
    pub session_id: String,
    /// Same value as `session_id` for Claude conversations, `null` for other tools. Kept for
    /// apps and hooks installed before tools other than Claude were supported, which would
    /// otherwise run `claude --resume` on a Codex/Cursor id.
    pub claude_session_id: Option<String>,
    pub status: ConversationStatus,
    pub status_message: Option<String>,
    pub status_updated_at: Option<String>,
    #[serde(default)]
    pub status_revision: i64,
    #[serde(default)]
    pub reviewed: bool,
    pub created_at: String,
    /// The conversation's project: its session's project, or matched from computer + cwd
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// Name given when this conversation was duplicated. Absent on the original.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// MCP servers selected for this conversation. Absent when no selection was made.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp_servers: Option<Vec<String>>,
    /// The last turn stopped on a usage limit. The status is `idle`, so apps that predate
    /// this show it as finished. Absent when the conversation isn't paused.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<LimitPause>,
    /// The project folder this conversation's own git worktree is made from. Present when
    /// `cwd` is that worktree (`~/.ai-remote/worktrees/<project>/<conversation>`), which the
    /// computer creates on first open (`ai-todo-open --worktree <source> <branch>`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_source: Option<String>,
    /// The worktree's branch, with `worktree_source`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    /// Resume on its own once a session (5-hour) limit resets. Off by default.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub resume_on_reset: bool,
    /// Why the hub switched `resume_on_reset` off: `cap` (3 resumes in 24 hours).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_off_reason: Option<String>,
    /// The pull request (GitHub) or merge request (GitLab) of the branch this conversation
    /// works on, as its computer's runner last found it. Absent until one is found.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<PullRequest>,
    /// The tool's model, when one was chosen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The commit this conversation's worktree started from, when it was added from another.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_base: Option<String>,
    /// The conversation the user continued with ("Continue with this") on its todo.
    #[serde(default)]
    pub main: bool,
}

/// A conversation's pull or merge request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullRequest {
    pub url: String,
    /// "open", "merged" or "closed".
    pub state: String,
}

/// A conversation stopped by a subscription or API usage limit.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LimitPause {
    /// `session` (the 5-hour window), `weekly`, or `limit` (no reset time known: a plain
    /// rate limit, or one whose message couldn't be read).
    pub kind: String,
    /// When the limit resets (RFC 3339, UTC), if known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    /// When the computer plans to resume it (RFC 3339, UTC). Only on hub replies.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_at: Option<String>,
    /// The limit has reset and a one-tap Resume is offered. Only on hub replies.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub offer: bool,
}

impl LimitPause {
    pub const KINDS: &'static [&'static str] = &["session", "weekly", "limit"];
}

/// Sent by the status hooks on the computer. Either key identifies the conversation;
/// `claude_session_id` is what hooks installed before multi-tool support send.
/// `tool` defaults to `claude` (older hooks are all Claude hooks), so one post matches
/// at most one conversation even when two tools share an id.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ConversationStatusRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claude_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    pub status: ConversationStatus,
    #[serde(default)]
    pub message: Option<String>,
    /// Sent by hooks: a tmux client attached to the conversation had keyboard activity in
    /// the last minute (or, on a repeated `waiting`, since the prompt appeared). Suppresses
    /// the push. Older hooks omit it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attended: Option<bool>,
    /// Capture time on the reporting host, before any network work. Claude/Codex reporters
    /// persist this with their outbox so retrying an old event cannot undo a newer one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_timestamp_ns: Option<i64>,
    /// Latest user turn, retained when offline updates coalesce or a fast turn is missed
    /// by runtime polling. Repeated heartbeats for this turn do not rearm review.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_started_ns: Option<i64>,
    /// With `idle`: the turn stopped on a usage limit. A later post without it clears the
    /// pause only when the status changes or a new turn starts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paused: Option<LimitPause>,
}

/// Acknowledge only the idle result the client actually displayed.
#[derive(Debug, Serialize, Deserialize)]
pub struct ReviewConversationRequest {
    pub status_revision: i64,
}

impl ConversationStatusRequest {
    /// The conversation id from whichever key was sent (`session_id` wins), if non-empty.
    #[must_use]
    pub fn session_id(&self) -> Option<&str> {
        self.session_id
            .as_deref()
            .or(self.claude_session_id.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }

    /// The tool the hook reports for, `claude` when not sent.
    #[must_use]
    pub fn tool(&self) -> &str {
        self.tool.as_deref().map(str::trim).filter(|s| !s.is_empty()).unwrap_or("claude")
    }
}

/// Link an existing conversation (made outside the todo app) to a todo.
#[derive(Debug, Serialize, Deserialize)]
pub struct LinkConversationRequest {
    pub computer_id: String,
    pub tool: String,
    pub session_id: String,
    pub cwd: String,
}

/// Create a todo from an existing conversation, linked to it.
#[derive(Debug, Serialize, Deserialize)]
pub struct TodoFromConversationRequest {
    pub section: Section,
    pub title: String,
    pub project_id: String,
    pub computer_id: String,
    pub tool: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub importance: Option<Importance>,
    #[serde(default)]
    pub due_date: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoWithConversation {
    pub todo: Todo,
    pub conversation: Conversation,
}

// ---------------------------------------------------------------------------
// Projects: a folder on one section. The computer is the section's computer.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub section: Section,
    pub computer: Computer,
    /// Folder on the computer, `~`-relative when under its home, no trailing `/`
    pub folder: String,
    #[serde(default)]
    pub repo_url: Option<String>,
    pub digest_enabled: bool,
    pub created_at: String,
    pub updated_at: String,
    /// Todos of this project that are not completed
    #[serde(default)]
    pub open_todos: i64,
    #[serde(default)]
    pub sessions: i64,
    /// Memories that are not archived
    #[serde(default)]
    pub memories: i64,
    /// Latest `last_activity` of the project's sessions
    #[serde(default)]
    pub last_activity: Option<String>,
    /// MCP server names ticked by default for new conversations in this project.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mcp_default: Option<Vec<String>>,
    /// A summary of each day's work (08:00 to 08:00 Sofia) is written for this project.
    #[serde(default)]
    pub daily_updates: bool,
    /// How the daily update should read; empty: a plain bullet list.
    #[serde(default)]
    pub update_style: String,
    /// New conversations open in their own git worktree (only when the project has a
    /// `repo_url`, i.e. is a git repo). Off: they share the project folder.
    #[serde(default = "default_true")]
    pub worktrees: bool,
}

fn default_true() -> bool {
    true
}

/// One day's update of a project (the window starting 08:00 Sofia on `day`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectUpdate {
    pub day: String,
    /// Markdown.
    pub text: String,
    pub commits: u32,
    /// Conversation summaries it was written from.
    pub conversations: u32,
    /// Conversations of that day that couldn't be summarized.
    #[serde(default)]
    pub failed: u32,
    /// Computers that hadn't reported when it was written.
    pub waiting_on: Vec<String>,
    pub written_at: String,
    /// A rewrite was asked for, or a late summary came in; the project's computer rewrites it.
    pub rewriting: bool,
}

/// One conversation's summary for a day, as the project update was written from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateSummary {
    pub tool: String,
    pub session_id: String,
    pub todo_id: Option<String>,
    pub title: String,
    pub summary: String,
    pub jira_keys: Vec<String>,
    pub computer: String,
    /// The conversation couldn't be summarized (`summary` is empty).
    #[serde(default)]
    pub failed: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreateProjectRequest {
    pub name: String,
    pub section: Section,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest_enabled: Option<bool>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct UpdateProjectRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// `null` clears the repo URL.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub repo_url: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest_enabled: Option<bool>,
    /// `null` clears the default.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub mcp_default: Option<Option<Vec<String>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daily_updates: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_style: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktrees: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSuggestion {
    pub computer: Computer,
    pub folder: String,
    pub name: String,
    #[serde(default)]
    pub repo_url: Option<String>,
    pub sessions: i64,
    #[serde(default)]
    pub last_activity: Option<String>,
    #[serde(default)]
    pub example_cwds: Vec<String>,
}

// ---------------------------------------------------------------------------
// Sessions: Claude/Codex conversations known from a computer's transcripts
// ---------------------------------------------------------------------------

/// Usage numbers of one conversation, recomputed from its whole transcript.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionStats {
    #[serde(default)]
    pub prompts: i64,
    #[serde(default)]
    pub assistant_turns: i64,
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub cache_read_tokens: Option<i64>,
    #[serde(default)]
    pub cache_creation_tokens: Option<i64>,
    #[serde(default)]
    pub active_seconds: i64,
    /// ISO 8601 UTC
    #[serde(default)]
    pub first_activity: Option<String>,
    #[serde(default)]
    pub last_activity: Option<String>,
    #[serde(default)]
    pub files_touched: Vec<String>,
    #[serde(default)]
    pub models: Vec<String>,
}

/// Usage numbers of one conversation on one local day of its computer.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionDay {
    /// YYYY-MM-DD
    pub day: String,
    #[serde(default)]
    pub prompts: i64,
    #[serde(default)]
    pub assistant_turns: i64,
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub cache_read_tokens: Option<i64>,
    #[serde(default)]
    pub cache_creation_tokens: Option<i64>,
    #[serde(default)]
    pub active_seconds: i64,
    /// Distinct files edited that day
    #[serde(default)]
    pub files_touched: i64,
}

/// One conversation in `POST /api/sessions/stats` (an item of `ai-todo-sessions stats --json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionUpload {
    pub tool: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub repo_url: Option<String>,
    #[serde(default)]
    pub stats: SessionStats,
    /// Replaces all of the session's day rows
    #[serde(default)]
    pub days: Vec<SessionDay>,
    /// The conversation's own tokens per model. Absent (an older collector): the stored
    /// rows are kept; present: they are replaced.
    #[serde(default)]
    pub by_model: Option<BTreeMap<String, ModelTokens>>,
    /// Sub-agents and internal threads. Absent: the stored workers are kept; present
    /// (even empty): they are replaced.
    #[serde(default)]
    pub workers: Option<Vec<WorkerUpload>>,
    /// Entries copied from another transcript (resume, fork) that were not counted
    #[serde(default)]
    pub copied_entries_skipped: Option<i64>,
}

/// Token fields of one model. A field the tool doesn't report is null.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelTokens {
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub cache_read_tokens: Option<i64>,
    #[serde(default)]
    pub cache_creation_tokens: Option<i64>,
}

/// One sub-agent (Claude `subagents/agent-*.jsonl`, a Codex child thread) of an uploaded
/// conversation; nested workers are already flattened under the top conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerUpload {
    pub id: String,
    /// `agent` (a sub-agent the conversation started) or `internal` (e.g. Codex guardian)
    #[serde(default = "default_worker_kind")]
    pub kind: String,
    /// Agent type, e.g. `Explore`, `general-purpose`
    #[serde(default, rename = "type")]
    pub worker_type: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub depth: Option<i64>,
    #[serde(default)]
    pub stats: SessionStats,
    #[serde(default)]
    pub days: Vec<SessionDay>,
    #[serde(default)]
    pub by_model: BTreeMap<String, ModelTokens>,
}

fn default_worker_kind() -> String {
    "agent".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStatsUpload {
    pub computer_id: String,
    #[serde(default)]
    pub sessions: Vec<SessionUpload>,
}

/// A session's project after an upload.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionProjectRef {
    pub tool: String,
    pub session_id: String,
    pub project_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStatsResponse {
    pub upserted: usize,
    pub sessions: Vec<SessionProjectRef>,
}

/// A known conversation with its stats (flat, as stored) and, when it is linked to a
/// todo, that todo's id and conversation status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub tool: String,
    pub session_id: String,
    pub computer_id: String,
    pub cwd: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub repo_root: Option<String>,
    #[serde(default)]
    pub repo_url: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
    /// Set in the app; automatic matching leaves the project alone
    #[serde(default)]
    pub project_override: bool,
    #[serde(default)]
    pub prompts: i64,
    #[serde(default)]
    pub assistant_turns: i64,
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub cache_read_tokens: Option<i64>,
    #[serde(default)]
    pub cache_creation_tokens: Option<i64>,
    #[serde(default)]
    pub active_seconds: i64,
    #[serde(default)]
    pub first_activity: Option<String>,
    #[serde(default)]
    pub last_activity: Option<String>,
    #[serde(default)]
    pub files_touched: Vec<String>,
    #[serde(default)]
    pub models: Vec<String>,
    #[serde(default)]
    pub stats_updated_at: Option<String>,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub todo_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<ConversationStatus>,
}

/// `{"project_id":"<id>"}` sets an override, `{"project_id":null}` overrides to no
/// project, `{"auto":true}` clears the override and matches automatically again.
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct SetSessionProjectRequest {
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto: Option<bool>,
}

// ---------------------------------------------------------------------------
// Weekly stats
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct StatsCounters {
    /// Distinct sessions with at least one day in the week
    pub sessions: i64,
    pub prompts: i64,
    pub assistant_turns: i64,
    /// Sums over non-null values; null when every value is null
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_creation_tokens: Option<i64>,
    pub active_seconds: i64,
    pub files_touched: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectRollup {
    pub project_id: Option<String>,
    pub name: Option<String>,
    #[serde(flatten)]
    pub counters: StatsCounters,
    #[serde(default)]
    pub workers: StatsCounters,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SectionRollup {
    pub section: Option<Section>,
    #[serde(flatten)]
    pub counters: StatsCounters,
    #[serde(default)]
    pub workers: StatsCounters,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ComputerRollup {
    pub computer_id: String,
    pub name: String,
    #[serde(flatten)]
    pub counters: StatsCounters,
    #[serde(default)]
    pub workers: StatsCounters,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyStats {
    /// Monday, YYYY-MM-DD
    pub week_start: String,
    /// Sunday, YYYY-MM-DD
    pub week_end: String,
    /// The conversations' own usage
    pub totals: StatsCounters,
    /// Their sub-agents' usage on the week's days (`sessions` counts workers); add it to
    /// `totals` for everything the week cost. Rollups carry the same split.
    #[serde(default)]
    pub workers: StatsCounters,
    pub by_project: Vec<ProjectRollup>,
    pub by_section: Vec<SectionRollup>,
    pub by_computer: Vec<ComputerRollup>,
}

// ---------------------------------------------------------------------------
// Usage of a todo or job: its conversations' own usage and their workers'
// ---------------------------------------------------------------------------

/// Tokens of one model over a todo's or job's conversations (own + workers).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelUsage {
    pub model: String,
    #[serde(flatten)]
    pub tokens: ModelTokens,
}

/// Workers of one kind and type, e.g. 7 `agent`/`Explore`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkerTypeUsage {
    pub kind: String,
    #[serde(rename = "type")]
    pub worker_type: Option<String>,
    #[serde(flatten)]
    pub counters: StatsCounters,
}

/// Why a conversation has numbers or not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageReading {
    /// Its computer uploaded stats for it
    Uploaded,
    /// Cursor keeps no token counts
    Cursor,
    /// The tool hasn't reported a session id yet
    NoSession,
    /// Known session, but no stats upload yet
    NotUploaded,
}

/// One conversation of a todo, with its own and its workers' usage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConversationUsage {
    pub conversation_id: String,
    pub todo_id: String,
    pub tool: String,
    #[serde(default)]
    pub session_id: Option<String>,
    pub computer_id: String,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    pub reading: UsageReading,
    pub own: StatsCounters,
    pub workers: StatsCounters,
    #[serde(default)]
    pub first_activity: Option<String>,
    #[serde(default)]
    pub last_activity: Option<String>,
    #[serde(default)]
    pub stats_updated_at: Option<String>,
    /// The conversation is no longer on the todo (deleted, or replaced by a restart), but
    /// its session still counts there
    #[serde(default)]
    pub removed: bool,
}

/// Usage summed over a set of conversations.
///
/// `own` is the conversations' own usage, `workers` their sub-agents'. Add them for the
/// total. `own.active_seconds` is time someone or the agent was busy in the conversation;
/// `elapsed_seconds` spans first to last activity (workers included). Never a price:
/// subscription quota isn't money per conversation.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageSummary {
    pub own: StatsCounters,
    pub workers: StatsCounters,
    /// Own + workers per model, the heaviest (output + cache-creation tokens) first
    pub by_model: Vec<ModelUsage>,
    /// The heaviest (output + cache-creation tokens) first
    pub worker_types: Vec<WorkerTypeUsage>,
    #[serde(default)]
    pub first_activity: Option<String>,
    #[serde(default)]
    pub last_activity: Option<String>,
    #[serde(default)]
    pub elapsed_seconds: Option<i64>,
    /// The oldest upload among the conversations with numbers: everything is at least this fresh
    #[serde(default)]
    pub stats_updated_at: Option<String>,
    /// Conversations without numbers (Cursor, no session id yet, never uploaded)
    pub unread_conversations: i64,
    pub conversations: Vec<ConversationUsage>,
}

/// `GET /api/todos/{id}/usage`
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TodoUsage {
    pub todo_id: String,
    #[serde(flatten)]
    pub usage: UsageSummary,
}

/// One run of a job with its todo's usage. A run without a todo has empty usage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunUsage {
    pub run_id: String,
    pub due_at: String,
    pub state: String,
    #[serde(default)]
    pub todo_id: Option<String>,
    #[serde(flatten)]
    pub usage: UsageSummary,
}

/// `GET /api/jobs/{id}/usage`: all runs summed, then the newest runs one by one.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobUsage {
    pub job_id: String,
    #[serde(flatten)]
    pub usage: UsageSummary,
    pub runs: Vec<RunUsage>,
}

/// One todo in `GET /api/stats/heaviest`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeavyTodo {
    pub todo_id: String,
    pub title: String,
    pub section: Option<Section>,
    #[serde(default)]
    pub project_id: Option<String>,
    pub own: StatsCounters,
    pub workers: StatsCounters,
}

/// One job (all its runs' todos) in `GET /api/stats/heaviest`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeavyJob {
    pub job_id: String,
    pub name: String,
    /// Runs whose todo's conversations had activity that week
    pub runs: i64,
    pub own: StatsCounters,
    pub workers: StatsCounters,
}

/// One conversation in `GET /api/stats/heaviest`, linked to a todo or not.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeavyConversation {
    pub tool: String,
    pub session_id: String,
    pub computer_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
    #[serde(default)]
    pub todo_id: Option<String>,
    pub own: StatsCounters,
    pub workers: StatsCounters,
}

/// `GET /api/stats/heaviest`: what used the most of one week, each list heaviest first
/// by output + cache-creation tokens (cache reads are cheap and left out of the ranking).
/// Counts only, never a price.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeavyUsage {
    pub week_start: String,
    pub week_end: String,
    /// Every conversation's own usage that week
    pub own: StatsCounters,
    /// Every sub-agent's usage that week
    pub workers: StatsCounters,
    pub todos: Vec<HeavyTodo>,
    pub jobs: Vec<HeavyJob>,
    pub worker_types: Vec<WorkerTypeUsage>,
    pub conversations: Vec<HeavyConversation>,
}

// ---------------------------------------------------------------------------
// Memories
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    Decision,
    Gotcha,
    OpenThread,
    Done,
    FilesChanged,
}

impl MemoryKind {
    #[must_use]
    pub fn all() -> &'static [MemoryKind] {
        &[MemoryKind::Decision, MemoryKind::Gotcha, MemoryKind::OpenThread, MemoryKind::Done, MemoryKind::FilesChanged]
    }

    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            MemoryKind::Decision => "decision",
            MemoryKind::Gotcha => "gotcha",
            MemoryKind::OpenThread => "open_thread",
            MemoryKind::Done => "done",
            MemoryKind::FilesChanged => "files_changed",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<MemoryKind> {
        MemoryKind::all().iter().copied().find(|k| k.as_str() == s)
    }
}

impl std::fmt::Display for MemoryKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Memory {
    pub id: String,
    pub project_id: Option<String>,
    pub todo_id: Option<String>,
    pub computer_id: Option<String>,
    /// `null` for manual memories
    pub tool: Option<String>,
    pub session_id: Option<String>,
    pub kind: MemoryKind,
    pub text: String,
    #[serde(default)]
    pub files: Vec<String>,
    pub confidence: Option<f64>,
    /// `extracted`, `manual`, `claude-memory` (imported) or `agent` (saved on purpose)
    pub source: String,
    pub pinned: bool,
    pub archived: bool,
    pub created_at: String,
    pub updated_at: String,
    /// Proposed by an agent and waiting for the user's OK; hidden from lists unless asked for.
    #[serde(default)]
    pub pending: bool,
    /// Uses: relied on, found by search, touched by the user, or re-extracted.
    #[serde(default)]
    pub use_count: i64,
    #[serde(default)]
    pub last_used_at: Option<String>,
    /// Why it was archived: `unused`, `duplicate`, `superseded`, `retired` or `user`.
    #[serde(default)]
    pub archived_reason: Option<String>,
    /// Imported memories: `<claude project dir>/<file>`, unique per computer.
    #[serde(default)]
    pub source_key: Option<String>,
}

/// A manual memory from the app, or one an agent saves on purpose (`source: "agent"`,
/// `pending: true`). It needs a project, a todo, or a computer (a global memory).
#[derive(Debug, Serialize, Deserialize)]
pub struct CreateMemoryRequest {
    pub kind: MemoryKind,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub todo_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    /// The computer of a global memory (no project, no todo).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub computer_id: Option<String>,
    /// `manual` (default) or `agent`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<bool>,
}

/// One imported memory file in `POST /api/memories/import`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportMemory {
    pub source_key: String,
    /// `null`: a global memory of the posting computer.
    #[serde(default)]
    pub project_id: Option<String>,
    pub kind: MemoryKind,
    pub text: String,
}

/// `POST /api/memories/import`: upserts on (computer_id, source_key).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportMemoriesRequest {
    pub computer_id: String,
    #[serde(default)]
    pub items: Vec<ImportMemory>,
    /// Keys of files that are gone: their memories are archived (reason `retired`).
    #[serde(default)]
    pub remove_keys: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportMemoriesResponse {
    pub inserted: usize,
    pub updated: usize,
    pub unchanged: usize,
    #[serde(default)]
    pub removed: usize,
}

/// One extracted memory in `POST /api/memories/bulk`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewMemory {
    pub kind: MemoryKind,
    pub text: String,
    #[serde(default)]
    pub files: Vec<String>,
    #[serde(default)]
    pub confidence: Option<f64>,
    /// Ids of earlier memories this one resolves or replaces
    #[serde(default)]
    pub supersedes: Vec<String>,
}

/// Memories extracted from one conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BulkMemoriesRequest {
    pub computer_id: String,
    pub tool: String,
    pub session_id: String,
    pub cwd: String,
    #[serde(default)]
    pub memories: Vec<NewMemory>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BulkMemoriesResponse {
    pub inserted: Vec<Memory>,
    pub duplicates: usize,
    /// Ids archived through `supersedes`
    pub archived: Vec<String>,
    pub project_id: Option<String>,
    pub todo_id: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct UpdateMemoryRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<MemoryKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub files: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived: Option<bool>,
    /// With `archived: true`: `duplicate` or `retired` (the memory gardener); default `user`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub archived_reason: Option<String>,
    /// The memory gardener's change: refused for pinned, hand-written and imported memories,
    /// and an archive is marked as the gardener's (so a bad run can be found and undone).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by_gardener: Option<bool>,
    /// `false` approves a pending memory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<bool>,
    /// `null` makes the memory project-less.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub project_id: Option<Option<String>>,
    /// `null` unlinks the memory from its todo.
    #[serde(default, deserialize_with = "double_option", skip_serializing_if = "Option::is_none")]
    pub todo_id: Option<Option<String>>,
}

// ---------------------------------------------------------------------------
// Push notifications (APNs)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApnsEnvironment {
    Sandbox,
    Production,
}

impl ApnsEnvironment {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            ApnsEnvironment::Sandbox => "sandbox",
            ApnsEnvironment::Production => "production",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<ApnsEnvironment> {
        match s {
            "sandbox" => Some(ApnsEnvironment::Sandbox),
            "production" => Some(ApnsEnvironment::Production),
            _ => None,
        }
    }

    #[must_use]
    pub fn other(&self) -> ApnsEnvironment {
        match self {
            ApnsEnvironment::Sandbox => ApnsEnvironment::Production,
            ApnsEnvironment::Production => ApnsEnvironment::Sandbox,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PushPlatform {
    Ios,
    Macos,
}

impl PushPlatform {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            PushPlatform::Ios => "ios",
            PushPlatform::Macos => "macos",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<PushPlatform> {
        match s {
            "ios" => Some(PushPlatform::Ios),
            "macos" => Some(PushPlatform::Macos),
            _ => None,
        }
    }
}

/// `PUT /api/push/devices`: register (or refresh) this device's APNs token.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushDeviceRequest {
    /// APNs device token, hex
    pub token: String,
    pub platform: PushPlatform,
    pub environment: ApnsEnvironment,
    /// The app's bundle id; used as `apns-topic`
    pub bundle_id: String,
    pub app_version: String,
    #[serde(default)]
    pub device_name: Option<String>,
}

/// `POST /api/push/devices/unregister`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushUnregisterRequest {
    pub token: String,
}

/// A registered device. The token is never returned in full.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PushDevice {
    /// First 8 hex characters of the token
    pub token_prefix: String,
    pub platform: PushPlatform,
    pub environment: ApnsEnvironment,
    pub bundle_id: String,
    pub app_version: String,
    pub device_name: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub last_sent_at: Option<String>,
    /// Last APNs failure reason, e.g. `BadDeviceToken`
    pub last_error: Option<String>,
}

/// Quiet hours: pushes inside the window are delivered silently (`passive`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuietHours {
    /// `HH:MM`
    pub start: String,
    /// `HH:MM`; earlier than `start` means the window crosses midnight
    pub end: String,
    /// IANA timezone, e.g. `Europe/Sofia`
    pub tz: String,
}

/// Default grace before a `waiting` push is sent.
pub const DEFAULT_PUSH_GRACE_SECONDS: u32 = 20;

/// `GET /api/push/settings`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PushSettings {
    pub notify_waiting: bool,
    /// Push when a busy run of at least this many minutes goes idle; `None` = never
    pub done_after_minutes: Option<u32>,
    pub grace_seconds: u32,
    pub quiet_hours: Option<QuietHours>,
    pub muted_sections: Vec<Section>,
    pub muted_todo_ids: Vec<String>,
}

impl Default for PushSettings {
    fn default() -> Self {
        Self {
            notify_waiting: true,
            done_after_minutes: None,
            grace_seconds: DEFAULT_PUSH_GRACE_SECONDS,
            quiet_hours: None,
            muted_sections: Vec::new(),
            muted_todo_ids: Vec::new(),
        }
    }
}

/// `PUT /api/push/settings`: replaces everything but the per-todo mutes (which have their
/// own endpoint). Omitted fields take their defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PushSettingsUpdate {
    pub notify_waiting: bool,
    pub done_after_minutes: Option<u32>,
    pub grace_seconds: u32,
    pub quiet_hours: Option<QuietHours>,
    pub muted_sections: Vec<Section>,
}

impl Default for PushSettingsUpdate {
    fn default() -> Self {
        let d = PushSettings::default();
        Self {
            notify_waiting: d.notify_waiting,
            done_after_minutes: d.done_after_minutes,
            grace_seconds: d.grace_seconds,
            quiet_hours: d.quiet_hours,
            muted_sections: d.muted_sections,
        }
    }
}

/// `POST /api/push/presence`: this client is showing `todo_id`'s conversation (or none).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresenceRequest {
    pub client_id: String,
    #[serde(default)]
    pub todo_id: Option<String>,
}

/// `GET /api/push/status`. Never contains key material.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PushStatus {
    /// The APNs key, key id and team id are all set
    pub configured: bool,
    pub last_error: Option<String>,
    pub last_sent_at: Option<String>,
    pub devices: usize,
}

/// `POST /api/push/test`: all devices, or the one with `token`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PushTestRequest {
    #[serde(default)]
    pub token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PushTestResult {
    pub token_prefix: String,
    pub ok: bool,
    pub reason: Option<String>,
}

// --- Scheduler -----------------------------------------------------------------------

/// When a job runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum JobTrigger {
    /// 5-field cron in Europe/Sofia.
    Cron { cron: String },
    /// Only "Run now".
    Manual,
}

/// A conversation job's usage limit setting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum LimitSetting {
    /// Starts whatever the usage.
    Always,
    /// Waits while usage is above these thresholds (percent), or the global ones when unset.
    Wait { five_hour: Option<u8>, weekly: Option<u8> },
}

/// Only decides notifications: background scheduled todos are push-muted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Urgent,
    Background,
}

/// What a job does.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum JobAction {
    /// A scheduled conversation on a Mac, started by its runner.
    Conversation {
        project_id: String,
        /// `None`: the computer of the project's section.
        computer_id: Option<String>,
        /// `claude`, `codex`, or `auto` (the runner picks by weekly headroom).
        tool: String,
        /// `None`: the project folder.
        folder: Option<String>,
        prompt: String,
        priority: Priority,
        limit: LimitSetting,
        /// The tool's model (`haiku`, `gpt-6.1-terra`); `None`: the tool's default.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    /// A research run: the hub picks the project's next idea and builds the prompt;
    /// `prompt` holds optional extra instructions.
    Research {
        project_id: String,
        computer_id: Option<String>,
        tool: String,
        folder: Option<String>,
        prompt: String,
        priority: Priority,
        limit: LimitSetting,
    },
    /// A push, sent by the hub.
    Push { title: String, body: String },
    /// A todo, created by the hub.
    Todo { title: String, project_id: Option<String>, section: Option<Section> },
    /// A watcher check on one computer; new problems push, and with a debug tool open problems
    /// are taken by debugging conversations (runs of the watcher's hidden Debug job).
    Watch {
        project_id: String,
        computer_id: String,
        watcher: String,
        debug_tool: Option<String>,
        /// Extra instructions for the debugging conversations.
        prompt: String,
    },
}

/// The fields shared by conversation and research actions.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ConversationParts<'a> {
    pub project_id: &'a str,
    pub computer_id: Option<&'a str>,
    pub tool: &'a str,
    pub folder: Option<&'a str>,
    pub prompt: &'a str,
    pub priority: Priority,
    pub limit: LimitSetting,
    pub model: Option<&'a str>,
}

impl JobAction {
    /// The conversation a conversation or research action starts; `None` for push and todo.
    #[must_use]
    pub fn conversation_parts(&self) -> Option<ConversationParts<'_>> {
        match self {
            JobAction::Conversation { project_id, computer_id, tool, folder, prompt, priority, limit, model } => Some(ConversationParts {
                project_id,
                computer_id: computer_id.as_deref(),
                tool,
                folder: folder.as_deref(),
                prompt,
                priority: *priority,
                limit: *limit,
                model: model.as_deref(),
            }),
            JobAction::Research { project_id, computer_id, tool, folder, prompt, priority, limit } => Some(ConversationParts {
                project_id,
                computer_id: computer_id.as_deref(),
                tool,
                folder: folder.as_deref(),
                prompt,
                priority: *priority,
                limit: *limit,
                model: None,
            }),
            _ => None,
        }
    }

    #[must_use]
    pub fn is_research(&self) -> bool {
        matches!(self, JobAction::Research { .. })
    }
    #[must_use]
    pub fn is_watch(&self) -> bool {
        matches!(self, JobAction::Watch { .. })
    }
}

/// One problem in a watcher's check output.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WatchProblem {
    pub key: String,
    pub title: String,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub url: String,
    /// The repo, relative to the project folder, a debugging conversation works in.
    #[serde(default)]
    pub folder: Option<String>,
}

/// A watcher's check output: every problem open right now.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WatchReport {
    pub problems: Vec<WatchProblem>,
    /// The list may be incomplete: nothing is cleared.
    #[serde(default)]
    pub partial: bool,
}

/// A watcher problem on the hub, per watcher and key. `state`: `open`, `resolving`, `cleared`;
/// `outcome`: `fixed`, `needs_you`, `cant_fix`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WatchIssue {
    pub id: String,
    pub watcher: String,
    pub key: String,
    pub job_id: Option<String>,
    pub project_id: String,
    pub title: String,
    pub details: String,
    pub url: String,
    pub folder: Option<String>,
    pub state: String,
    /// The debugging run that took it.
    pub taken_run_id: Option<String>,
    /// That run's todo (its conversation).
    pub todo_id: Option<String>,
    pub outcome: Option<String>,
    pub outcome_note: Option<String>,
    pub resolve_error: Option<String>,
    pub first_seen: String,
    pub last_seen: String,
    pub cleared_at: Option<String>,
    pub updated_at: String,
    /// The branch of the conversation that took it (where a fix is committed).
    #[serde(default)]
    pub branch: Option<String>,
    /// That conversation's folder (its worktree).
    #[serde(default)]
    pub worktree: Option<String>,
    /// The fix's commits, as the agent reported them.
    #[serde(default)]
    pub commits: Vec<String>,
}

/// A ready-made job plugin (`ai-session-remote/jobs/<name>`), as a computer reported it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobTemplate {
    pub name: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    pub cron: String,
    #[serde(default = "default_tool")]
    pub tool: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default = "default_priority")]
    pub priority: String,
    #[serde(default = "default_limit")]
    pub limit: String,
    /// `choose`, or a project name as the default.
    #[serde(default = "default_project")]
    pub project: String,
    #[serde(default)]
    pub prompt: String,
    /// The computer that reported it (filled in by the hub's list).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub computer_id: Option<String>,
}

fn default_tool() -> String {
    "claude".into()
}
fn default_priority() -> String {
    "background".into()
}
fn default_limit() -> String {
    "wait".into()
}
fn default_project() -> String {
    "choose".into()
}

/// A watcher installed on a computer, from its manifest; settings say only whether they are set.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WatcherInfo {
    pub name: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub settings: Vec<WatcherSetting>,
    #[serde(default)]
    pub resolve: bool,
    #[serde(default)]
    pub resolve_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WatcherSetting {
    pub key: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub secret: bool,
    #[serde(default)]
    pub set: bool,
    /// The watcher works without it (a default, or an extra).
    #[serde(default)]
    pub optional: bool,
}

/// An idea on a project: `new`, `researching`, `researched` or `dropped`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Idea {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub notes: String,
    pub status: String,
    pub starred: bool,
    /// Proposed by an agent; waits for the user's OK and is never researched before.
    pub pending: bool,
    pub findings: Option<String>,
    /// The research todo, or the todo it was turned into.
    pub todo_id: Option<String>,
    pub run_id: Option<String>,
    /// `manual` or `agent`
    pub source: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateIdeaRequest {
    pub project_id: String,
    pub title: String,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub pending: Option<bool>,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateIdeaRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub starred: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub findings: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JobRun {
    pub id: String,
    pub job_id: String,
    pub due_at: String,
    /// `due`, `waiting`, `running`, `done`, `failed`, `skipped` or `missed`
    pub state: String,
    pub computer_id: Option<String>,
    pub todo_id: Option<String>,
    pub waiting_reason: Option<String>,
    pub result: Option<String>,
    pub started_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    /// Extra text for this run's prompt (`{note}`), e.g. the hint of "shape an idea".
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub trigger: JobTrigger,
    pub action: JobAction,
    pub max_runs_per_day: u32,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub last_run: Option<JobRun>,
    /// Next cron fire time (RFC 3339 UTC); `None` for manual or disabled jobs.
    #[serde(default)]
    pub next_fire_at: Option<String>,
    /// The schedule in plain words ("Weekdays at 09:00", "Manual").
    #[serde(default)]
    pub schedule_text: Option<String>,
}

/// A run with its job's name, for the list of recent runs across jobs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecentRun {
    #[serde(flatten)]
    pub run: JobRun,
    pub job_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateJobRequest {
    pub name: String,
    #[serde(default)]
    pub enabled: Option<bool>,
    pub trigger: JobTrigger,
    pub action: JobAction,
    #[serde(default)]
    pub max_runs_per_day: Option<u32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateJobRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger: Option<JobTrigger>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<JobAction>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_runs_per_day: Option<u32>,
}

/// Global limit-guard settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SchedulerSettings {
    pub five_hour: u8,
    pub weekly: u8,
    pub pause_waiting: bool,
}

/// One run line in a weekly jobs snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyRunLine {
    pub run_id: String,
    pub due_at: String,
    pub state: String,
    pub outcome: String,
    pub todo_id: Option<String>,
}

/// One job's week: its tallies and the runs still present.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyJob {
    pub job_id: String,
    pub name: String,
    pub project_name: String,
    pub is_watch: bool,
    pub runs: u32,
    pub done: u32,
    pub failed: u32,
    pub skipped: u32,
    pub checks: u32,
    pub findings: u32,
    pub lines: Vec<WeeklyRunLine>,
}

/// The scheduled jobs' week, stored as the weekly snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyJobs {
    pub runs: u32,
    pub done: u32,
    pub failed: u32,
    pub skipped: u32,
    pub todos_created: u32,
    pub conversations_started: u32,
    pub findings: u32,
    pub jobs: Vec<WeeklyJob>,
}

/// Totals across one week's sections and the scheduled jobs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct WeeklyTotals {
    pub commits: u32,
    pub conversations: u32,
    pub runs: u32,
}

/// One day of a project's week: `update`, `quiet`, `failed`, `missing` or `untracked`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WeeklyDayState {
    pub day: String,
    pub state: String,
}

/// One project's recap for a week.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklySection {
    pub project_id: String,
    pub project_name: String,
    pub headline: String,
    pub wins: String,
    pub failed: bool,
    pub rewriting: bool,
    pub commits: u32,
    pub conversations: u32,
    pub days_with_work: u32,
    pub days: Vec<WeeklyDayState>,
    pub written_at: String,
}

/// A finished week as the apps list it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyRecap {
    pub week: String,
    pub totals: WeeklyTotals,
    pub sections: Vec<WeeklySection>,
    pub jobs: Option<WeeklyJobs>,
}

// --- Reviews ---------------------------------------------------------------------------

/// Tokens and cost of one reviewer run, as far as its tool reported them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ReviewUsage {
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub cache_read_tokens: Option<i64>,
    #[serde(default)]
    pub cache_write_tokens: Option<i64>,
    #[serde(default)]
    pub cost_usd: Option<f64>,
}

/// One reviewer agent run on a conversation's changes. The app runs it on the computer and
/// records it here; the hub only stores it. Times the app sets are ISO 8601 as it sent them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Review {
    pub id: String,
    pub conversation_id: String,
    /// `claude` or `codex`
    pub tool: String,
    #[serde(default)]
    pub model: Option<String>,
    /// The review window's scope: uncommitted, conversation, branch, since, commit.
    pub scope: String,
    pub base_sha: String,
    pub reviewed_sha: String,
    /// `running`, `done`, `failed` or `cancelled`
    pub state: String,
    pub started_at: String,
    #[serde(default)]
    pub finished_at: Option<String>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub usage: Option<ReviewUsage>,
    #[serde(default)]
    pub finding_count: Option<i64>,
    #[serde(default)]
    pub added_count: Option<i64>,
    /// Set by the hub.
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}

/// A comment on a conversation's changes: the user's own (`author` = `user`) or a
/// reviewer's finding (`reviewer:<tool>`). Its lines are in `path` as it is at `revision`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReviewItem {
    pub id: String,
    /// The run it came from (findings only).
    #[serde(default)]
    pub review_id: Option<String>,
    pub conversation_id: String,
    pub author: String,
    #[serde(default)]
    pub fingerprint: Option<String>,
    #[serde(default)]
    pub severity: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    pub path: String,
    /// `new` or `old`
    pub side: String,
    #[serde(default)]
    pub line_start: Option<i64>,
    #[serde(default)]
    pub line_end: Option<i64>,
    pub revision: String,
    #[serde(default)]
    pub quote: Vec<String>,
    pub body: String,
    /// `new` (a finding nobody acted on), `draft`, `sent`, `addressed`, `stale`, `dismissed`
    pub state: String,
    #[serde(default)]
    pub sent_at: Option<String>,
    /// The conversation's status revision when it was sent: a later idle turn is the answer.
    #[serde(default)]
    pub sent_in_turn: Option<i64>,
    /// The "Send to agent" it went out in, and the worktree revision then.
    #[serde(default)]
    pub batch_id: Option<String>,
    #[serde(default)]
    pub sent_revision: Option<String>,
    pub created_at: String,
    /// Set by the hub.
    #[serde(default)]
    pub updated_at: String,
}

/// Everything about one conversation's review: `GET /api/reviews?conversation_id=`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ReviewRecord {
    pub reviews: Vec<Review>,
    pub items: Vec<ReviewItem>,
}

/// `POST /api/reviews/batch`: upserts (by id, whole rows) and deletes in one transaction.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ReviewBatchRequest {
    #[serde(default)]
    pub reviews: Vec<Review>,
    #[serde(default)]
    pub items: Vec<ReviewItem>,
    #[serde(default)]
    pub delete_reviews: Vec<String>,
    #[serde(default)]
    pub delete_items: Vec<String>,
}

/// `PATCH /api/review-items/{id}`: what the phone changes (Send, Dismiss) and edits.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UpdateReviewItemRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_in_turn: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_revision: Option<String>,
    /// Applied only while the item is still in this state; else 409 (another device acted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_state: Option<String>,
    /// Clears sent_at, sent_in_turn, batch_id and sent_revision (a send that didn't go out).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clear_sent: Option<bool>,
}

/// A conversation's review at a glance, for its row: `GET /api/reviews/summary`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReviewSummary {
    pub conversation_id: String,
    /// Findings and comments not sent or dismissed yet (`new` or `draft`).
    pub open: i64,
    /// A reviewer run is going (one started in the last 45 minutes, not finished).
    pub reviewing: bool,
    /// When the last finished run started, ISO 8601 as the app sent it.
    #[serde(default)]
    pub last_reviewed_at: Option<String>,
}

#[cfg(test)]
mod tests {
    #[test]
    fn watch_action_round_trips_json() {
        let json = r#"{"kind":"watch","project_id":"p","computer_id":"c","watcher":"sentry","debug_tool":"claude","prompt":""}"#;
        let action: JobAction = serde_json::from_str(json).unwrap();
        assert_eq!(serde_json::to_string(&action).unwrap(), json);
        assert!(action.conversation_parts().is_none());
        assert!(action.is_watch());
        let report: WatchReport = serde_json::from_str(r#"{"problems":[{"key":"k","title":"t"}]}"#).unwrap();
        assert!(!report.partial);
        assert_eq!((report.problems[0].details.as_str(), report.problems[0].folder.as_deref()), ("", None));
    }

    #[test]
    fn research_action_round_trips_json() {
        let json = r#"{"kind":"research","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"","priority":"background","limit":{"mode":"always"}}"#;
        let action: JobAction = serde_json::from_str(json).unwrap();
        assert_eq!(serde_json::to_string(&action).unwrap(), json);
        let parts = action.conversation_parts().unwrap();
        assert_eq!((parts.project_id, parts.tool, parts.prompt), ("p", "claude", ""));
        let push = JobAction::Push { title: "t".into(), body: "b".into() };
        assert!(push.conversation_parts().is_none());
    }

    #[test]
    fn job_action_round_trips_json() {
        let json = r#"{"kind":"conversation","project_id":"p","computer_id":null,"tool":"claude","folder":null,"prompt":"x","priority":"background","limit":{"mode":"wait","five_hour":40,"weekly":null}}"#;
        let action: JobAction = serde_json::from_str(json).unwrap();
        match &action {
            JobAction::Conversation { project_id, priority, limit, .. } => {
                assert_eq!(project_id, "p");
                assert_eq!(*priority, Priority::Background);
                assert_eq!(*limit, LimitSetting::Wait { five_hour: Some(40), weekly: None });
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(serde_json::to_string(&action).unwrap(), json);
        let trigger: JobTrigger = serde_json::from_str(r#"{"kind":"cron","cron":"0 8 * * *"}"#).unwrap();
        assert_eq!(trigger, JobTrigger::Cron { cron: "0 8 * * *".into() });
        assert_eq!(serde_json::to_string(&JobTrigger::Manual).unwrap(), r#"{"kind":"manual"}"#);
    }

    use super::*;

    fn todo() -> Todo {
        Todo {
            id: "t".into(),
            section: Section::P,
            title: "x".into(),
            completed: false,
            on_hold: false,
            importance: Importance::Medium,
            due_date: None,
            daily_date: None,
            carried_from: None,
            created_at: "c".into(),
            updated_at: "u".into(),
            completed_at: None,
            conversation_status: None,
            project_id: None,
            scheduled_job_id: None,
            scheduled_run_id: None,
        }
    }

    #[test]
    fn todo_without_project_omits_field() {
        let json = serde_json::to_value(todo()).unwrap();
        assert!(json.get("project_id").is_none(), "{json}");
        let with = Todo { project_id: Some("p1".into()), ..todo() };
        assert_eq!(serde_json::to_value(with).unwrap()["project_id"], "p1");
        // JSON from an older server (no project_id) still decodes.
        let old = r#"{"id":"t","section":"P","title":"x","completed":false,"importance":"low","due_date":null,
                      "created_at":"c","updated_at":"u","completed_at":null}"#;
        assert_eq!(serde_json::from_str::<Todo>(old).unwrap().project_id, None);
        assert!(!serde_json::from_str::<Todo>(old).unwrap().on_hold);
    }

    #[test]
    fn update_todo_project_null_vs_absent() {
        let clear: UpdateTodoRequest = serde_json::from_str(r#"{"project_id":null}"#).unwrap();
        assert_eq!(clear.project_id, Some(None));
        let set: UpdateTodoRequest = serde_json::from_str(r#"{"project_id":"p1"}"#).unwrap();
        assert_eq!(set.project_id, Some(Some("p1".into())));
        let absent: UpdateTodoRequest = serde_json::from_str("{}").unwrap();
        assert_eq!(absent.project_id, None);
        // due_date follows the same rule: null clears, absent leaves it.
        let clear: UpdateTodoRequest = serde_json::from_str(r#"{"due_date":null}"#).unwrap();
        assert_eq!(clear.due_date, Some(None));
        // Serializing keeps the distinction for clients built on these types.
        let req = UpdateTodoRequest { project_id: Some(None), ..Default::default() };
        assert_eq!(serde_json::to_string(&req).unwrap(), r#"{"project_id":null}"#);
        assert_eq!(serde_json::to_string(&UpdateTodoRequest::default()).unwrap(), "{}");
    }

    #[test]
    fn old_requests_still_deserialize() {
        let create: CreateTodoRequest = serde_json::from_str(r#"{"section":"P","title":"x"}"#).unwrap();
        assert_eq!(create.project_id, None);
        let conv = r#"{"todo_id":"t","computer":{"id":"m","name":"n","hostname":"h","port":22,"username":"u",
            "created_at":"c","updated_at":"u"},"cwd":"~","tool":"claude","tmux_name":"x","session_id":"s",
            "claude_session_id":"s","status":"idle","status_message":null,"status_updated_at":null,"created_at":"c"}"#;
        let conv: Conversation = serde_json::from_str(conv).unwrap();
        assert_eq!(conv.project_id, None);
        assert!(serde_json::to_value(&conv).unwrap().get("project_id").is_none());
    }

    #[test]
    fn spec_samples_decode() {
        let upload = r#"{"computer_id":"78e7","sessions":[{"tool":"claude","session_id":"s1","cwd":"~/programming/todo-app",
            "title":"Add projects","repo_root":"~/programming/todo-app","repo_url":"git@github.com:tsetsoo/todo-app.git",
            "stats":{"prompts":12,"assistant_turns":12,"input_tokens":4021,"output_tokens":51234,
                     "cache_read_tokens":9123456,"cache_creation_tokens":402311,"active_seconds":5400,
                     "first_activity":"2026-10-16T07:01:12Z","last_activity":"2026-10-16T09:12:03Z",
                     "files_touched":["crates/todo-server/src/db.rs"],"models":["claude-opus-5-5"]},
            "days":[{"day":"2026-10-16","prompts":12,"assistant_turns":12,"input_tokens":4021,"output_tokens":51234,
                     "cache_read_tokens":9123456,"cache_creation_tokens":402311,"active_seconds":5400,"files_touched":1}]}]}"#;
        let upload: SessionStatsUpload = serde_json::from_str(upload).unwrap();
        assert_eq!(upload.sessions[0].stats.cache_creation_tokens, Some(402_311));
        assert_eq!(upload.sessions[0].days[0].files_touched, 1);

        let bulk = r#"{"computer_id":"m","tool":"claude","session_id":"s","cwd":"~/x",
            "memories":[{"kind":"open_thread","text":"Check it.","files":["a"],"confidence":0.85,"supersedes":["id1"]}]}"#;
        let bulk: BulkMemoriesRequest = serde_json::from_str(bulk).unwrap();
        assert_eq!(bulk.memories[0].kind, MemoryKind::OpenThread);
        assert!(serde_json::from_str::<NewMemory>(r#"{"kind":"idea","text":"x","confidence":1}"#).is_err());

        let auto: SetSessionProjectRequest = serde_json::from_str(r#"{"auto":true}"#).unwrap();
        assert_eq!((auto.auto, auto.project_id), (Some(true), None));
        let none: SetSessionProjectRequest = serde_json::from_str(r#"{"project_id":null}"#).unwrap();
        assert_eq!(none.project_id, Some(None));

        let patch: UpdateMemoryRequest = serde_json::from_str(r#"{"todo_id":null,"pinned":true}"#).unwrap();
        assert_eq!((patch.todo_id, patch.project_id, patch.pinned), (Some(None), None, Some(true)));
        let patch: UpdateProjectRequest = serde_json::from_str(r#"{"repo_url":null}"#).unwrap();
        assert_eq!(patch.repo_url, Some(None));
    }

    #[test]
    fn rollups_flatten_counters() {
        let rollup = ProjectRollup { project_id: None, name: None, counters: StatsCounters::default(), workers: StatsCounters::default() };
        let json = serde_json::to_value(rollup).unwrap();
        assert!(json["project_id"].is_null() && json["name"].is_null());
        assert_eq!(json["sessions"], 0);
        assert!(json["input_tokens"].is_null());
        let section = SectionRollup { section: Some(Section::Sp), counters: StatsCounters::default(), workers: StatsCounters::default() };
        assert_eq!(serde_json::to_value(section).unwrap()["section"], "Sp");
    }

    #[test]
    fn push_settings_update_defaults_omitted_fields() {
        let u: PushSettingsUpdate = serde_json::from_str(r#"{"muted_sections":["P"]}"#).unwrap();
        assert!(u.notify_waiting);
        assert_eq!(u.grace_seconds, DEFAULT_PUSH_GRACE_SECONDS);
        assert_eq!(u.muted_sections, vec![Section::P]);
        let d: PushDeviceRequest = serde_json::from_str(
            r#"{"token":"ab","platform":"ios","environment":"sandbox","bundle_id":"b","app_version":"1"}"#,
        )
        .unwrap();
        assert_eq!((d.platform, d.environment, d.device_name), (PushPlatform::Ios, ApnsEnvironment::Sandbox, None));
        let s: ConversationStatusRequest = serde_json::from_str(r#"{"session_id":"a","status":"waiting","attended":true}"#).unwrap();
        assert_eq!(s.attended, Some(true));
    }
}
