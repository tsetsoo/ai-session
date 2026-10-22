import AISessionCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A conversation: the tool's icon and color, status dot, the todo's title and age,
/// "Sp · mac-studio", and the status message, plus its ⌘n hint in the Mac's Running now.
struct ConversationRow: View {
    let title: String
    let section: TodoSection?
    let conversation: Conversation
    let status: ConversationDisplayStatus
    /// Closing or deleting it.
    let isBusy: Bool
    /// Marks the todo done. On the Mac a checkmark takes the age's place while the pointer is on the row.
    var onDone: (() -> Void)?
    /// Its ⌘n in Running now on the Mac.
    var shortcut: Int?
    /// The Mac list paints the accent behind this row. The tool name then uses the selection label color.
    var isSelected: Bool = false

    /// Width of the dot column; the lines under the title start after it.
    private static let dotColumn: CGFloat = 21

    @State private var isHovering = false

    private var toolColor: Color {
        AppTheme.color(for: AITool(rawValue: conversation.tool))
    }

    /// Text on the Mac list's selection fill. White is a poor fit on the light accent.
    private var selectedLabel: Color {
        #if os(macOS)
        Color(nsColor: .alternateSelectedControlTextColor)
        #else
        Color.white
        #endif
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.spacing.s) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(toolColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            ToolIcon(tool: conversation.tool)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.spacing.s) {
                    StatusBadge(status, style: .dot)
                        .frame(width: Self.dotColumn)
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(RowText.toolName(conversation.tool))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(isSelected ? selectedLabel : toolColor)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: DS.spacing.s)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else if isHovering, let onDone {
                        Button(action: onDone) {
                            Image(systemName: "checkmark.circle")
                                .font(.body)
                                .foregroundStyle(isSelected ? selectedLabel : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Mark Todo Done")
                        .accessibilityLabel("Mark Todo Done")
                    } else {
                        ConversationAgeLabel(conversation: conversation)
                    }
                }
                HStack(spacing: DS.spacing.s) {
                    Text(RowText.conversationMeta(conversation, section: section))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let shortcut {
                        Text("⌘\(shortcut)")
                            .monospacedDigit()
                            .accessibilityLabel("Command \(shortcut)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, Self.dotColumn + DS.spacing.s)
                ConversationMessageLabel(conversation: conversation, status: status)
                    .font(.footnote)
                    .lineLimit(1)
                    .padding(.leading, Self.dotColumn + DS.spacing.s)
            }
        }
        .padding(.vertical, DS.spacing.xs)
        .frame(minHeight: DS.rowMinHeight)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onDone {
                Button("Mark Todo Done", action: onDone)
            }
        }
    }
}

/// The row's age, redrawn once a minute on its own so the list around the row stays put.
private struct ConversationAgeLabel: View {
    let conversation: Conversation

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let age = RowText.age(of: conversation, now: context.date) {
                Text(age)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Working for 4m" advances with the same minute clock. Needs-you text does not depend on it,
/// but one label is cheaper than rebuilding the list to pass a date in.
private struct ConversationMessageLabel: View {
    let conversation: Conversation
    let status: ConversationDisplayStatus

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(RowText.conversationMessage(conversation, status: status, now: context.date))
                .foregroundStyle(status == .needsYou ? DS.accent : Color.secondary)
        }
    }
}
