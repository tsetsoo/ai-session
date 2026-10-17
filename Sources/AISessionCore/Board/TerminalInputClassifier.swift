/// Tells what the user typed apart from what the terminal answers on its own. A terminal view
/// sends both through the same channel: keystrokes, and its replies to queries from the host
/// (device attributes, status and cursor reports, focus and mouse reports, and the colour,
/// version and mode replies tmux asks for when a client attaches).
public enum TerminalInputClassifier {
    private static let esc: UInt8 = 0x1B
    private static let csi: UInt8 = 0x5B        // [
    private static let osc: UInt8 = 0x5D        // ]
    private static let dcs: UInt8 = 0x50        // P
    private static let bel: UInt8 = 0x07
    private static let stFinal: UInt8 = 0x5C    // \ (ST is ESC \)

    /// Final bytes of CSI replies: DA (`c`), DSR (`n`), cursor position (`R`), window reports
    /// (`t`), DECRPM (`$y`) and SGR/URXVT mouse (`M`/`m`).
    private static let replyFinals: Set<UInt8> = Set("cnRtyMm".utf8)

    /// True when `bytes` is a reply the terminal generated rather than input from the user.
    public static func isTerminalReport(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3, bytes[0] == esc else { return false }
        switch bytes[1] {
        case csi: return isCSIReply(bytes)
        case osc: return endsWithStringTerminator(bytes, allowsBEL: true)
        case dcs: return endsWithStringTerminator(bytes, allowsBEL: false)
        default: return false
        }
    }

    private static func isCSIReply(_ bytes: [UInt8]) -> Bool {
        let body = bytes.dropFirst(2)
        // Focus in/out.
        if body.count == 1, body.first == UInt8(ascii: "I") || body.first == UInt8(ascii: "O") {
            return true
        }
        // X10 mouse: `ESC [ M` and three raw bytes (button, column, row).
        if body.first == UInt8(ascii: "M") {
            return body.count == 4
        }
        guard let final = body.last, replyFinals.contains(final), body.count >= 2 else { return false }
        // Parameter bytes (0x30–0x3F: digits ; < = > ?) then intermediates (0x20–0x2F, e.g. `$`).
        var sawIntermediate = false
        for byte in body.dropLast() {
            switch byte {
            case 0x30...0x3F where !sawIntermediate: continue
            case 0x20...0x2F: sawIntermediate = true
            default: return false
            }
        }
        return true
    }

    private static func endsWithStringTerminator(_ bytes: [UInt8], allowsBEL: Bool) -> Bool {
        if allowsBEL, bytes.last == bel { return true }
        return bytes.count >= 4 && bytes[bytes.count - 2] == esc && bytes.last == stFinal
    }
}
