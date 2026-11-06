import AISessionCore
import SwiftUI

/// A conversation: the tool's icon and name, status dot, the todo's title and age,
/// "Sp · mac-studio", and the status message, plus its ⌘n hint in the Mac's conversation lists.
struct ConversationRow: View {
    let title: String
    let section: TodoSection?
    let conversation: Conversation
    let status: ConversationDisplayStatus
    /// Closing or deleting it.
    let isBusy: Bool
    /// Marks the todo done. On the Mac a checkmark takes the age's place while the pointer is on the row.
    var onDone: (() -> Void)?
    /// Its ⌘n in the Mac's conversation lists.
    var shortcut: Int?
    /// The one-tap Resume, while a weekly or unknown limit's reset is offered.
    var onResume: (() -> Void)?
    /// Its review at a glance: "2 open · reviewed 4m ago", "reviewing…".
    var review: ReviewSummary?

    /// Width of the dot column; the lines under the title start after it.
    private static let dotColumn: CGFloat = 21

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: DS.spacing.s) {
            ToolIcon(tool: conversation.tool)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.spacing.s) {
                    StatusBadge(status, style: .dot)
                        .frame(width: Self.dotColumn)
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    // Secondary, so the Mac list's selection fill restyles it like the other grey text.
                    Text(RowText.toolName(conversation.tool))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: DS.spacing.s)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else if let onResume {
                        ResumeAfterLimitButton(action: onResume)
                    } else if isHovering, let onDone {
                        Button(action: onDone) {
                            Image(systemName: "checkmark.circle")
                                .font(.body)
                                .foregroundStyle(.secondary)
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
                    if let review {
                        ReviewBadge(summary: review)
                    }
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
            if let onResume {
                Button("Resume", action: onResume)
            }
            if let onDone {
                Button("Mark Todo Done", action: onDone)
            }
        }
    }
}

/// "Resume" in a row once a usage limit has reset. Quiet: a small bordered button, no badge.
struct ResumeAfterLimitButton: View {
    let action: () -> Void

    var body: some View {
        Button("Resume", action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            #if os(macOS)
            .help("Continue where it stopped at the usage limit")
            #endif
    }
}

/// "2 open · reviewed 4m ago" with a checklist icon; nothing when there's nothing to say.
struct ReviewBadge: View {
    let summary: ReviewSummary

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let label = summary.label(now: context.date) {
                Label(label, systemImage: summary.reviewing ? "sparkle.magnifyingglass" : "checklist")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(summary.open > 0 ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityLabel("Review: \(label)")
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
