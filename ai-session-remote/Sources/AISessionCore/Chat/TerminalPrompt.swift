import Foundation

/// A Claude or Codex question read off the terminal screen: a numbered menu with one option
/// marked by the cursor (❯ or ›) under a line ending in "?", and an Esc hint as the last line
/// (below the menu, or on its last option in older Claude's boxed prompt).
/// Fixtures in `TerminalPromptFixtures` are real captures; parse nothing they don't justify.
public struct TerminalPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        /// The indented line under an option (Claude's question descriptions).
        public let detail: String?
        /// Choosing it asks for words: "Type something", "No, and tell Codex what to do differently".
        public let needsText: Bool
        /// Claude's "Type something" takes the words while it is highlighted, before Enter.
        /// Other text options are chosen first and then ask for the words in the input box.
        public var typesInPlace: Bool { needsText && label.lowercased().hasPrefix("type something") }
    }

    public let question: String
    /// What the question is about: the command, file or diff summary above it.
    public let detail: String?
    public let options: [Option]
    /// The option the cursor is on now.
    public let selected: Int
    /// Tells two prompts apart, so an answer is only sent to the prompt it was meant for.
    public var signature: String { ([question] + options.map(\.label)).joined(separator: "\n") }

    /// Down or up from the current option to `index`, then Enter unless `enter` is false.
    public func keys(toChoose index: Int, tool: String, enter: Bool = true) -> [UInt8] {
        let key: TerminalKey = index > selected ? .down : .up
        let moves = Array(repeating: key.bytes(tool: tool), count: abs(index - selected)).flatMap { $0 }
        return moves + (enter ? TerminalKey.enter.bytes(tool: tool) : [])
    }

    public static func parse(screen: [String]) -> TerminalPrompt? {
        let lines = screen.map(clean)
        guard let hint = lines.lastIndex(where: { !$0.isEmpty && !isRule($0) }),
              lines[hint].range(of: #"(?i)\besc\b"#, options: .regularExpression) != nil
        else { return nil }
        // Where the menu ends: below the hint line, unless the hint is on the last option.
        let footer = optionLine(lines[hint]) == nil ? hint : hint + 1

        // Up from the hint to option 1: only options, their indented continuations, blanks and rules.
        var first: Int?
        var row = footer - 1
        while row >= 0 {
            let line = lines[row]
            if line.isEmpty || isRule(line) {
                row -= 1
                continue
            }
            if let option = optionLine(line) {
                if option.number == 1 { first = row; break }
            } else if indent(line) < 4 {
                return nil
            }
            row -= 1
        }
        guard let first else { return nil }

        let width = lines.map(\.count).max() ?? 0
        var parsed: [(number: Int, cursor: Bool, label: String, detail: String?, lastLine: String)] = []
        for line in lines[first..<footer] where !line.isEmpty && !isRule(line) {
            if let option = optionLine(line) {
                parsed.append((option.number, option.cursor, option.text, nil, line))
            } else if var last = parsed.popLast() {
                let text = line.trimmingCharacters(in: .whitespaces)
                if last.detail == nil, last.lastLine.count >= width - 4 {
                    // The label wrapped at the pane's edge.
                    let joiner = last.label.hasSuffix("-") || last.label.hasSuffix("/") ? "" : " "
                    last.label += joiner + text
                } else {
                    last.detail = last.detail.map { $0 + " " + text } ?? text
                }
                last.lastLine = line
                parsed.append(last)
            }
        }
        guard parsed.count >= 2, parsed.map(\.number) == Array(1...parsed.count) else { return nil }
        let cursors = parsed.indices.filter { parsed[$0].cursor }
        guard cursors.count == 1 else { return nil }

        // The question block sits above the options, up to a rule, two blank lines or a transcript line.
        var block: [String] = []
        row = first - 1
        while row >= 0, lines[row].isEmpty { row -= 1 }
        var blanks = 0
        while row >= 0 {
            let line = lines[row]
            if line.isEmpty {
                blanks += 1
                if blanks == 2 { break }
            } else {
                blanks = 0
                if isSolidRule(line) || startsTranscriptLine(line) { break }
                if !isRule(line) { block.insert(line.trimmingCharacters(in: .whitespaces), at: 0) }
            }
            row -= 1
        }
        guard let questionIndex = block.firstIndex(where: { $0.hasSuffix("?") }) else { return nil }
        let detailLines = block.enumerated()
            .filter { $0.offset != questionIndex && !$0.element.hasPrefix("Tip:") }
            .map(\.element)

        return TerminalPrompt(
            question: block[questionIndex],
            detail: detailLines.isEmpty ? nil : detailLines.joined(separator: "\n"),
            options: parsed.map { Option(label: stripHint($0.label), detail: $0.detail, needsText: needsText(stripHint($0.label))) },
            selected: cursors[0]
        )
    }

    private static func clean(_ line: String) -> String {
        var line = line
        for box in ["│", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"] { line = line.replacingOccurrences(of: box, with: " ") }
        while line.last?.isWhitespace == true { line.removeLast() }
        return line
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { "─╌━═".contains($0) }
    }

    private static func isSolidRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
    }

    private static func startsTranscriptLine(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return "•⏺✻⎿❯›■✗".contains(first)
    }

    private static let optionPattern = try! NSRegularExpression(pattern: #"^\s*([❯›>])?\s*(\d+)\.\s+(.*)$"#)

    private static func optionLine(_ line: String) -> (number: Int, cursor: Bool, text: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = optionPattern.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line),
              let number = Int(line[numberRange])
        else { return nil }
        return (number, match.range(at: 1).location != NSNotFound, String(line[textRange]))
    }

    /// Drops a trailing shortcut hint such as "(esc)", "(y)" or "(shift+tab)".
    private static func stripHint(_ label: String) -> String {
        label.replacingOccurrences(of: #"\s*\((esc|[a-z]|shift\+tab)\)$"#, with: "", options: .regularExpression)
    }

    private static func needsText(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("what to do differently") || lower.hasPrefix("type something") || lower == "other"
    }
}
