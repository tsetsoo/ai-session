import AISessionCore
import SwiftUI

/// A reply's prose lines as styled text: headings sized, list markers as bullets, quotes
/// dimmed, and inline emphasis, code and links rendered (also project updates, on both platforms). Line rules are `ChatMarkdown`'s, so
/// what shows matches "Copy as plain text".
enum ChatStyledText {
    static let codeFont = Font.system(.callout, design: .monospaced)

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    static func make(_ markdownLines: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in markdownLines.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            let (kind, rest) = ChatMarkdown.lineKind(line)
            var styled = inline(rest)
            switch kind {
            case let .heading(level): styled.font = headingFont(level)
            case .quote: styled.foregroundColor = .secondary
            case .plain, .bullet: break
            }
            result += styled
        }
        return result
    }

    private static func inline(_ line: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(line) }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = codeFont
        }
        return attributed
    }
}
