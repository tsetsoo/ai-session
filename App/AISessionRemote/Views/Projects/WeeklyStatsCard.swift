import AISessionCore
import SwiftUI

/// "This week" for a project: active time, prompts, turns, tokens, sessions and files, with a
/// stepper to earlier weeks. Weeks run Monday to Sunday.
struct WeeklyStatsCard: View {
    let projectId: String?
    let store: TodoHubStore

    @State private var weekStart = WeekMath.monday(of: .now)
    @State private var stats: WeeklyStats?
    @State private var error: String?

    private var thisWeek: String { WeekMath.monday(of: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let stats {
                grid(stats.totals)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .task(id: "\(projectId ?? "")|\(weekStart)|\(store.revision)") { await load() }
    }

    private var header: some View {
        HStack {
            Text(weekStart == thisWeek ? "This week" : weekTitle)
                .font(.headline)
            Spacer()
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous week")
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next week")
            .disabled(weekStart >= thisWeek)
        }
        .buttonStyle(.borderless)
    }

    private var weekTitle: String {
        guard let start = WeekMath.date(from: weekStart),
              let endDay = WeekMath.addingDays(6, to: weekStart),
              let end = WeekMath.date(from: endDay)
        else { return weekStart }
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }

    private func grid(_ totals: StatsCounters) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 12) {
            metric("Active", StatsFormat.duration(seconds: totals.activeSeconds))
            metric("Prompts", "\(totals.prompts)")
            metric("Turns", "\(totals.assistantTurns)")
            metric("Output tokens", StatsFormat.tokens(totals.outputTokens))
            metric("Total tokens", StatsFormat.tokens(totals.totalTokens))
            metric("Sessions", "\(totals.sessions)")
            metric("Files", "\(totals.filesTouched)")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    private func step(_ weeks: Int) {
        guard let moved = WeekMath.shift(weekStart, byWeeks: weeks), moved <= thisWeek else { return }
        stats = nil
        weekStart = moved
    }

    private func load() async {
        do {
            let result = try await store.weekly(projectId: projectId, weekStart: weekStart)
            stats = result
            error = nil
        } catch {
            // A newer load (another week, a live update) replaced this one.
            guard !Task.isCancelled else { return }
            self.error = TodoHubStore.message(for: error)
        }
    }
}
