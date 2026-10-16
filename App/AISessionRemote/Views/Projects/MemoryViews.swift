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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if memory.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
                if showsKind {
                    Image(systemName: memory.kind.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(memory.kind.label)
                }
                Text(memory.text)
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

    var body: some View {
        MemoryRow(memory: memory, showsKind: showsKind)
            .contentShape(Rectangle())
            .onTapGesture { actions.editing = .edit(memory) }
            .contextMenu { menuItems }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { actions.togglePin(memory, store: store) } label: {
                    Label(memory.pinned ? "Unpin" : "Pin", systemImage: memory.pinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
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
                    TextField("One or two sentences", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("\(trimmedText.count)/\(Self.maxLength)")
                        .foregroundStyle(trimmedText.count > Self.maxLength ? .red : .secondary)
                }
                Section {
                    TextField("path/relative/to/project", text: $filesText, axis: .vertical)
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
                        .foregroundStyle(.red)
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
