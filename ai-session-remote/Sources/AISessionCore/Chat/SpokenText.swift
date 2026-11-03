import Foundation
import NaturalLanguage

/// What Read Aloud says for a chat message: the prose without markdown symbols, a code block
/// as just "Code block." and table rows as short sentences.
public enum SpokenText {
    public static func make(_ markdown: String) -> String {
        ChatMarkdown.blocks(markdown).map { block in
            switch block {
            case let .text(prose):
                return ChatMarkdown.plainText(prose)
                    .components(separatedBy: "\n")
                    .map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }
                    .joined(separator: "\n")
            case .code:
                return "Code block."
            case let .table(rows):
                return rows.map { $0.joined(separator: ", ") + "." }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
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
