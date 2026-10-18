import AISessionCore
import SwiftUI

/// A todo: checkbox, title, its conversation's status, and a second line with the computer and
/// age, or the status message when it needs you.
struct TodoRow: View {
    let todo: Todo
    let conversation: Conversation?
    let status: ConversationDisplayStatus?
    /// Closing or deleting its conversation.
    let isBusy: Bool
    let canToggle: Bool
    /// The todo's project, in lists not already filtered by project.
    var projectName: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            Button(action: onToggle) {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.completed ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .strikethrough(todo.completed)
                    .foregroundStyle(todo.completed ? .secondary : .primary)
                    .lineLimit(1)
                if conversation != nil || projectName != nil {
                    TodoSubtitleLabel(conversation: conversation, status: status, projectName: projectName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if let status {
                StatusBadge(status)
            }
        }
        .frame(minHeight: DS.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityValue(todo.completed ? "Done" : "")
        .accessibilityAction(named: todo.completed ? "Undo" : "Done") {
            if canToggle { onToggle() }
        }
    }
}

/// The second line, including the age, redrawn once a minute without rebuilding the todo list.
private struct TodoSubtitleLabel: View {
    let conversation: Conversation?
    let status: ConversationDisplayStatus?
    let projectName: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let subtitle = RowText.todoSubtitle(conversation, status: status, now: context.date)
            if subtitle != nil || projectName != nil {
                HStack(spacing: DS.spacing.s) {
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(status == .needsYou ? DS.accent : Color.secondary)
                    }
                    if let projectName {
                        Label(projectName, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .lineLimit(1)
            }
        }
    }
}
