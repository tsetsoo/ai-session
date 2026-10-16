use serde::{Deserialize, Serialize};

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
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CreateTodoRequest {
    pub section: Section,
    pub title: String,
    #[serde(default)]
    pub importance: Option<Importance>,
    #[serde(default)]
    pub due_date: Option<String>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_date: Option<Option<String>>,
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
