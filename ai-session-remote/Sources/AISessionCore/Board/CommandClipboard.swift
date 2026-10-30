import Foundation

/// Recover command text from the saved reply, before the terminal added wrapping and
/// indentation. Complete logical lines of a saved code snippet must match; ambiguous or
/// ordinary selections are copied verbatim. Shell syntax and quoted whitespace stay intact.
public enum CommandClipboard {
    public static func candidates(in messages: [String]) -> [String] {
        var snippets: Set<String> = []
        let inline = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
        for message in messages {
            var fence: (character: Character, length: Int, indentation: Int)?
            var code: [String] = []
            for line in message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
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
                        // A fence nested in a Markdown list adds container indentation,
                        // including before heredoc delimiters. That is not command text.
                        let padding = line.prefix(while: { $0 == " " }).count
                        code.append(String(line.dropFirst(min(padding, current.indentation))))
                    }
                } else if let first = trimmed.first, (first == "`" || first == "~"), marker.count >= 3 {
                    fence = (first, marker.count, line.prefix(while: { $0 == " " }).count)
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
        let contents = rows.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s*")
        guard let entire = try? NSRegularExpression(pattern: "\\A\\s*" + contents + "\\s*\\z"),
              let lines = try? NSRegularExpression(pattern: "^[\\t ]*" + contents + "[\\t ]*$", options: .anchorsMatchLines)
        else { return selection }
        var matches: Set<String> = []
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if entire.firstMatch(in: candidate, range: range) != nil { matches.insert(candidate) }
            // Selections can cover a multiline command inside a larger block. Only start
            // and end at source line boundaries; never expand selected arguments to a command.
            for match in lines.matches(in: candidate, range: range) {
                if let range = Range(match.range, in: candidate) { matches.insert(String(candidate[range])) }
            }
        }
        return matches.count == 1 ? matches.first! : selection
    }
}
