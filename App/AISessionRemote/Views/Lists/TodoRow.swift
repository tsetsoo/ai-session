import AISessionCore
import SwiftUI

/// A todo: checkbox, title, its conversation's status, and a second line with the computer and
/// age, or the status message when it needs you.
struct TodoRow: View {
    let todo: Todo
    let conversation: Conversation?
    let status: ConversationDisplayStatus?
    let now: Date
    /// Closing or deleting its conversation.
    let isBusy: Bool
    let canToggle: Bool
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
                if let subtitle = RowText.todoSubtitle(conversation, status: status, now: now) {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(status == .needsYou ? DS.accent : Color.secondary)
                        .lineLimit(1)
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
