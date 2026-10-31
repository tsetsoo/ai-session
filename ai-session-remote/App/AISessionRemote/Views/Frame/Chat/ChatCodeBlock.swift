#if os(iOS)
import AISessionCore
import SwiftUI

/// A fenced code block: a dark box with its language and its own Copy, scrolling sideways
/// instead of wrapping so commands stay on one line.
struct ChatCodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    /// Exactly the text between the fences. Nil for anything that isn't code.
    static func copyText(for block: ChatBlock) -> String? {
        guard case let .code(_, code) = block else { return nil }
        return code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2.monospaced())
                Spacer()
                Button {
                    PlatformSupport.pasteboardString = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().overlay(Color.white.opacity(0.15))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(ChatStyledText.codeFont)
                    .foregroundStyle(Color(white: 0.92))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A markdown table in a grid that scrolls sideways.
struct ChatTable: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    GridRow {
                        ForEach(rows[index].indices, id: \.self) { column in
                            Text(ChatStyledText.make(rows[index][column]))
                                .fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
#endif
