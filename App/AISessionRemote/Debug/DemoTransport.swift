#if DEBUG
import Foundation

/// Canned terminal for `-uiDemo -uiDemoScreen terminal`: paints a Claude Code permission prompt
/// and ignores input. Never touches the network.
final class DemoTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?

    func connect(cols: Int, rows: Int) async throws {
        onOutput?(Array(Self.screen(cols: cols).utf8))
    }

    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}

    /// Word-wraps `text` to `width` columns. Continuation lines keep the first line's leading
    /// spaces plus `hang` more, the way Claude Code indents a wrapped option.
    private static func wrap(_ text: String, width: Int, hang: Int = 0) -> [String] {
        let lead = String(text.prefix { $0 == " " })
        let indent = lead + String(repeating: " ", count: hang)
        var lines: [String] = []
        var line = lead
        for word in text.dropFirst(lead.count).split(separator: " ") {
            let start = lines.isEmpty ? lead : indent
            if line == start {
                line = String((line + word).prefix(width))
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String((indent + word).prefix(width))
            }
        }
        lines.append(line)
        return lines
    }

    /// The canned screen, with the permission box laid out to the terminal's width (at most 62
    /// columns, like Claude's own box on a wide terminal).
    private static func screen(cols: Int) -> String {
        let esc = "\u{1B}["
        let reset = "\(esc)0m"
        let green = "\(esc)32m"
        let dim = "\(esc)2m"
        let bold = "\(esc)1m"
        let orange = "\(esc)38;5;208m"
        let hi = "\(esc)1;38;5;208m"
        let boxWidth = max(20, min(cols, 62))
        // "│ " + content + " │"
        let content = boxWidth - 4
        func row(_ text: String, style: String? = nil, hang: Int = 0) -> [String] {
            wrap(text, width: content, hang: hang).map { line in
                let pad = String(repeating: " ", count: max(0, content - line.count))
                let body = style.map { "\($0)\(line)\(reset)" } ?? line
                return "\(orange)│\(reset) \(body)\(pad) \(orange)│\(reset)"
            }
        }
        let rule = String(repeating: "─", count: boxWidth - 2)
        var lines: [String] = [
            "\(bold)>\(reset) Fix the rate import so it skips empty rows from the CSV",
            "",
            "\(green)⏺\(reset) I'll look at the importer first.",
            "",
            "\(green)⏺\(reset) \(bold)Read\(reset)(src/import/rates.rs)",
            "  \(dim)⎿  Read 214 lines\(reset)",
            "",
            "\(green)⏺\(reset) \(bold)Update\(reset)(src/import/rates.rs)",
            "  \(dim)⎿  Updated src/import/rates.rs with 6 additions and 1 removal\(reset)",
            "",
            "\(orange)╭\(rule)╮\(reset)",
        ]
        lines += row("Bash command", style: bold)
        lines += row("")
        lines += row("  cargo test import::rates")
        lines += row("  Run the importer tests", style: dim)
        lines += row("")
        lines += row("Do you want to proceed?")
        lines += row("❯ 1. Yes", style: hi)
        lines += row("  2. Yes, and don't ask again for cargo test commands", hang: 3)
        lines += row("  3. No, and tell Claude what to do differently (esc)", hang: 3)
        lines.append("\(orange)╰\(rule)╯\(reset)")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
#endif
