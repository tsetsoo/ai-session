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
