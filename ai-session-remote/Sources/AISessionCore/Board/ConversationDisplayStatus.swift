/// What the UI shows for a conversation: the hub status, overridden by whether its tmux session lives.
public enum ConversationDisplayStatus: Equatable, Sendable {
    case working, needsYou, idle, ready, closed

    /// `tmuxAlive == false` means the computer was reachable and the session is gone, so it is
    /// closed whatever the hub last said. `nil` means unknown: trust the hub.
    public init(_ status: ConversationStatus, tmuxAlive: Bool?, reviewed: Bool = false) {
        if tmuxAlive == false {
            self = .closed
            return
        }
        switch status {
        case .busy: self = .working
        case .waiting: self = .needsYou
        case .idle: self = reviewed ? .ready : .idle
        case .unknown: self = .ready
        case .closed: self = .closed
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .idle: return "Ready for review"
        case .ready: return "Ready"
        case .closed: return "Closed"
        }
    }
}
