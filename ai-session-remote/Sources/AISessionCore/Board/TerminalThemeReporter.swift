/// Answers tmux's questions about whether the terminal is light or dark, and tells it when that
/// changes (the `CSI ? 2031` colour-scheme protocol, which SwiftTerm doesn't implement).
///
/// tmux asks the terminal for its colours once when it attaches and answers programs from that
/// copy. Without updates, a Codex started after the app switched themes is told the old
/// background and tints its message blocks for it. tmux subscribes with `CSI ? 2031 h` and
/// asks with `CSI ? 996 n`. The reply, and the notice sent on a change, is `CSI ? 997 ; 1 n`
/// for dark or `CSI ? 997 ; 2 n` for light. On a notice tmux asks for the colours again, which
/// SwiftTerm answers from the palette.
///
/// Feed every output chunk through `scan(_:)` in order and send what it returns to the host.
public struct TerminalThemeReporter {
    public enum Theme: Equatable {
        case light, dark
    }

    public private(set) var theme: Theme
    private var subscribed = false
    private var scanner = TerminalEscapeScanner()

    public init(theme: Theme) {
        self.theme = theme
    }

    /// Returns the replies to any theme queries in `bytes`, for the host.
    public mutating func scan(_ bytes: [UInt8]) -> [UInt8] {
        var replies: [UInt8] = []
        for byte in bytes {
            guard case .csi(let csi)? = scanner.step(byte), csi.marker == 0x3F,
                  csi.intermediate == nil else { continue }
            switch csi.final {
            case 0x6E where csi.numbers == [996]: // n
                replies += report
            case 0x68 where csi.numbers.contains(2031): // h
                subscribed = true
            case 0x6C where csi.numbers.contains(2031): // l
                subscribed = false
            default:
                break
            }
        }
        return replies
    }

    /// Records the theme. Returns the change notice for the host if the theme changed and the
    /// host subscribed.
    public mutating func setTheme(_ theme: Theme) -> [UInt8]? {
        guard theme != self.theme else { return nil }
        self.theme = theme
        return subscribed ? report : nil
    }

    /// Forgets the subscription, for a new session on the same terminal.
    public mutating func reset() {
        self = TerminalThemeReporter(theme: theme)
    }

    private var report: [UInt8] {
        Array("\u{1B}[?997;\(theme == .dark ? 1 : 2)n".utf8)
    }
}
