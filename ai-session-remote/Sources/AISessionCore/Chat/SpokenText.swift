import Foundation
import NaturalLanguage

/// One line Read Aloud speaks on its own, and the pause after it in seconds.
public struct SpokenPart: Equatable, Sendable {
    public let text: String
    public let pause: Double

    public init(text: String, pause: Double) {
        self.text = text
        self.pause = pause
    }
}

/// What Read Aloud says for a chat message: the prose without markdown symbols, inline code
/// said the way a person would ("status dot py"), a code block as just "Code block." and table
/// rows as short sentences.
public enum SpokenText {
    /// Pause after a line, and longer after a paragraph (a blank line, or a block's end).
    public static let linePause = 0.15
    public static let paragraphPause = 0.4

    public static func make(_ markdown: String) -> String {
        ChatMarkdown.blocks(markdown).map { block in
            switch block {
            case let .text(prose):
                return ChatMarkdown.plainText(speakingInlineCode(prose))
                    .components(separatedBy: "\n")
                    .map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }
                    .joined(separator: "\n")
            case .code:
                return "Code block."
            case let .table(rows):
                return rows.map { $0.joined(separator: ", ") + "." }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }

    /// `make`'s text split into lines spoken one by one, so headings and list items end like
    /// sentences instead of running into the next line.
    public static func parts(_ spoken: String) -> [SpokenPart] {
        let lines = spoken.components(separatedBy: "\n")
        var parts: [SpokenPart] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if let last = parts.popLast() { parts.append(SpokenPart(text: last.text, pause: paragraphPause)) }
            } else {
                parts.append(SpokenPart(text: text, pause: linePause))
            }
        }
        if let last = parts.popLast() { parts.append(SpokenPart(text: last.text, pause: 0)) }
        return parts
    }

    /// Inline code spans replaced by how they're said: dots before a letter, slashes and
    /// underscores are spoken or dropped, camelCase is split into words. "1.2" stays a number.
    static func speakingInlineCode(_ markdown: String) -> String {
        guard markdown.contains("`") else { return markdown }
        let pattern = #/`([^`\n]+)`/#
        return markdown.replacing(pattern) { match in say(code: String(match.output.1)) }
    }

    static func say(code: String) -> String {
        var words = ""
        var previous: Character?
        let characters = Array(code)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch character {
            case "." where next?.isLetter == true && previous != nil:
                words += " dot "
            case "/":
                words += previous == nil ? "slash " : " slash "
            case "_", "`":
                words += " "
            default:
                if character.isUppercase, previous?.isLowercase == true { words += " " }
                words.append(character)
            }
            previous = character
        }
        return words.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The message's language (a BCP 47 code such as "en" or "bg") to pick the voice, or nil
    /// when there is too little prose to tell; the system voice is used then.
    public static func language(of markdown: String) -> String? {
        let prose = ChatMarkdown.blocks(markdown).compactMap { block -> String? in
            if case let .text(text) = block { return ChatMarkdown.plainText(text) }
            return nil
        }.joined(separator: "\n")
        guard prose.split(whereSeparator: \.isWhitespace).count >= 3 else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: prose)?.rawValue
    }
}
