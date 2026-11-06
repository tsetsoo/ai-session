import AISessionCore
import SwiftUI

// What a todo's or job's conversations used, from `GET /api/todos/{id}/usage` and
// `/api/jobs/{id}/usage`. Token counts and time only: subscription quota is never shown as
// money. "Heaviest" means output + cache-creation tokens (cache reads are cheap and make up
// most of the input).

/// The usage chip at the right of the limits strip; opens the details.
struct TodoUsageChip: View {
    let usage: UsageSummary
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            Text(UsageText.compact(usage))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(UsageText.spoken(usage))
        .accessibilityLabel(UsageText.spoken(usage))
        .accessibilityHint("Shows usage by model and sub-agent")
        .popover(isPresented: $showsDetails) {
            ScrollView {
                UsageDetailView(usage: usage, title: "This todo")
                    .padding(DS.spacing.l)
            }
            .frame(minWidth: 320, idealWidth: 360, maxHeight: 520)
            .presentationCompactAdaptation(.sheet)
        }
    }
}

enum UsageText {
    /// `Todo 1.1M out +4.1M agents`
    static func compact(_ u: UsageSummary) -> String {
        var text = "Todo \(StatsFormat.tokens(u.own.outputTokens)) out"
        if u.workers.sessions > 0 {
            text += " +\(StatsFormat.tokens(u.workers.outputTokens)) agents"
        }
        return text
    }

    static func spoken(_ u: UsageSummary) -> String {
        var parts = ["This todo's conversations: \(StatsFormat.tokens(u.own.outputTokens)) output tokens"]
        if u.workers.sessions > 0 {
            parts.append("their \(u.workers.sessions) sub-agents \(StatsFormat.tokens(u.workers.outputTokens))")
        }
        parts.append("active \(StatsFormat.duration(seconds: u.own.activeSeconds))")
        return parts.joined(separator: ", ")
    }

    /// One line for a job run: `1.1M out +4.1M agents · 1h 5m`, or why there is nothing.
    static func runLine(_ u: UsageSummary) -> String? {
        if u.isEmpty {
            return u.unreadConversations > 0 ? "No usage reading" : nil
        }
        return "\(compactTokens(u)) · \(StatsFormat.duration(seconds: u.own.activeSeconds))"
    }

    static func compactTokens(_ u: UsageSummary) -> String {
        var text = "\(StatsFormat.tokens(u.own.outputTokens)) out"
        if u.workers.sessions > 0 {
            text += " +\(StatsFormat.tokens(u.workers.outputTokens)) agents"
        }
        return text
    }
}

/// Own vs sub-agents, time, models, sub-agent types and conversations without numbers.
struct UsageDetailView: View {
    let usage: UsageSummary
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.l) {
            Text(title).font(.headline)
            totals
            if !usage.byModel.isEmpty { models }
            if !usage.workerTypes.isEmpty { workerTypes }
            if usage.unreadConversations > 0 { unread }
            footer
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totals: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.spacing.l, verticalSpacing: DS.spacing.xs) {
            GridRow {
                Text("")
                Text("Output").foregroundStyle(.secondary)
                Text("Cache writes").foregroundStyle(.secondary)
            }
            .font(.caption)
            row("Conversations", usage.own)
            if usage.workers.sessions > 0 {
                row(usage.workers.sessions == 1 ? "1 sub-agent" : "\(usage.workers.sessions) sub-agents", usage.workers)
                row("Total", usage.total).fontWeight(.semibold)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Active")
                Text(StatsFormat.duration(seconds: usage.own.activeSeconds)).monospacedDigit()
                    .gridCellColumns(2)
            }
            if let elapsed = usage.elapsedSeconds {
                GridRow {
                    Text("First to last")
                    Text(StatsFormat.span(seconds: elapsed)).monospacedDigit()
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func row(_ label: String, _ c: StatsCounters) -> some View {
        GridRow {
            Text(label)
            Text(StatsFormat.tokens(c.outputTokens)).monospacedDigit()
            Text(StatsFormat.tokens(c.cacheCreationTokens)).monospacedDigit()
        }
    }

    private var models: some View {
        section("By model") {
            ForEach(usage.byModel) { m in
                HStack {
                    Text(m.shortName).lineLimit(1)
                    Spacer()
                    Text("\(StatsFormat.tokens(m.outputTokens)) out · \(StatsFormat.tokens(m.cacheCreationTokens)) writes")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var workerTypes: some View {
        section("Sub-agents") {
            ForEach(usage.workerTypes) { w in
                HStack {
                    Text("\(w.title) ×\(w.counters.sessions)").lineLimit(1)
                    Spacer()
                    Text("\(StatsFormat.tokens(w.counters.outputTokens)) out")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unread: some View {
        section("Not counted") {
            ForEach(usage.conversations.filter { $0.reading != .uploaded }) { c in
                HStack {
                    Text(c.title ?? c.label ?? c.tool.capitalized).lineLimit(1)
                    Spacer()
                    Text(c.reading.missingReason ?? "").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sorted by output + cache writes, which use up limits; cheap cache reads are left out.")
            if let updated = usage.statsUpdatedAt {
                Text("Uploaded by the computers, oldest reading \(updated) UTC.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}
