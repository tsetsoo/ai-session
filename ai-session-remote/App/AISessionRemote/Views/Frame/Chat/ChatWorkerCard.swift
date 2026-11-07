#if os(iOS)
import AISessionCore
import SwiftUI

/// Work the agent handed to another agent, in the chat where it started: who, how it's going,
/// and the start of what it reported.
struct ChatWorkerCard: View {
    let worker: DelegatedWorker

    private var stateLine: (icon: String, text: String, color: Color) {
        switch worker.state {
        case .working: return ("circle.dotted", "Working", .blue)
        case .done: return ("checkmark.circle.fill", "Done", .green)
        case .failed: return ("exclamationmark.triangle.fill", "Failed", .red)
        case .stale: return ("questionmark.circle", "No news", .secondary)
        }
    }

    var body: some View {
        let state = stateLine
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2").font(.caption)
                Text(worker.displayTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Label(state.text, systemImage: state.icon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.color)
            }
            if let result = worker.result, worker.state == .done {
                Text(result).font(.footnote).lineLimit(3).foregroundStyle(.primary)
            } else if worker.state != .done, let evidence = worker.evidence {
                Text(evidence).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            let stats = [worker.kind, worker.statsLine.isEmpty ? nil : worker.statsLine].compactMap { $0 }.joined(separator: " · ")
            if !stats.isEmpty {
                Text(stats).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.chipFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state.color.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}
#endif
