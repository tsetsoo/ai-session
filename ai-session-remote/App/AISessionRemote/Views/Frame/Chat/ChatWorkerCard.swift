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
                    WorkerStateLabel(state: worker.state, needsYou: worker.needsYou)
                }
                if let result = worker.result, worker.state == .done {
                    Text(ChatMarkdown.plainText(result)).font(.footnote).lineLimit(3).foregroundStyle(.primary)
                } else {
                    // "Last update 4 s ago" keeps counting between list refreshes.
                    TimelineView(.periodic(from: .now, by: worker.state == .working && !worker.needsYou ? 5 : 60)) { context in
                        if let status = worker.statusText(now: context.date) {
                            Text(status).font(.caption).foregroundStyle(worker.needsYou ? AnyShapeStyle(WorkerStateLabel.needsYouColor) : AnyShapeStyle(.secondary)).lineLimit(2)
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
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkerStateLabel.color(worker.state, needsYou: worker.needsYou).opacity(worker.needsYou ? 0.7 : 0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the result, what it did and its task")
    }
}

/// "Done", "Working", "Failed", "No news", "Needs you" with its symbol and color.
struct WorkerStateLabel: View {
    let state: DelegatedWorker.State
    /// The worker waits on an approval or answer (from the hub's status): amber, over its state.
    var needsYou = false

    static let needsYouColor = Color.orange

    static func look(_ state: DelegatedWorker.State, needsYou: Bool) -> (String, String) {
        if needsYou { return ("hand.raised.fill", "Needs you") }
        return switch state {
        case .working: ("circle.dotted", "Working")
        case .done: ("checkmark.circle.fill", "Done")
        case .failed: ("exclamationmark.triangle.fill", "Failed")
        case .stale: ("questionmark.circle", "No news")
        }
    }

    static func color(_ state: DelegatedWorker.State, needsYou: Bool = false) -> Color {
        if needsYou { return needsYouColor }
        return switch state {
        case .working: .blue
        case .done: .green
        case .failed: .red
        case .stale: .secondary
        }
    }

    var body: some View {
        let (icon, text) = Self.look(state, needsYou: needsYou)
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Self.color(state, needsYou: needsYou))
    }
}

/// Over a chat with more than one worker: "2 working · 1 needs you · 1 done". Tapping it opens
/// the worker that needs you, if one does.
struct WorkerStrip: View {
    let tally: WorkerTally
    var onTap: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: tally.needsYou > 0 ? "hand.raised.fill" : "person.2")
                .foregroundStyle(tally.needsYou > 0 ? WorkerStateLabel.needsYouColor : Color.secondary)
            Text(tally.summary).lineLimit(1)
            Spacer(minLength: 0)
            if onTap != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tally.needsYou > 0 ? AnyShapeStyle(WorkerStateLabel.needsYouColor.opacity(0.12)) : AnyShapeStyle(DS.chipFill))
        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .accessibilityLabel("Workers: \(tally.summary)")
                .accessibilityHint("Opens the worker that needs you")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Workers: \(tally.summary)")
        }
    }
}
