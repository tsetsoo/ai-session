import Foundation

/// One todo, several conversations (agents trying the same task, or added from each other):
/// which get a tab in the switcher, how they're named, the note for closed attempts, the
/// side-by-side grid, and which one the todo shows.
public enum ConversationSwitcherModel {
    /// The open conversations, oldest first: one tab each.
    public static func tabs(_ conversations: [Conversation]) -> [Conversation] {
        conversations.filter { $0.status != .closed }.sorted {
            ($0.createdAt, $0.listKey) < ($1.createdAt, $1.listKey)
        }
    }

    /// The switcher shows while two or more are open.
    public static func showsSwitcher(_ conversations: [Conversation]) -> Bool {
        tabs(conversations).count >= 2
    }

    /// With research attempts that failed to start (they have no open conversation), the
    /// switcher shows while there are two or more tabs in all.
    public static func showsSwitcher(_ conversations: [Conversation], failed: Int) -> Bool {
        tabs(conversations).count + failed >= 2
    }

    /// A research todo's attempts that failed or never started and get a place of their own
    /// (with Retry): those with no conversation, or whose conversation was closed when they failed.
    public static func failedAttempts(_ attempts: [IdeaAttempt], conversations: [Conversation]) -> [IdeaAttempt] {
        let open = Set(tabs(conversations).map(\.id))
        return attempts.filter { ResearchAgents.canRetry($0) && !($0.conversationId.map(open.contains) ?? false) }
    }

    /// `Codex · gpt-6.1`, or just `Claude` with its default model.
    public static func label(_ conversation: Conversation) -> String {
        let tool = conversation.tool.prefix(1).uppercased() + conversation.tool.dropFirst()
        guard let model = conversation.model, !model.isEmpty else { return tool }
        return "\(tool) · \(model)"
    }

    /// ✓ done, … working, ! needs you.
    public static func statusGlyph(_ status: ConversationStatus) -> String {
        switch status {
        case .idle: return "✓"
        case .busy: return "…"
        case .waiting: return "!"
        case .unknown, .closed: return ""
        }
    }

    /// After "Continue with this" (one open, others closed): the note that opens them again.
    public static func closedNote(_ conversations: [Conversation]) -> String? {
        guard tabs(conversations).count <= 1 else { return nil }
        let closed = conversations.filter { $0.status == .closed }
        switch closed.count {
        case 0: return nil
        case 1: return "\(label(closed[0]).components(separatedBy: " · ")[0]) attempt · closed"
        default: return "\(closed.count) other attempts · closed"
        }
    }

    /// Side by side: two columns from two conversations up (rows as needed).
    public static func gridColumns(_ count: Int) -> Int {
        count >= 2 ? 2 : max(count, 1)
    }

    /// `14 min`, `2 h 5 min` since the conversation started; nil without a start time.
    public static func elapsed(since createdAt: String, now: Date = Date()) -> String? {
        guard let start = HubDates.date(from: createdAt) else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The conversation the user continued with, while it is open.
    public static func preferred(_ conversations: [Conversation]) -> Conversation? {
        conversations.first { $0.main && $0.status != .closed }
    }

    /// The other open conversations still working: continuing with `chosen` asks first.
    public static func busyOthers(continuing chosen: Conversation, in conversations: [Conversation]) -> [Conversation] {
        conversations.filter { $0.listKey != chosen.listKey && $0.status == .busy }
    }

    // MARK: Side by side panes

    /// The conversation a frame acts on: a pane's own, else the todo's selected one, else
    /// the one its terminal shows.
    public static func frameConversation(pinned: Conversation?, displayed: Conversation?, ready: Conversation?) -> Conversation? {
        pinned ?? displayed ?? ready
    }

    /// The pane the column toolbar acts on: the selected tab, else the first.
    public static func toolbarKey(tabs: [Conversation], selectedKey: String?) -> String? {
        tabs.first { $0.listKey == selectedKey }?.listKey ?? tabs.first?.listKey
    }

    /// Only one pane is frontmost (its sheets, focus and toolbar state), and none while the
    /// todo isn't the one on screen.
    public static func paneIsFrontmost(screenFrontmost: Bool, suspended: Bool, paneKey: String, toolbarKey: String?) -> Bool {
        screenFrontmost && !suspended && paneKey == toolbarKey
    }

    /// A pane attaches an open conversation whose tool has started (it has an id).
    public static func paneCanAttach(_ conversation: Conversation) -> Bool {
        conversation.status != .closed && ConversationStart.hasStartedSession(conversation.sessionId)
    }
}
