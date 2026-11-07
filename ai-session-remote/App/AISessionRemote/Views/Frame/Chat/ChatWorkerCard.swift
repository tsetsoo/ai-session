import AISessionCore
import SwiftUI

/// Work the agent handed to another agent, in the chat where it started: who, how it's going,
/// and the start of what it reported. Tap for the sheet.
struct ChatWorkerCard: View {
    let worker: DelegatedWorker
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2").font(.caption)
                    Text(worker.displayTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    WorkerStateLabel(state: worker.state)
                }
                if let result = worker.result, worker.state == .done {
                    Text(ChatMarkdown.plainText(result)).font(.footnote).lineLimit(3).foregroundStyle(.primary)
                } else {
                    // "Last update 4 s ago" keeps counting between list refreshes.
                    TimelineView(.periodic(from: .now, by: worker.state == .working ? 5 : 60)) { context in
                        if let status = worker.statusText(now: context.date) {
                            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                let stats = [worker.kind, worker.statsLine.isEmpty ? nil : worker.statsLine].compactMap { $0 }.joined(separator: " · ")
                if !stats.isEmpty {
                    Text(stats).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.chipFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkerStateLabel.color(worker.state).opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the result, what it did and its task")
    }
}

/// "Done", "Working", "Failed", "No news" with its symbol and color.
struct WorkerStateLabel: View {
    let state: DelegatedWorker.State

    static func color(_ state: DelegatedWorker.State) -> Color {
        switch state {
        case .working: .blue
        case .done: .green
        case .failed: .red
        case .stale: .secondary
        }
    }

    var body: some View {
        let (icon, text): (String, String) = switch state {
        case .working: ("circle.dotted", "Working")
        case .done: ("checkmark.circle.fill", "Done")
        case .failed: ("exclamationmark.triangle.fill", "Failed")
        case .stale: ("questionmark.circle", "No news")
        }
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Self.color(state))
    }
}
