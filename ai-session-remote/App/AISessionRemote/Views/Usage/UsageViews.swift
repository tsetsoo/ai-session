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

/// Usage limits pane: what used the most of this week or last, by todo, job, sub-agent type
/// and conversation. Ranked and shared by output + cache writes; token counts, never money.
struct HeavyUsageSections: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void
    /// `nil`: job rows push the job's detail (the phone's navigation stack).
    let onOpenJob: ((String) -> Void)?

    @State private var lastWeek = false
    @State private var heavy: HeavyUsage?
    @State private var failed = false

    private var weekStart: String {
        let monday = WeekMath.monday(of: .now)
        return lastWeek ? (WeekMath.shift(monday, byWeeks: -1) ?? monday) : monday
    }

    var body: some View {
        Section {
            Picker("Week", selection: $lastWeek) {
                Text("This week").tag(false)
                Text("Last week").tag(true)
            }
            .pickerStyle(.segmented)
            if let heavy {
                if heavy.totalWeight == 0 {
                    Text("No usage uploaded for this week.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Conversations", value: "\(StatsFormat.tokens(heavy.own.outputTokens)) out")
                    if heavy.workers.sessions > 0 {
                        LabeledContent("\(heavy.workers.sessions) sub-agents",
                                       value: "\(StatsFormat.tokens(heavy.workers.outputTokens)) out")
                    }
                }
            } else if failed {
                Text("Couldn't load usage from the hub.").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Used most")
        } footer: {
            Text("Ranked by output + cache writes, which use up limits; cheap cache reads are left out. Token counts, not money.")
        }
        .task(id: weekStart) { await poll() }
        if let heavy, heavy.totalWeight > 0 {
            if !heavy.todos.isEmpty {
                Section("Todos") {
                    ForEach(heavy.todos) { t in
                        opener({ onOpenTodo(t.todoId) }, help: "Open this todo") {
                            row(t.title, own: t.own, workers: t.workers, share: heavy.share(t.weight))
                        }
                    }
                }
            }
            if !heavy.jobs.isEmpty {
                Section("Jobs") {
                    ForEach(heavy.jobs) { j in
                        let label = row(j.runs == 1 ? j.name : "\(j.name) · \(j.runs) runs", own: j.own,
                                        workers: j.workers, share: heavy.share(j.weight))
                        if let onOpenJob {
                            opener({ onOpenJob(j.jobId) }, help: "Open this job") { label }
                        } else {
                            NavigationLink {
                                PhoneJobDetail(store: store, jobID: j.jobId, onOpenTodo: onOpenTodo)
                            } label: { label }
                        }
                    }
                }
            }
            if !heavy.workerTypes.isEmpty {
                Section("Sub-agents") {
                    ForEach(heavy.workerTypes) { w in
                        row("\(w.title) ×\(w.counters.sessions)", own: w.counters, workers: StatsCounters(),
                            share: heavy.share(w.counters.weight))
                    }
                }
            }
            if !heavy.conversations.isEmpty {
                Section("Conversations") {
                    ForEach(heavy.conversations) { c in
                        let label = row(conversationTitle(c), own: c.own, workers: c.workers, share: heavy.share(c.weight))
                        if let todoId = c.todoId {
                            opener({ onOpenTodo(todoId) }, help: "Open its todo") { label }
                        } else {
                            label
                        }
                    }
                }
            }
        }
    }

    /// A whole row as a button, with a chevron so it reads as one.
    private func opener(_ action: @escaping () -> Void, help: String,
                        @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack {
                label()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityHint(help)
    }

    private func conversationTitle(_ c: HeavyConversation) -> String {
        if let todoId = c.todoId, let todo = store.todos.first(where: { $0.id == todoId }) { return todo.title }
        return c.title ?? "\(c.tool.capitalized) \(c.sessionId.prefix(8))"
    }

    private func row(_ title: String, own: StatsCounters, workers: StatsCounters, share: Double) -> some View {
        let summary = UsageSummary(own: own, workers: workers)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(UsageText.compactTokens(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(share.formatted(.percent.precision(.fractionLength(0))))
                .font(.callout.monospacedDigit())
                .foregroundStyle(share >= 0.25 ? DS.accent : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Computers upload every few minutes, so a slow refresh while the pane is open is enough.
    private func poll() async {
        heavy = nil
        failed = false
        while !Task.isCancelled {
            do {
                let next = try await store.heaviest(weekStart: weekStart)
                guard !Task.isCancelled else { return }
                heavy = next
                failed = next == nil
            } catch {
                guard !Task.isCancelled else { return }
                if heavy == nil { failed = true }
            }
            try? await Task.sleep(for: .seconds(120))
        }
    }
}
