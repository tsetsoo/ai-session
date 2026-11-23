import AISessionCore
import SwiftData
import SwiftUI

/// Creates or edits a project on a computer.
struct ProjectEditorSheet: View {
    enum Mode: Identifiable {
        case create(ProjectSuggestion?, computerID: String? = nil)
        case edit(Project)

        var id: String {
            switch self {
            case let .create(suggestion, computerID): "create|\(suggestion?.id ?? computerID ?? "")"
            case let .edit(project): "edit|\(project.id)"
            }
        }
    }

    let mode: Mode
    let store: TodoHubStore
    /// Called with the created project (not after an edit).
    var onCreated: (Project) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var browsing: BrowseRequest?
    @State private var browseError: String?
    @State private var repoWasEdited = false
    @State private var detectedRepo = ""
    @State private var detectedLookup: OriginLookup?
    @State private var detectingRepo = false

    @State private var computerID: String?
    @State private var name = ""
    @State private var suggestedName = ""
    @State private var folder = ""
    @State private var repoUrl = ""
    @State private var digestEnabled = true
    @State private var error: String?
    @State private var isSaving = false
    @State private var loaded = false
    @State private var mcpDefault: [String]?
    @State private var dailyUpdates = false
    @State private var updateStyle = ""
    @State private var worktrees = true

