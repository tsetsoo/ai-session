import AISessionCore
import SwiftUI

// Memories: rows, the editor sheet and the pin / archive / delete actions. Used by project
// pages and by the panel next to a conversation's terminal.

/// What the memory editor sheet edits.
enum MemoryEditorTarget: Identifiable {
    /// A manual memory for a project and/or todo (at least one is required by the hub).
    case new(projectId: String?, todoId: String?)
    case edit(Memory)

    var id: String {
        switch self {
        case let .new(projectId, todoId): "new|\(projectId ?? "")|\(todoId ?? "")"
        case let .edit(memory): memory.id
        }
    }
}

/// Sheet, confirmation and error state for memory actions. The owning screen attaches it with
/// `.memoryActions(_:store:)`; rows only call its methods.
@MainActor
@Observable
final class MemoryActions {
    var editing: MemoryEditorTarget?
    var deleting: Memory?
    var errorMessage: String?

    func togglePin(_ memory: Memory, store: TodoHubStore) {
        run(store) { try await store.updateMemory(memory, UpdateMemoryRequest(pinned: !memory.pinned)) }
    }

    func toggleArchive(_ memory: Memory, store: TodoHubStore) {
        run(store) { try await store.updateMemory(memory, UpdateMemoryRequest(archived: !memory.archived)) }
    }

    func confirmDelete(store: TodoHubStore) {
        guard let memory = deleting else { return }
        deleting = nil
        run(store) { try await store.deleteMemory(memory) }
    }

