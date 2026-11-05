import AISessionCore
import SwiftUI

/// A project's daily updates (each morning, the previous day's work, 08:00 to 08:00), newest
/// first. Each day: the update, Copy (its Markdown), Rewrite, and the conversation summaries it
/// was written from. Shown only when the project has daily updates on.
struct ProjectUpdatesSection: View {
    let project: Project
    let store: TodoHubStore
    let onOpenTodo: (Todo) -> Void
    /// Scrolls the page to a row id (a day opened from Weekly).
    var onReveal: (String) -> Void = { _ in }

    @Environment(AppModel.self) private var model

    @State private var updates: [ProjectUpdate]?
    @State private var canLoadOlder = false
    @State private var expanded: Set<String> = []
    @State private var summaries: [String: [UpdateSummary]] = [:]
    @State private var shownSummaries: Set<String> = []
    @State private var copied: String?
    @State private var errorMessage: String?
    @State private var isLoadingOlder = false

    private static let pageSize = 14

    var body: some View {
        Section {
            if let updates {
                if updates.isEmpty {
                    Text("No updates yet. Each morning after 08:00, the previous day's work shows here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(updates) { update in
                    day(update)
                }
                if canLoadOlder {
                    Button("Show Older") { Task { await loadOlder() } }
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
        } header: {
            Text("Updates")
        }
        .task(id: "\(project.id)|\(store.revision)") {
            // Hub broadcasts come in bursts while conversations run: wait for a quiet moment
            // (a newer revision cancels this task) before reloading.
            if updates != nil {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            await loadFirstPage()
        }
        .task(id: model.updateDayRequest) {
            // A day opened from Weekly while this page was already showing.
            if updates != nil { await revealRequestedDay() }
        }
    }

    // MARK: A day

    private func day(_ update: ProjectUpdate) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(update.day) },
            set: { open in if open { expanded.insert(update.day) } else { expanded.remove(update.day) } }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                Text(ChatStyledText.make(update.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if update.failed > 0 {
                    Label(update.failed == 1 ? "1 conversation couldn't be summarized"
                          : "\(update.failed) conversations couldn't be summarized", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !update.waitingOn.isEmpty {
                    Label("Waiting on: \(update.waitingOn.joined(separator: ", "))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Button {
                        PlatformSupport.pasteboardString = update.text
                        copied = update.day
                    } label: {
                        Label(copied == update.day ? "Copied" : "Copy", systemImage: copied == update.day ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        Task { await rewrite(update) }
                    } label: {
                        Label(update.rewriting ? "Rewriting…" : "Rewrite", systemImage: "arrow.clockwise")
                    }
                    .disabled(update.rewriting || store.isOffline)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                sources(update)
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text(UpdateDay.label(update.day)).font(.headline)
                if update.rewriting {
                    Text("Rewriting…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .id(Self.rowID(update.day))
    }

    private func sources(_ update: ProjectUpdate) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { shownSummaries.contains(update.day) },
            set: { open in
                if open {
                    shownSummaries.insert(update.day)
                    Task { await loadSummaries(update.day) }
                } else {
                    shownSummaries.remove(update.day)
                }
            }
        )) {
            if let rows = summaries[update.day] {
                ForEach(rows) { row in
                    summaryRow(row)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } label: {
            Text("\(update.conversations) conversations · \(update.commits) commits")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ row: UpdateSummary) -> some View {
        let todo = row.todoId.flatMap { id in store.todos.first(where: { $0.id == id }) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title.isEmpty ? "Untitled conversation" : row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if row.todoId == nil {
                    Text("terminal only").font(.caption).foregroundStyle(.secondary)
                } else if todo == nil {
                    Text("todo archived or deleted").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(row.failed ? "Couldn't be summarized." : row.summary).font(.callout).foregroundStyle(.secondary)
            Text("\(row.tool) · \(row.computer)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if let todo { onOpenTodo(todo) } }
    }

    // MARK: Loading

    private func loadFirstPage() async {
        do {
            let page = try await store.projectUpdates(projectId: project.id, before: nil, limit: Self.pageSize)
            guard !Task.isCancelled else { return }
            // Keep older pages already shown; replace the newest page.
            let older = (updates ?? []).filter { u in page.last.map { u.day < $0.day } ?? false }
            // The newest day opens when it first shows up (on first load, or a new morning's).
            if let newest = page.first, newest.day != updates?.first?.day { expanded.insert(newest.day) }
            updates = UpdateDay.appending(page, older)
            if updates?.count == page.count { canLoadOlder = page.count == Self.pageSize }
            for day in shownSummaries { await loadSummaries(day) }
            errorMessage = nil
            await revealRequestedDay()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = TodoHubStore.message(for: error)
            if updates == nil { updates = [] }
        }
    }

    /// A day opened from Weekly: expand it (loading older pages until it shows, up to 90 days)
    /// and scroll to it.
    private func revealRequestedDay() async {
        guard let request = model.updateDayRequest, request.projectId == project.id else { return }
        model.updateDayRequest = nil
        while canLoadOlder, let last = updates?.last, last.day > request.day, !Task.isCancelled {
            await loadOlder()
            guard updates?.last?.day != last.day else { break }
        }
        guard updates?.contains(where: { $0.day == request.day }) == true else { return }
        expanded.insert(request.day)
        try? await Task.sleep(for: .milliseconds(150))
        onReveal(Self.rowID(request.day))
    }

    static func rowID(_ day: String) -> String { "update-\(day)" }

    private func loadOlder() async {
        guard !isLoadingOlder, let last = updates?.last else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await store.projectUpdates(projectId: project.id, before: last.day, limit: Self.pageSize)
            updates = UpdateDay.appending(updates ?? [], page)
            canLoadOlder = page.count == Self.pageSize
        } catch {
            errorMessage = TodoHubStore.message(for: error)
        }
    }

    private func loadSummaries(_ day: String) async {
        do {
            summaries[day] = try await store.updateSummaries(projectId: project.id, day: day)
        } catch {
            errorMessage = TodoHubStore.message(for: error)
        }
    }

    private func rewrite(_ update: ProjectUpdate) async {
        do {
            try await store.rewriteUpdate(projectId: project.id, day: update.day)
            if let index = updates?.firstIndex(where: { $0.day == update.day }) {
                updates?[index].rewriting = true
            }
        } catch {
            errorMessage = TodoHubStore.message(for: error)
        }
    }
}
