/// Keys on the terminal accessory bar, with the bytes each tool expects.
public enum TerminalKey: CaseIterable, Sendable {
    case esc, tab, left, up, down, right, shiftEnter, approve

    public func bytes(tool: String) -> [UInt8] {
        let codex = tool == "codex"
        switch self {
        case .esc: return [0x1B]
        case .tab: return [0x09]
        case .left: return [0x1B, 0x5B, 0x44]
        case .up: return [0x1B, 0x5B, 0x41]
        case .down: return [0x1B, 0x5B, 0x42]
        case .right: return [0x1B, 0x5B, 0x43]
        case .shiftEnter: return codex ? [0x0A] : [0x1B, 0x0D]
        case .approve: return codex ? [0x79] : [0x31]   // "y" / "1"
        }
    }
}

/// Claude's approve sends "1", which would land in the prompt if the user has started typing, so
/// it is only enabled from a fresh `waiting` until the user types. Codex's "y" is always safe.
public struct ApproveGate: Sendable {
    private var armed = false
    private var last: ConversationStatus?

    public init() {}

    public mutating func statusChanged(to status: ConversationStatus) {
        if status != .waiting { armed = false }
        else if last != .waiting { armed = true }
        last = status
    }

    public mutating func userTyped() { armed = false }

    /// Armed by a fresh `waiting` and not typed into since. Callers check it before
    /// `userTyped()` so a keystroke doesn't write their state when there is nothing to disarm.
    public var isArmed: Bool { armed }

    public func isEnabled(tool: String) -> Bool {
        tool == "codex" || armed
    }
}

/// Switching to a conversation that is waiting on the user lands keyboard focus in its terminal
/// once it connects, on the Mac too, where focus would otherwise stay in the list. Other
/// conversations keep the terminal's own focus-after-connect.
public struct WaitingFocus: Sendable {
    private var armed = false

    public init() {}

    /// The frame's terminal area turned into a terminal (`isReady`) or away from one. `status`
    /// is the conversation's status at that moment (`nil`: unknown).
    public mutating func readyChanged(isReady: Bool, status: ConversationStatus?) {
        armed = isReady && status == .waiting
    }

    /// The terminal connected. True once per ready-while-waiting: focus the terminal now.
    public mutating func connected() -> Bool {
        defer { armed = false }
        return armed
    }
}
