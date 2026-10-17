#if DEBUG
import Foundation

/// Canned terminal for `-uiDemo -uiDemoScreen terminal`: paints a Claude Code permission prompt
/// and ignores input. Never touches the network.
final class DemoTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?

    func connect(cols: Int, rows: Int) async throws {
        onOutput?(Array(Self.screen.utf8))
    }

    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}

    private static let screen: String = {
        let esc = "\u{1B}["
        let reset = "\(esc)0m"
        let green = "\(esc)32m"
        let dim = "\(esc)2m"
        let bold = "\(esc)1m"
        let orange = "\(esc)38;5;208m"
        let hi = "\(esc)1;38;5;208m"
        let width = 58
        func row(_ text: String, styled: String? = nil) -> String {
            let pad = String(repeating: " ", count: max(0, width - 1 - text.count))
            return "\(orange)│\(reset) \(styled ?? text)\(pad)\(orange)│\(reset)"
        }
        let top = "\(orange)╭\(String(repeating: "─", count: width))╮\(reset)"
        let bottom = "\(orange)╰\(String(repeating: "─", count: width))╯\(reset)"
        let lines: [String] = [
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
            top,
            row("Bash command", styled: "\(bold)Bash command\(reset)"),
            row(""),
            row("  cargo test import::rates"),
            row("  Run the importer tests", styled: "  \(dim)Run the importer tests\(reset)"),
            row(""),
            row("Do you want to proceed?"),
            row("❯ 1. Yes", styled: "\(hi)❯ 1. Yes\(reset)"),
            row("  2. Yes, and don't ask again for cargo test commands"),
            row("  3. No, and tell Claude what to do differently (esc)"),
            bottom,
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }()
}
#endif
