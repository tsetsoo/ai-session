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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionComputer {
    pub section: Section,
    pub computer: Computer,
    /// Default working directory for new conversations (may start with ~)
    pub cwd: String,
    pub tool: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SetSectionComputerRequest {
    pub computer_id: String,
    pub cwd: String,
    #[serde(default)]
    pub tool: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Conversation {
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
    pub created_at: String,
    /// The conversation's project: its session's project, or matched from computer + cwd
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
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
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SectionRollup {
    pub section: Option<Section>,
    #[serde(flatten)]
    pub counters: StatsCounters,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ComputerRollup {
    pub computer_id: String,
    pub name: String,
    #[serde(flatten)]
    pub counters: StatsCounters,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WeeklyStats {
    /// Monday, YYYY-MM-DD
    pub week_start: String,
    /// Sunday, YYYY-MM-DD
    pub week_end: String,
    pub totals: StatsCounters,
    pub by_project: Vec<ProjectRollup>,
    pub by_section: Vec<SectionRollup>,
    pub by_computer: Vec<ComputerRollup>,
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
    /// `extracted` or `manual`
    pub source: String,
    pub pinned: bool,
    pub archived: bool,
    pub created_at: String,
    pub updated_at: String,
}

/// A manual memory from the app. At least one of `project_id` / `todo_id` is required.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn todo() -> Todo {
        Todo {
            id: "t".into(),
            section: Section::P,
            title: "x".into(),
            completed: false,
            importance: Importance::Medium,
            due_date: None,
            daily_date: None,
            carried_from: None,
            created_at: "c".into(),
            updated_at: "u".into(),
            completed_at: None,
            conversation_status: None,
            project_id: None,
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
        let rollup = ProjectRollup { project_id: None, name: None, counters: StatsCounters::default() };
        let json = serde_json::to_value(rollup).unwrap();
        assert!(json["project_id"].is_null() && json["name"].is_null());
        assert_eq!(json["sessions"], 0);
        assert!(json["input_tokens"].is_null());
        let section = SectionRollup { section: Some(Section::Sp), counters: StatsCounters::default() };
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
