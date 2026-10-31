import Foundation

/// A reply split into what the chat draws differently. `text` keeps its markdown lines for the
/// app to style; `code` is exactly what sat between the fences.
public enum ChatBlock: Equatable, Sendable {
    case text(String)
    case code(language: String?, code: String)
    case table(rows: [[String]])
}

public enum ChatMarkdown {
    /// Replies longer than this fold behind "Show more".
    public static let foldLines = 30
    public static let foldCharacters = 2000
    public static let previewLines = 20
    public static let previewCharacters = 1500

    public static func blocks(_ text: String) -> [ChatBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ChatBlock] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            while prose.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { prose.removeFirst() }
            while prose.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { prose.removeLast() }
            if !prose.isEmpty { blocks.append(.text(prose.joined(separator: "\n"))) }
            prose = []
        }

        while index < lines.count {
            let line = lines[index]
            if let fence = fence(line) {
                flushProse()
                var code: [String] = []
                index += 1
                while index < lines.count, !closes(lines[index], fence.marker) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if isRow(line), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                flushProse()
                var rows = [cells(line)]
                index += 2
                while index < lines.count, isRow(lines[index]) {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        return blocks
    }

    /// The reply without markdown symbols: headings and emphasis lose their markers, list
    /// markers become bullets, and code keeps its exact text.
    public static func plainText(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case let .text(markdown): return plainProse(markdown)
            case let .code(_, code): return code
            case let .table(rows): return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    public static func isLong(_ text: String) -> Bool {
        text.count > foldCharacters || text.components(separatedBy: "\n").count > foldLines
    }

    public static func preview(_ text: String) -> String {
        String(text.components(separatedBy: "\n").prefix(previewLines).joined(separator: "\n").prefix(previewCharacters))
    }

    /// One prose line's block-level marker removed: `(kind, rest)`.
    public enum LineKind: Equatable, Sendable { case plain, heading(Int), bullet, quote }

    public static func lineKind(_ line: String) -> (LineKind, String) {
        let indent = String(line.prefix { $0 == " " })
        let body = line.dropFirst(indent.count)
        if let hashes = body.firstIndex(where: { $0 != "#" }), hashes > body.startIndex,
           body.distance(from: body.startIndex, to: hashes) <= 6, body[hashes] == " " {
            return (.heading(body.distance(from: body.startIndex, to: hashes)), String(body[body.index(after: hashes)...]))
        }
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            return (.bullet, indent + "• " + body.dropFirst(2))
        }
        if body.hasPrefix("> ") { return (.quote, String(body.dropFirst(2))) }
        return (.plain, line)
    }

    /// Inline markdown (emphasis, code, links) removed from one line, whitespace kept.
    public static func inlinePlain(_ line: String) -> String {
        guard let attributed = try? AttributedString(
            markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return line }
        return String(attributed.characters)
    }

    private static func plainProse(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { inlinePlain(lineKind($0).1) }.joined(separator: "\n")
    }

    private static func fence(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    private static func closes(_ line: String, _ marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    private static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1
    }

    private static func isSeparator(_ line: String) -> Bool {
        isRow(line) && line.allSatisfy { "|-: ".contains($0) } && line.contains("-")
    }

    private static func cells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
