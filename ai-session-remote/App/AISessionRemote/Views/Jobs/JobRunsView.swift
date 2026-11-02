import AISessionCore
import SwiftUI

/// A job's runs, newest first: when, state, why it waits or failed, and the todo it made.
struct JobRunsView: View {
    let store: TodoHubStore
    let job: SchedulerJob

    @Environment(\.dismiss) private var dismiss
    @State private var runs: [JobRun]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
            }
            if let runs {
                if runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(run.state.capitalized)
                            Spacer()
                            Text(HubDates.date(from: run.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? run.dueAt)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = run.waitingReason ?? run.result {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let todoId = run.todoId, let todo = store.todos.first(where: { $0.id == todoId }) {
                            Label(todo.title, systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(job.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task(id: store.revision) {
            do {
                runs = try await store.jobRuns(job)
                errorMessage = nil
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}
