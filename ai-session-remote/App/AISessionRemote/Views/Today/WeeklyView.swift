import AISessionCore
import SwiftUI

/// Weekly recaps, newest first: a Monday look back at last week's wins. The newest week is open,
/// older ones show their label and totals. Loads when it opens (never on the general refresh),
/// four weeks at a time.
struct WeeklyView: View {
    let store: TodoHubStore
    let onOpenTodo: (String) -> Void

    @State private var weeks: [WeeklyRecap]?
    @State private var expanded: Set<String> = []
    @State private var canLoadOlder = false
    @State private var isLoadingOlder = false
    @State private var errorMessage: String?

    private static let pageSize = 4

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.spacing.xl) {
                if let weeks {
                    if weeks.isEmpty && errorMessage == nil {
                        Text("No recaps yet. Each Monday morning, last week's shows here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(weeks) { recap in
                        WeeklyWeekCard(
                            recap: recap,
                            isExpanded: Binding(
                                get: { expanded.contains(recap.week) },
                                set: { open in if open { expanded.insert(recap.week) } else { expanded.remove(recap.week) } }
                            ),
                            isOffline: store.isOffline,
                            onRewrite: { section in Task { await rewrite(section, week: recap.week) } },
                            onOpenTodo: onOpenTodo
                        )
                    }
                    if canLoadOlder {
                        Button("Show older") { Task { await loadOlder() } }
                            .disabled(isLoadingOlder)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(DS.warning)
                }
            }
            .padding(DS.spacing.l)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Weekly")
        .refreshable { await loadFirstPage() }
        .task {
            guard weeks == nil else { return }
            await loadFirstPage()
        }
    }

    private func loadFirstPage() async {
        do {
            let page = try await store.weeklyRecaps(before: nil, limit: Self.pageSize)
            guard !Task.isCancelled else { return }
            if let newest = page.first, newest.week != weeks?.first?.week { expanded.insert(newest.week) }
            weeks = page
            canLoadOlder = page.count == Self.pageSize
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = TodoHubStore.message(for: error)
            if weeks == nil { weeks = [] }
        }
    }

    private func loadOlder() async {
        guard !isLoadingOlder, let last = weeks?.last else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await store.weeklyRecaps(before: last.week, limit: Self.pageSize)
            let shown = Set((weeks ?? []).map(\.week))
            weeks = (weeks ?? []) + page.filter { !shown.contains($0.week) }
            canLoadOlder = page.count == Self.pageSize
        } catch {
            errorMessage = TodoHubStore.message(for: error)
        }
    }

    private func rewrite(_ section: WeeklySection, week: String) async {
        do {
            try await store.rewriteWeekly(projectId: section.projectId, week: week)
            if let w = weeks?.firstIndex(where: { $0.week == week }),
               let s = weeks?[w].sections.firstIndex(where: { $0.projectId == section.projectId }) {
                weeks?[w].sections[s].rewriting = true
                weeks?[w].sections[s].failed = false
            }
        } catch {
            errorMessage = TodoHubStore.message(for: error)
        }
    }
}

// MARK: - A week