    var body: some View {
        let lookup = originLookup
        NavigationStack {
            Form {
                Section {
                    if case let .edit(project) = mode {
                        LabeledContent("Computer", value: project.computer.name)
                    } else if case let .create(_, fixedID?) = mode {
                        LabeledContent("Computer", value: store.computers.first { $0.id == fixedID }?.name ?? "Computer")
                    } else {
                        Picker("Computer", selection: $computerID) {
                            Text("Choose").tag(String?.none)
                            ForEach(store.computers) { computer in
                                Text(computer.name).tag(Optional(computer.id))
                            }
                        }
                    }
                    FormTextField("Name", text: $name)
                    FormTextField("Folder, e.g. ~/programming/app", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Browse Folders…", systemImage: "folder") { browse() }
                        .disabled(selectedComputer == nil)
                    if let browseError {
                        Text(browseError).foregroundStyle(DS.error)
                    }
                } footer: {
                    Text("The folder lives on this computer. A nested folder is its own project.")
                }
                Section {
                    FormTextField("Repository URL (optional)", text: Binding(
                        get: { repoUrl },
                        set: {
                            repoWasEdited = true
                            repoUrl = $0
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if detectingRepo && !repoWasEdited {
                        ProgressView("Detecting Git remote…")
                    }
                }
                if case .edit = mode, !trimmed(repoUrl).isEmpty {
                    Section {
                        Toggle("New conversations get their own worktree", isOn: $worktrees)
                    } footer: {
                        Text(worktrees
                            ? "Each new conversation works on its own branch in ~/.ai-remote/worktrees, made from the latest origin. Files named in .worktreeinclude and .worktreelink come along. Existing conversations stay where they are."
                            : "New conversations share the project folder.")
                    }
                }
                Section {
                    Toggle("Feed memories into new conversations", isOn: $digestEnabled)
                } footer: {
                    Text("The computer writes a short digest of this project's memories where new Claude and Codex conversations in the folder load it.")
                }
                if case .edit = mode {
                    Section {
                        Toggle("Daily updates", isOn: $dailyUpdates)
                        if dailyUpdates {
                            ZStack(alignment: .topLeading) {
                                if updateStyle.isEmpty {
                                    Text("How the update should read. Empty: a plain bullet list.")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                }
                                TextEditor(text: $updateStyle)
                                    .frame(minHeight: 90)
                                    .scrollContentBackground(.hidden)
                            }
                            .accessibilityLabel("Update style")
                        }
                    } footer: {
                        Text("Each morning, a summary of yesterday's work (08:00 to 08:00) appears on this project's page.")
                    }
                }
                if case let .edit(project) = mode {
                    ProjectDefaultServersSection(project: project, store: store, selection: $mcpDefault)
                }
                if case let .create(suggestion?, _) = mode, !suggestion.exampleCwds.isEmpty {
                    Section("Seen in") {
                        ForEach(suggestion.exampleCwds, id: \.self) { cwd in
                            Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.error)
                        .font(.subheadline)
                }
            }
            .skinnedList()
            .formStyle(.grouped)
            .navigationTitle(isCreate ? "New Project" : "Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreate ? "Create" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
            .onChange(of: computerID) { _, _ in browseError = nil }
            .task(id: lookup) { await detectOrigin(lookup) }
            .sheet(item: $browsing) { request in
                ProjectFolderPicker(
                    computer: request.computer,
                    config: request.config,
                    initialFolder: request.folder,
                    registeredFolders: Set(store.projects.lazy
                        .filter { $0.computer.id == request.computer.id }.map(\.folder)),
                    onSelect: useFolder
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var selectedComputer: Computer? {
        if case let .edit(project) = mode { return project.computer }
        return store.computers.first { $0.id == computerID }
    }

    private struct BrowseRequest: Identifiable {
        let id = UUID()
        let computer: Computer
        let config: HostConnectionConfig
        let folder: String
    }

    private struct OriginLookup: Equatable {
        let computer: Computer
        let folder: String
    }

    private var originLookup: OriginLookup? {
        guard let computer = selectedComputer, loaded else { return nil }
        let path = trimmed(folder)
        guard path.hasPrefix("/") || path.hasPrefix("~/") || path == "~" else { return nil }
        return OriginLookup(computer: computer, folder: path)
    }

    private func browse() {
        guard let computer = selectedComputer else { return }
        browseError = nil
        do {
            let config = try HostLookup.config(for: computer, in: hosts)
            let path = trimmed(folder)
            browsing = BrowseRequest(computer: computer, config: config, folder: path.isEmpty ? "~" : path)
        } catch {
            browseError = TodoHubStore.message(for: error)
        }
    }

    private func useFolder(_ path: String) {
        if trimmed(name).isEmpty || name == suggestedName {
            suggestedName = path.split(separator: "/").last.map(String.init) ?? path
            name = suggestedName
        }
        folder = path
    }

    private func detectOrigin(_ lookup: OriginLookup?) async {
        guard !Task.isCancelled, originLookup == lookup else { return }
        detectingRepo = false
        guard !repoWasEdited, repoUrl.isEmpty || repoUrl == detectedRepo else { return }
        repoUrl = ""
        detectedRepo = ""
        detectedLookup = nil
        guard let lookup else { return }
        detectingRepo = true
        defer { if !Task.isCancelled { detectingRepo = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard !repoWasEdited, let config = try? HostLookup.config(for: lookup.computer, in: hosts) else { return }
            let result = try await NIOSSHClient(execTimeoutSeconds: 5).exec(
                config, command: TmuxCommandBuilder.projectOrigin(in: lookup.folder)
            )
            guard !Task.isCancelled, originLookup == lookup, !repoWasEdited, result.exitCode == 0 else { return }
            let origin = trimmed(result.stdout)
            if origin.contains("://") {
                guard var url = URLComponents(string: origin), let scheme = url.scheme?.lowercased() else { return }
                if scheme == "http" || scheme == "https" || url.password != nil {
                    url.user = nil
                    url.password = nil
                }
                detectedRepo = url.string ?? ""
            } else {
                detectedRepo = origin
            }
            detectedLookup = lookup
            repoUrl = detectedRepo
        } catch {
            // Git may be absent or this folder may be outside a repository. The URL stays optional.
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        guard !isSaving, !trimmed(name).isEmpty, !trimmed(folder).isEmpty else { return false }
        return !isCreate || ((repoWasEdited || !detectingRepo)
            && computerID != nil)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case let .create(suggestion, fixedID):
            if let suggestion {
                name = suggestion.name
                folder = suggestion.folder
                repoUrl = suggestion.repoUrl ?? ""
            }
            let eligible = store.computers
            computerID = fixedID ?? suggestion?.computer.id ?? (eligible.count == 1 ? eligible.first?.id : nil)
        case let .edit(project):
            name = project.name
            folder = project.folder
            repoUrl = project.repoUrl ?? ""
            digestEnabled = project.digestEnabled
            mcpDefault = project.mcpDefault
            dailyUpdates = project.dailyUpdates
            updateStyle = project.updateStyle
            worktrees = project.worktrees
        }
    }

    private func save() {
        isSaving = true
        error = nil
        let name = trimmed(name)
        let folder = trimmed(folder)
        let isStaleOrigin = !repoWasEdited && detectedLookup != nil && detectedLookup != originLookup
        let repo = isStaleOrigin ? "" : trimmed(repoUrl)
        Task {
            defer { isSaving = false }
            do {
                switch mode {
                case .create:
                    guard let computerID else { return }
                    let created = try await store.createProject(CreateProjectRequest(
                        name: name, computerId: computerID, folder: folder,
                        repoUrl: repo.isEmpty ? nil : repo, digestEnabled: digestEnabled
                    ))
                    dismiss()
                    if let created { onCreated(created) }
                case let .edit(project):
                    let request = UpdateProjectRequest(
                        name: name == project.name ? nil : name,
                        folder: folder == project.folder ? nil : folder,
                        repoUrl: repo == (project.repoUrl ?? "") ? nil : (repo.isEmpty ? .clear : .set(repo)),
                        digestEnabled: digestEnabled == project.digestEnabled ? nil : digestEnabled,
                        mcpDefault: mcpDefault == project.mcpDefault ? nil : (mcpDefault.map { .set($0) } ?? .clear),
                        dailyUpdates: dailyUpdates == project.dailyUpdates ? nil : dailyUpdates,
                        updateStyle: trimmed(updateStyle) == project.updateStyle ? nil : trimmed(updateStyle),
                        worktrees: worktrees == project.worktrees ? nil : worktrees
                    )
                    if request.name != nil || request.folder != nil || request.repoUrl != nil
                        || request.digestEnabled != nil || request.mcpDefault != nil
                        || request.dailyUpdates != nil || request.updateStyle != nil || request.worktrees != nil {
                        try await store.updateProject(project, request)
                    }
                    dismiss()
                }
            } catch {
                self.error = TodoHubStore.message(for: error)
            }
        }
    }
}

/// The project's default servers: "Same as computer" (nil) or a ticked list from the project's
/// computer. When that computer's list can't be read, the saved names show as plain text.
private struct ProjectDefaultServersSection: View {
    let project: Project
    let store: TodoHubStore
    @Binding var selection: [String]?

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var state = MCPServerListState.loading
    @State private var showingChecklist = false

    private static let unmanaged = "Same as computer"

    var body: some View {
        Section {
            switch state {
            case .loading:
                HStack(spacing: DS.spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading servers…")
                        .foregroundStyle(.secondary)
                }
            case .loaded:
                Button { showingChecklist = true } label: {
                    HStack(spacing: DS.spacing.s) {
                        Text("Default servers")
                            .foregroundStyle(.primary)
                        Spacer(minLength: DS.spacing.m)
                        Text(MCPServerListState.summary(selection, unmanaged: Self.unmanaged))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Default servers, \(MCPServerListState.summary(selection, unmanaged: Self.unmanaged))")
            case .unavailable, .failed:
                LabeledContent("Default servers", value: MCPServerListState.summary(selection, unmanaged: Self.unmanaged))
            }
        } footer: {
            if state == .failed {
                Text(MCPServerListState.failureMessage(project.computer))
            } else {
                Text("New conversations in this project start with these servers.")
            }
        }
        .task {
            state = await MCPServerListState.load(on: project.computer, store: store) {
                try HostLookup.config(for: project.computer, in: hosts)
            }
        }
        .sheet(isPresented: $showingChecklist) {
            if case let .loaded(servers) = state {
                MCPServersSheet(
                    computer: project.computer, store: store, hosts: hosts, selection: selection,
                    allowsUnmanaged: true, unmanagedTitle: Self.unmanaged,
                    unmanagedDetail: "Whatever the computer's default is",
                    list: .loaded(servers), confirmTitle: "Done",
                    onConfirm: { selection = $0; showingChecklist = false },
                    onCancel: { showingChecklist = false }
                )
            }
        }
    }
}