    private func run(_ store: TodoHubStore, _ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}

extension View {
    /// Presents the editor sheet, the delete confirmation and errors for `actions`.
    func memoryActions(_ actions: MemoryActions, store: TodoHubStore) -> some View {
        modifier(MemoryActionsModifier(actions: actions, store: store))
    }
}

private struct MemoryActionsModifier: ViewModifier {
    @Bindable var actions: MemoryActions
    let store: TodoHubStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.editing) { target in
                MemoryEditorSheet(target: target, store: store)
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                titleVisibility: .visible,
                presenting: actions.deleting
            ) { _ in
                Button("Delete Memory", role: .destructive) { actions.confirmDelete(store: store) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This can't be undone, and the memory may be extracted again later. Archive it instead to keep it hidden.")
            }
            .alert(
                "Memories",
                isPresented: Binding(get: { actions.errorMessage != nil }, set: { if !$0 { actions.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.errorMessage ?? "")
            }
    }
}

/// One memory: text, files, date, and markers for pinned / archived / manual.
struct MemoryRow: View {
    let memory: Memory
    /// Show the kind's icon (in lists that aren't grouped by kind).
    var showsKind = false
    /// Clamp the text (imported memory files run to thousands of characters).
    var lineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if memory.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(DS.accent)
                        .accessibilityLabel("Pinned")
                }
                if showsKind {
                    Image(systemName: memory.kind.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(memory.kind.label)
                }
                Text(memory.text)
                    .lineLimit(lineLimit)
                    .foregroundStyle(memory.archived ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !memory.files.isEmpty {
                Text(memory.files.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                if let ago = AppTheme.relativeTime(from: memory.createdDate) {
                    Text(ago)
                }
                if memory.isManual {
                    Text("· added by hand")
                } else if let tool = memory.tool {
                    Text("· \(RemoteConversationPicker.toolName(tool))")
                }
                if memory.archived {
                    Text("· archived")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A tappable memory row with swipe and context-menu actions.
struct MemoryActionRow: View {
    let memory: Memory
    let actions: MemoryActions
    let store: TodoHubStore
    var showsKind = false
    var lineLimit: Int?

    var body: some View {
        MemoryRow(memory: memory, showsKind: showsKind, lineLimit: lineLimit)
            .contentShape(Rectangle())
            .onTapGesture { actions.editing = .edit(memory) }
            .contextMenu { menuItems }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { actions.togglePin(memory, store: store) } label: {
                    Label(memory.pinned ? "Unpin" : "Pin", systemImage: memory.pinned ? "pin.slash" : "pin")
                }
                .tint(DS.accentSolid)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { actions.deleting = memory } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { actions.toggleArchive(memory, store: store) } label: {
                    Label(memory.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
            .disabled(store.isOffline)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { actions.editing = .edit(memory) } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button { actions.togglePin(memory, store: store) } label: {
            Label(memory.pinned ? "Unpin" : "Pin", systemImage: memory.pinned ? "pin.slash" : "pin")
        }
        Button { actions.toggleArchive(memory, store: store) } label: {
            Label(memory.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
        }
        Button(role: .destructive) { actions.deleting = memory } label: {
            Label("Delete…", systemImage: "trash")
        }
    }
}

/// List sections, one per memory kind (open threads, decisions, gotchas, done, files changed).
struct MemoryGroupSections: View {
    let memories: [Memory]
    let actions: MemoryActions
    let store: TodoHubStore

    var body: some View {
        ForEach(MemoryGrouping.grouped(memories)) { group in
            Section {
                ForEach(group.memories) { memory in
                    MemoryActionRow(memory: memory, actions: actions, store: store)
                }
            } header: {
                Label(group.kind.title, systemImage: group.kind.systemImage)
            }
        }
    }
}

/// Create or edit a memory: kind, text (≤ 400 characters) and files (one per line).
struct MemoryEditorSheet: View {
    let target: MemoryEditorTarget
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MemoryKind = .decision
    @State private var text = ""
    @State private var filesText = ""
    @State private var pinned = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var loaded = false

    private static let maxLength = 400

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(MemoryKind.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                }
                Section {
                    FormTextField("One or two sentences", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("\(trimmedText.count)/\(Self.maxLength)")
                        .foregroundStyle(trimmedText.count > Self.maxLength ? DS.error : Color.secondary)
                }
                Section {
                    FormTextField("path/relative/to/project", text: $filesText, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Files")
                } footer: {
                    Text("One per line, relative to the project folder.")
                }
                if case .new = target {
                    Toggle("Pinned", isOn: $pinned)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.error)
                        .font(.subheadline)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var files: [String] {
        filesText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !isSaving && !trimmedText.isEmpty && trimmedText.count <= Self.maxLength && files.count <= 20
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case let .edit(memory) = target {
            kind = memory.kind
            text = memory.text
            filesText = memory.files.joined(separator: "\n")
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                switch target {
                case let .new(projectId, todoId):
                    try await store.createMemory(CreateMemoryRequest(
                        kind: kind, text: trimmedText, files: files.isEmpty ? nil : files,
                        projectId: projectId, todoId: todoId, pinned: pinned ? true : nil
                    ))
                case let .edit(memory):
                    let request = UpdateMemoryRequest(
                        text: trimmedText == memory.text ? nil : trimmedText,
                        kind: kind == memory.kind ? nil : kind,
                        files: files == memory.files ? nil : files
                    )
                    if request.text != nil || request.kind != nil || request.files != nil {
                        try await store.updateMemory(memory, request)
                    }
                }
                dismiss()
            } catch {
                self.error = TodoHubStore.message(for: error)
            }
        }
    }
}

/// A section title in the memories panel's lazy stack.
private struct PanelSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    /// A row or group in the memories panel, drawn like a grouped list cell.
    func panelCard() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What the memories panel last showed for a conversation (`TodoHubStore.cachedMemoryPanel`).
struct MemoryPanelSnapshot {
    var mine: [Memory]
    var page: MemoryPage
    var limit: Int
    var pending: [Memory]
}

/// The memories panel next to a conversation's terminal (an inspector on the Mac, a sheet on
/// iOS): this conversation's memories first, then the project's newest extracted ones a page
/// at a time. Without a project it shows the todo's memories. Imported Claude memory files are
/// long and search-only: they load only when their section is opened, clamped to two lines.
/// A project can hold hundreds of memories, and laying all of them out stalled the window.
struct MemoriesPanel: View {
    let todoId: String
    let store: TodoHubStore
    /// The conversation on screen (not the todo's most urgent one): "This conversation" and
    /// the cache follow it. The presenter gives the panel a new identity when it changes.
    let conversation: Conversation

    @State private var mine: [Memory]
    @State private var page: MemoryPage?
    @State private var limit: Int
    @State private var pending: [Memory]
    @State private var showsImported = false
    @State private var imported: MemoryPage?
    @State private var importedLimit = MemoryPage.pageSize
    @State private var loadError: String?
    @State private var importedError: String?
    @State private var showArchived = false
    @State private var actions = MemoryActions()

    private static let mineLimit = 200

    /// Starts from what this conversation showed last time, so switching back is instant.
    /// Restoring here, before the load task starts, keeps that task from running twice.
    init(todoId: String, store: TodoHubStore, conversation: Conversation) {
        self.todoId = todoId
        self.store = store
        self.conversation = conversation
        let key = Self.cacheKey(todoId: todoId, store: store, conversation: conversation, showArchived: false)
        let snapshot = store.cachedMemoryPanel(key)
        _mine = State(initialValue: snapshot?.mine ?? [])
        _page = State(initialValue: snapshot?.page)
        _limit = State(initialValue: snapshot?.limit ?? MemoryPage.pageSize)
        _pending = State(initialValue: snapshot?.pending ?? [])
    }

    private static func projectId(todoId: String, store: TodoHubStore, conversation: Conversation) -> String? {
        conversation.projectId ?? store.todos.first { $0.id == todoId }?.projectId
    }

    private static func cacheKey(todoId: String, store: TodoHubStore, conversation: Conversation,
                                 showArchived: Bool) -> String {
        let project = projectId(todoId: todoId, store: store, conversation: conversation) ?? ""
        return "\(todoId)|\(conversation.id)|\(conversation.sessionId)|\(project)|\(showArchived)"
    }

    private var projectId: String? {
        Self.projectId(todoId: todoId, store: store, conversation: conversation)
    }

    private var cacheKey: String {
        Self.cacheKey(todoId: todoId, store: store, conversation: conversation, showArchived: showArchived)
    }

    /// Changes the archived filter and, in the same update, swaps in that view's cached rows
    /// (or clears them) with a fresh limit, so the old rows never pose as the new result and
    /// the load task starts once.
    private var showArchivedBinding: Binding<Bool> {
        Binding(get: { showArchived }, set: { value in
            showArchived = value
            let snapshot = store.cachedMemoryPanel(cacheKey)
            mine = snapshot?.mine ?? []
            page = snapshot?.page
            limit = snapshot?.limit ?? MemoryPage.pageSize
            pending = snapshot?.pending ?? []
            imported = nil
            importedLimit = MemoryPage.pageSize
        })
    }

    /// The project's memories, or the todo's when there is no project.
    private func scoped(_ query: MemoryQuery) -> MemoryQuery {
        var query = query
        query.projectId = projectId
        query.todoId = projectId == nil ? todoId : nil
        query.includeArchived = showArchived
        return query
    }

    var body: some View {
        // A lazy stack, not a List: on the Mac a List is a table that builds and measures every
        // row when it is filled, and the panel is refilled on every conversation switch. Here
        // only the rows on screen are built. Rows are direct children so they stay lazy.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 10) {
                    if let project = store.project(id: projectId) {
                        LabeledContent("Project", value: project.name)
                    } else {
                        Text("This conversation isn't in a project. Showing its todo's memories.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show archived", isOn: showArchivedBinding)
                    Button {
                        actions.editing = .new(projectId: projectId, todoId: todoId)
                    } label: {
                        Label("Add Memory", systemImage: "plus")
                    }
                    .disabled(store.isOffline)
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(DS.warning)
                    }
                }
                .panelCard()
                PendingMemoriesSection(memories: pending, store: store)
                content
                importedSection
            }
            .padding(12)
        }
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(cacheKey)|\(store.revision)|\(limit)") { await load() }
        .task(id: "\(cacheKey)|\(store.revision)|\(showsImported)|\(importedLimit)") {
            if showsImported { await loadImported() }
        }
        .memoryActions(actions, store: store)
    }

    @ViewBuilder
    private var content: some View {
        if let page {
            let mineIDs = Set(mine.map(\.id))
            let others = page.memories.filter { !mineIDs.contains($0.id) && $0.sessionId != conversation.sessionId }
            if mine.isEmpty && others.isEmpty {
                Text("No memories yet. They're extracted after the conversation goes idle.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if !mine.isEmpty {
                PanelSectionHeader(title: "This conversation", systemImage: "bubble.left")
                ForEach(mine) { memory in
                    MemoryActionRow(memory: memory, actions: actions, store: store, showsKind: true)
                        .panelCard()
                }
            }
            ForEach(MemoryGrouping.grouped(others)) { group in
                PanelSectionHeader(title: group.kind.title, systemImage: group.kind.systemImage)
                ForEach(group.memories) { memory in
                    MemoryActionRow(memory: memory, actions: actions, store: store)
                        .panelCard()
                }
            }
            if page.hasMore {
                Button("Show More") { limit = MemoryPage.nextLimit(after: limit) }
                    .padding(.top, 4)
            }
        } else if loadError == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 8)
        }
    }

    @ViewBuilder
    private var importedSection: some View {
        PanelSectionHeader(title: "Imported memory files", systemImage: "doc.text")
        Button {
            showsImported.toggle()
        } label: {
            Label(showsImported ? "Hide" : "Show", systemImage: showsImported ? "chevron.down" : "chevron.right")
        }
        Text("Claude's own memory files, imported for search. Agents look them up; they aren't in the session index.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        if showsImported {
            if let importedError {
                Label(importedError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(DS.warning)
            }
            if let imported {
                if imported.memories.isEmpty {
                    Text("No imported memory files.").foregroundStyle(.secondary)
                }
                ForEach(imported.memories) { memory in
                    MemoryActionRow(memory: memory, actions: actions, store: store, showsKind: true, lineLimit: 2)
                        .panelCard()
                }
                if imported.hasMore {
                    Button("Show More") { importedLimit = MemoryPage.nextLimit(after: importedLimit) }
                }
            } else if importedError == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func load() async {
        let sessionId = conversation.sessionId
        let projectId = projectId
        let key = cacheKey
        let limit = limit
        do {
            async let mineRows: [Memory] = sessionId.isEmpty ? [] : store.memories(MemoryQuery(
                sessionId: sessionId, includeArchived: showArchived, limit: Self.mineLimit,
                excludeSources: [MemoryPage.importedSource]
            ))
            // This conversation's memories have their own section: leaving them out here keeps
            // them from filling the project's page (and its "Show More") with hidden rows.
            async let pageRows = store.memories(scoped(MemoryQuery(
                limit: limit + 1, excludeSources: [MemoryPage.importedSource],
                excludeSessionId: sessionId.isEmpty ? nil : sessionId
            )))
            async let pendingRows: [Memory] = projectId == nil
                ? [] : ((try? await store.pendingMemories(projectId: projectId)) ?? [])
            // A hub from before `exclude_source` returns imported files anyway.
            let fetchedMine = try await mineRows.filter { $0.source != MemoryPage.importedSource }
            let fetchedPage = MemoryPage(fetched: try await pageRows, limit: limit, excludingImported: true)
            let fetchedPending = await pendingRows
            guard !Task.isCancelled else { return }
            mine = MemoryGrouping.sorted(fetchedMine)
            page = fetchedPage
            pending = fetchedPending
            loadError = nil
            store.cacheMemoryPanel(
                MemoryPanelSnapshot(mine: mine, page: fetchedPage, limit: limit, pending: fetchedPending), for: key
            )
        } catch {
            guard !Task.isCancelled else { return }
            loadError = TodoHubStore.message(for: error)
        }
    }

    private func loadImported() async {
        let limit = importedLimit
        do {
            let rows = try await store.memories(scoped(MemoryQuery(
                limit: limit + 1, sources: [MemoryPage.importedSource]
            )))
            guard !Task.isCancelled else { return }
            imported = MemoryPage(fetched: rows, limit: limit, onlyImported: true)
            importedError = nil
        } catch {
            guard !Task.isCancelled else { return }
            importedError = TodoHubStore.message(for: error)
        }
    }
}

/// Facts an agent saved with `ai-todo-memory add`: they wait here until approved (then they
/// join the index new conversations get) or rejected (deleted). Hidden when there are none.
struct PendingMemoriesSection: View {
    let memories: [Memory]
    let store: TodoHubStore

    @State private var errorMessage: String?

    var body: some View {
        if !memories.isEmpty {
            Section {
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(memory.text, systemImage: memory.kind.systemImage)
                        HStack {
                            Button("Approve") {
                                run { try await store.updateMemory(memory, UpdateMemoryRequest(pending: false)) }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Reject", role: .destructive) {
                                run { try await store.deleteMemory(memory) }
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(store.isOffline)
                    }
                    .padding(.vertical, 2)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(DS.warning)
                }
            } header: {
                Text("Waiting for OK (\(memories.count))")
            } footer: {
                Text("An agent saved these. Approved facts join the index new conversations get.")
            }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                errorMessage = nil
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}