struct WeeklyWeekCard: View {
    let recap: WeeklyRecap
    @Binding var isExpanded: Bool
    let isOffline: Bool
    let onRewrite: (WeeklySection) -> Void
    let onOpenTodo: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.l) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recap.label).font(.title2.weight(.semibold))
                        Text(isExpanded ? recap.windowLabel : totalsLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses the week" : "Shows the week")

            if isExpanded {
                tiles
                headlines
                ForEach(recap.sections) { section in
                    WeeklySectionBlock(section: section, isOffline: isOffline) { onRewrite(section) }
                }
                if recap.sections.isEmpty {
                    Text("No project had daily updates this week.").foregroundStyle(.secondary)
                }
                if let jobs = recap.jobs, !jobs.jobs.isEmpty {
                    WeeklyJobsBlock(jobs: jobs, onOpenTodo: onOpenTodo)
                }
            }
        }
    }

    private var totalsLine: String {
        "\(WeeklySection.plural(recap.totals.commits, "commit")) · \(WeeklySection.plural(recap.totals.conversations, "conversation")) · \(WeeklySection.plural(recap.totals.runs, "scheduled run"))"
    }

    private var tiles: some View {
        HStack(spacing: DS.spacing.m) {
            tile(recap.totals.commits, recap.totals.commits == 1 ? "commit" : "commits")
            tile(recap.totals.conversations, recap.totals.conversations == 1 ? "conversation" : "conversations")
            tile(recap.totals.runs, recap.totals.runs == 1 ? "scheduled run" : "scheduled runs")
        }
    }

    private func tile(_ value: Int, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DS.accentOnTint)
            Text(caption)
                .font(.caption)
                .foregroundStyle(DS.accentOnTint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.spacing.m)
        .background(DS.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var headlines: some View {
        let lines = recap.sections.filter { !$0.failed && !$0.headline.isEmpty }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: DS.spacing.xs) {
                ForEach(lines) { section in
                    (Text(section.projectName).fontWeight(.semibold) + Text(": \(section.headline)"))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - A project's section

struct WeeklySectionBlock: View {
    let section: WeeklySection
    let isOffline: Bool
    let onRewrite: () -> Void

    @State private var showsDays = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.projectName.isEmpty ? section.projectId : section.projectName).font(.headline)
                Text(section.countLine).font(.subheadline).foregroundStyle(.secondary)
            }
            if section.failed {
                Label("This section couldn't be written.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(DS.error)
            } else if !section.wins.isEmpty {
                Text(ChatStyledText.make(section.wins))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let gaps = section.gapsCaption {
                Label(gaps, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DS.spacing.l) {
                Button { withAnimation(.snappy) { showsDays.toggle() } } label: {
                    HStack(spacing: DS.spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showsDays ? 90 : 0))
                        Text("From \(WeeklySection.plural(section.updateCount, "daily update"))")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(action: onRewrite) {
                    Label(section.rewriting ? "Rewriting…" : "Rewrite", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(section.rewriting || isOffline)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            if showsDays {
                VStack(alignment: .leading, spacing: DS.spacing.xs) {
                    ForEach(section.days) { day in
                        HStack {
                            Text(UpdateDay.label(day.day))
                            Spacer()
                            Label(Self.stateText(day.state), systemImage: Self.stateIcon(day.state))
                                .foregroundStyle(day.state == "failed" ? AnyShapeStyle(DS.error) : AnyShapeStyle(.secondary))
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.leading, DS.spacing.l)
            }
        }
        .padding(DS.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.chipFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    static func stateText(_ state: String) -> String {
        switch state {
        case "update": "Daily update"
        case "quiet": "Quiet day"
        case "failed": "Couldn't be written"
        case "missing": "Missing"
        case "untracked": "Not tracked yet"
        default: state
        }
    }

    static func stateIcon(_ state: String) -> String {
        switch state {
        case "update": "checkmark.circle"
        case "quiet": "moon"
        case "failed": "exclamationmark.circle"
        case "missing": "questionmark.circle"
        default: "minus.circle"
        }
    }
}

// MARK: - Scheduled jobs

struct WeeklyJobsBlock: View {
    let jobs: WeeklyJobs
    let onOpenTodo: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.s) {
            Text("Scheduled jobs").font(.headline)
            totals.font(.subheadline).foregroundStyle(.secondary)
            if let did = didForYou {
                Label("What they did for you: \(did)", systemImage: "sparkles")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.spacing.s) {
                ForEach(jobs.jobs) { job in
                    WeeklyJobRow(job: job, onOpenTodo: onOpenTodo)
                }
            }
            .padding(.top, DS.spacing.xs)
        }
        .padding(DS.spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.chipFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var totals: Text {
        var text = Text("\(WeeklySection.plural(jobs.runs, "run")) · \(jobs.done) succeeded · ")
        let failed = Text("\(jobs.failed) failed")
        text = text + (jobs.failed > 0 ? failed.foregroundStyle(DS.error) : failed)
        return text + Text(" · \(jobs.skipped) skipped")
    }

    private var didForYou: String? {
        var parts: [String] = []
        if jobs.todosCreated > 0 { parts.append("\(WeeklySection.plural(jobs.todosCreated, "todo")) created") }
        if jobs.conversationsStarted > 0 { parts.append("\(WeeklySection.plural(jobs.conversationsStarted, "conversation")) started") }
        if jobs.findings > 0 { parts.append("\(WeeklySection.plural(jobs.findings, "new finding"))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct WeeklyJobRow: View {
    let job: WeeklyJob
    let onOpenTodo: (String) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacing.xs) {
            Button { withAnimation(.snappy) { isExpanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.spacing.s) {
                            Text(job.name).fontWeight(.medium)
                            if !job.projectName.isEmpty {
                                Text(job.projectName).foregroundStyle(.secondary)
                            }
                        }
                        counts.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: DS.spacing.xs) {
                    if job.lines.isEmpty {
                        Text("No runs kept for this week.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(job.lines) { line in
                        runLine(line)
                    }
                }
                .padding(.leading, DS.spacing.xl)
            }
        }
    }

    private var counts: Text {
        var text = Text("\(WeeklySection.plural(job.runs, "run")) · ✓ \(job.done) · ")
        let failed = Text("✗ \(job.failed)")
        text = text + (job.failed > 0 ? failed.foregroundStyle(DS.error) : failed) + Text(" · \(job.skipped) skip")
        if job.isWatch {
            text = text + Text(" · checked \(job.checks) time\(job.checks == 1 ? "" : "s")")
            if job.findings > 0 { text = text + Text(" · \(job.findings) new") }
        }
        return text
    }

    @ViewBuilder
    private func runLine(_ line: WeeklyRunLine) -> some View {
        let failed = line.state == "failed" || line.state == "missed"
        let content = HStack(alignment: .firstTextBaseline, spacing: DS.spacing.s) {
            Image(systemName: failed ? "xmark.circle" : line.state == "skipped" ? "forward.circle" : "checkmark.circle")
                .foregroundStyle(failed ? AnyShapeStyle(DS.error) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(line.outcome.isEmpty ? line.state.capitalized : line.outcome)
                    .foregroundStyle(failed ? AnyShapeStyle(DS.error) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                Text(HubDates.date(from: line.dueAt)?.formatted(.dateTime.weekday(.abbreviated).hour().minute()) ?? line.dueAt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if line.todoId != nil {
                Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .contentShape(Rectangle())
        if let todoId = line.todoId {
            Button { onOpenTodo(todoId) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Preview

#if DEBUG
enum WeeklyFixtures {
    static let recaps: [WeeklyRecap] = [
        WeeklyRecap(
            week: "2026-11-02",
            totals: WeeklyTotals(commits: 41, conversations: 23, runs: 9),
            sections: [
                WeeklySection(
                    projectId: "hub", projectName: "AI Session", headline: "You shipped daily updates and the scheduler's job plugins.",
                    wins: "- You shipped **daily updates** to all three Macs.\n- You cut hook latency from 4 s to 0.2 s by fixing PATH bloat.\n- You landed scheduler stages 1–5, hub v20.",
                    commits: 34, conversations: 17, daysWithWork: 4,
                    days: [
                        WeeklyDayState(day: "2026-11-02", state: "untracked"), WeeklyDayState(day: "2026-11-03", state: "untracked"),
                        WeeklyDayState(day: "2026-11-04", state: "update"), WeeklyDayState(day: "2026-11-05", state: "missing"),
                        WeeklyDayState(day: "2026-11-06", state: "missing"), WeeklyDayState(day: "2026-11-07", state: "update"),
                        WeeklyDayState(day: "2026-11-08", state: "quiet"),
                    ]
                ),
                WeeklySection(
                    projectId: "sigma", projectName: "Sigma", failed: true, commits: 7, conversations: 6, daysWithWork: 3,
                    days: [
                        WeeklyDayState(day: "2026-11-04", state: "failed"), WeeklyDayState(day: "2026-11-05", state: "update"),
                    ]
                ),
            ],
            jobs: WeeklyJobs(
                runs: 9, done: 7, failed: 1, skipped: 1, todosCreated: 3, conversationsStarted: 2, findings: 2,
                jobs: [
                    WeeklyJob(jobId: "j1", name: "Sentry watcher", projectName: "Sigma", isWatch: true, runs: 2, done: 2, checks: 40, findings: 2,
                              lines: [WeeklyRunLine(runId: "r1", dueAt: "2026-11-04 09:00:00", state: "done", outcome: "Fix null user in checkout", todoId: "t1")]),
                    WeeklyJob(jobId: "j2", name: "Upkeep", projectName: "AI Session", runs: 7, done: 5, failed: 1, skipped: 1,
                              lines: [WeeklyRunLine(runId: "r2", dueAt: "2026-11-05 07:00:00", state: "failed", outcome: "Runner timed out")]),
                ]
            )
        ),
        WeeklyRecap(week: "2026-10-26", totals: WeeklyTotals(commits: 28, conversations: 15, runs: 6)),
    ]
}

#Preview("Weekly") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.spacing.xl) {
            WeeklyWeekCard(recap: WeeklyFixtures.recaps[0], isExpanded: .constant(true), isOffline: false, onRewrite: { _ in }, onOpenTodo: { _ in })
            WeeklyWeekCard(recap: WeeklyFixtures.recaps[1], isExpanded: .constant(false), isOffline: false, onRewrite: { _ in }, onOpenTodo: { _ in })
        }
        .padding(DS.spacing.l)
    }
    .frame(width: 520, height: 1100)
}
#endif
