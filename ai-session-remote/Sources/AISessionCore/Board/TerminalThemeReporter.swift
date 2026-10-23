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
/// Send `pendingNotice()` only while SwiftTerm is being fed, because tmux follows the notice
/// with colour queries that SwiftTerm has to answer.
public struct TerminalThemeReporter {
    public enum Theme: Equatable {
        case light, dark
    }

    public private(set) var theme: Theme
    private var subscribed = false
    /// The theme the host last heard, by reply or notice.
    private var reported: Theme?
    private var scanner = TerminalEscapeScanner()

    public init(theme: Theme) {
        self.theme = theme
    }

    /// Returns the replies to any theme queries in `bytes`, for the host.
    public mutating func scan(_ bytes: [UInt8]) -> [UInt8] {
        var replies: [UInt8] = []
        for byte in bytes {
            switch scanner.step(byte) {
            case .escape(0x63)?: // c: RIS clears modes, the subscription with them
                subscribed = false
            case .csi(let csi)?:
                handle(csi, replies: &replies)
            default:
                break
            }
        }
        return replies
    }

    private mutating func handle(_ csi: TerminalEscapeScanner.CSI, replies: inout [UInt8]) {
        switch (csi.final, csi.marker, csi.intermediate) {
        case (0x6E, 0x3F, nil): // ? … n
            guard csi.numbers == [996] else { return }
            replies += report
            reported = theme
        case (0x68, 0x3F, nil), (0x6C, 0x3F, nil): // ? … h, ? … l
            guard csi.numbers.contains(2031) else { return }
            subscribed = csi.final == 0x68
        case (0x70, nil, 0x21): // ! p: DECSTR
            subscribed = false
        default:
            break
        }
    }

    /// Records the palette's theme. Send the change with `pendingNotice()`.
    public mutating func setTheme(_ theme: Theme) {
        self.theme = theme
    }

    /// The change notice, if the host subscribed and last heard a different theme.
    public mutating func pendingNotice() -> [UInt8]? {
        guard subscribed, reported != theme else { return nil }
        reported = theme
        return report
    }

    /// Forgets the subscription, for a new session on the same terminal.
    public mutating func reset() {
        self = TerminalThemeReporter(theme: theme)
    }

    private var report: [UInt8] {
        Array("\u{1B}[?997;\(theme == .dark ? 1 : 2)n".utf8)
    }
}
