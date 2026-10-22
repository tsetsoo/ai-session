/// Text the app types into a terminal on the user's behalf (Paste, a duplicate's hand-off).
/// When the program in the terminal has bracketed paste on (`ESC[?2004h`), the text goes
/// between `ESC[200~` and `ESC[201~`, as SwiftTerm's own paste does. The program then takes
/// newlines inside it as part of the text instead of as Return.
public enum TerminalPaste {
    public static let start: [UInt8] = Array("\u{1B}[200~".utf8)
    public static let end: [UInt8] = Array("\u{1B}[201~".utf8)

    /// `text` as pasted. An end marker inside the text is dropped, so it can't end the paste
    /// early and have the rest read as typed keys.
    public static func bytes(for text: String, bracketed: Bool) -> [UInt8] {
        guard bracketed else { return Array(text.utf8) }
        let body = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
        return start + Array(body.utf8) + end
    }

    /// `text` pasted and then sent with Return. Bracketed, the Return goes after the end
    /// marker, or it would only add a line. Unbracketed, a trailing newline submits it.
    public static func submission(_ text: String, bracketed: Bool) -> [UInt8] {
        guard bracketed else {
            return Array((text.hasSuffix("\n") ? text : text + "\n").utf8)
        }
        var body = Substring(text)
        while let last = body.last, last.isNewline { body = body.dropLast() }
        return bytes(for: String(body), bracketed: true) + [0x0D]
    }
}
