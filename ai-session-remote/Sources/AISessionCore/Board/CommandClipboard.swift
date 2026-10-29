import Foundation

/// Recover command text from the saved reply, before the terminal added wrapping and
/// indentation. A unique full code snippet must match; ambiguous or ordinary selections
/// are copied verbatim. No shell syntax, quoted whitespace or heredocs are rewritten.
public enum CommandClipboard {
    public static func candidates(in messages: [String]) -> [String] {
        var snippets: Set<String> = []
        let inline = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
        for message in messages {
            var fence: (character: Character, length: Int)?
            var code: [String] = []
            for line in message.components(separatedBy: "\n") {
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                let marker = trimmed.prefix(while: { $0 == trimmed.first })
                if let current = fence {
                    if trimmed.first == current.character, marker.count >= current.length,
                       trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
                        snippets.insert(code.joined(separator: "\n"))
                        snippets.formUnion(code.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        code = []
                        fence = nil
                    } else {
                        code.append(line)
                    }
                } else if let first = trimmed.first, (first == "`" || first == "~"), marker.count >= 3 {
                    fence = (first, marker.count)
                } else {
                    let range = NSRange(line.startIndex..., in: line)
                    for match in inline.matches(in: line, range: range) {
                        if let range = Range(match.range(at: 1), in: line) { snippets.insert(String(line[range])) }
                    }
                }
            }
        }
        return snippets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted()
    }

    public static func text(for selection: String, candidates: [String]) -> String {
        // Only visual row boundaries and their padding may differ. Literal spaces inside
        // each row must match, so `echo 'a  b'` can never become `echo 'a b'`.
        let rows = selection.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !rows.isEmpty, !candidates.isEmpty else { return selection }
        let pattern = "\\A\\s*" + rows.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s*") + "\\s*\\z"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return selection }
        let matches = Set(candidates.filter {
            expression.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        })
        return matches.count == 1 ? matches.first! : selection
    }
}
