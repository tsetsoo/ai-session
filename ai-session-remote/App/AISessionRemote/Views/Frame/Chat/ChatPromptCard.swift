#if os(iOS)
import AISessionCore
import SwiftUI

/// A question the agent is asking, read off the terminal, with one button per option.
struct ChatPromptCard: View {
    let prompt: TerminalPrompt
    /// The last tap found a different question on screen; this is the new one.
    let changed: Bool
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if changed {
                Text("That question changed. Here’s the new one.")
                    .font(.footnote)
                    .foregroundStyle(DS.warning)
            }
            Text(prompt.question).font(.subheadline.weight(.semibold))
            if let detail = prompt.detail {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .lineLimit(8)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(DS.chipFill, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(prompt.options.indices, id: \.self) { index in
                let option = prompt.options[index]
                Button { onChoose(index) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.callout.weight(index == prompt.selected ? .semibold : .regular))
                            if let detail = option.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if option.needsText {
                            Image(systemName: "keyboard").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Asks you to type")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(index == prompt.selected ? DS.accentTint : Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.warning.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// The agent is waiting but the app can't read the question: the bottom of the terminal, with
/// the keys a menu needs.
struct ChatScreenFallbackCard: View {
    let lines: [String]
    let onKey: (TerminalKey) -> Void
    let onOpenTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Needs your input").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Open Terminal", action: onOpenTerminal).font(.footnote)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(lines.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            .background(DS.chipFill, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                key("↑", .up, "Up")
                key("↓", .down, "Down")
                key("Enter", .enter, "Enter")
                key("Esc", .esc, "Escape")
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.warning.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func key(_ title: String, _ key: TerminalKey, _ label: String) -> some View {
        Button(title) { onKey(key) }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}
#endif
