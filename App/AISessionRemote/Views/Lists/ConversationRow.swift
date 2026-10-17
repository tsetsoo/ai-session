import AISessionCore
import SwiftUI

/// A conversation: status dot, the todo's title and age, "Sp · mac-studio · Claude", and the
/// status message (or how long it has been working).
struct ConversationRow: View {
    let title: String
    let section: TodoSection?
    let conversation: Conversation
    let status: ConversationDisplayStatus
    let now: Date
    /// Closing or deleting it.
    let isBusy: Bool

    /// Width of the dot column; the lines under the title start after it.
    private static let dotColumn: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.spacing.m) {
                StatusBadge(status, style: .dot)
                    .frame(width: Self.dotColumn)
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let age = RowText.age(of: conversation, now: now) {
                    Text(age)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                Text(RowText.conversationMeta(conversation, section: section))
                    .foregroundStyle(.secondary)
                Text(RowText.conversationMessage(conversation, status: status, now: now))
                    .foregroundStyle(status == .needsYou ? DS.accent : Color.secondary)
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.leading, Self.dotColumn + DS.spacing.m)
        }
        .padding(.vertical, DS.spacing.xs)
        .frame(minHeight: DS.rowMinHeight)
        .accessibilityElement(children: .combine)
    }
}
