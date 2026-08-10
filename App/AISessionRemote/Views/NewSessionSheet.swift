import AISessionCore
import SwiftUI

struct NewSessionSheet: View {
    let host: HostEntity
    /// Called once the remote tmux session actually exists, right before this sheet dismisses
    /// itself — the caller is responsible for navigating to the terminal (see
    /// `SessionsListView`'s `pendingSession`), since a sheet is the wrong place to push a
    /// `NavigationStack` destination that needs to outlive it.
    let onCreated: (SessionName) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tool: AITool = .claude
    @State private var path: String
    @State private var slug: String
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var showingHostEditor = false
    @State private var canEditHost = false

    init(host: HostEntity, onCreated: @escaping (SessionName) -> Void) {
        self.host = host
        self.onCreated = onCreated
        let initialPath = host.defaultPaths.first ?? ""
        _path = State(initialValue: initialPath)
        _slug = State(initialValue: Self.slugify(initialPath.split(separator: "/").last.map(String.init) ?? ""))
    }

    private var trimmedSlug: String {
        slug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var slugIsInvalid: Bool {
        !trimmedSlug.isEmpty && !SessionName.isValidSlug(trimmedSlug)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tool") {
                    Picker("Tool", selection: $tool) {
                        ForEach(AITool.allCases, id: \.self) { tool in
                            Text(tool.rawValue.capitalized).tag(tool)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Working directory") {
                    TextField("/path/to/project", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !host.defaultPaths.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(host.defaultPaths, id: \.self) { bookmark in
                                    Button(bookmark) {
                                        path = bookmark
                                        slug = Self.slugify(bookmark.split(separator: "/").last.map(String.init) ?? "")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                Section("Session name") {
                    TextField("Slug", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if slugIsInvalid {
                        Text("Use lowercase letters, numbers, and hyphens only.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(
                            isStarting
                                || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || trimmedSlug.isEmpty
                                || slugIsInvalid
                        )
                }
            }
            .alert("Could not start session", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                if canEditHost {
                    Button("Edit Host") { showingHostEditor = true }
                }
                Button("OK", role: .cancel) { canEditHost = false }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showingHostEditor) {
                HostEditorView(host: host)
            }
        }
    }

    private func start() {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmedSlug
        guard !trimmedPath.isEmpty, !slug.isEmpty else { return }
        guard SessionName.isValidSlug(slug) else {
            canEditHost = false
            errorMessage = "\"\(slug)\" is not a valid session name. Use lowercase letters, numbers, and hyphens only."
            return
        }
        isStarting = true

        Task {
            defer { isStarting = false }
            do {
                let connection = try SessionServiceFactory().make(for: host)
                try await connection.service.probeTmux(config: connection.config)
                let session = try await connection.service.createSession(
                    config: connection.config,
                    tool: tool,
                    slug: slug,
                    cwd: trimmedPath,
                    title: nil
                )
                onCreated(session)
                dismiss()
            } catch let error as SSHRemoteError {
                handle(error)
            } catch {
                canEditHost = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handle(_ error: SSHRemoteError) {
        canEditHost = error == .authenticationFailed
        switch error {
        case .tmuxMissing, .binaryMissing, .authenticationFailed, .unreachable, .commandFailed:
            errorMessage = error.userMessage
        }
    }

    /// Normalizes a raw path segment into a slug `SessionName` will accept: lowercase, with any
    /// run of characters outside `[a-z0-9-]` collapsed to a single hyphen, and no leading/trailing
    /// hyphens. Used for the slug derived from a working directory so the field starts valid
    /// instead of silently failing at submit time (e.g. `My_Project` -> `my-project`).
    private static func slugify(_ raw: String) -> String {
        var result = ""
        var lastWasHyphen = true // avoid leading hyphen
        for scalar in raw.lowercased().unicodeScalars {
            let value = scalar.value
            let isLowercaseASCII = value >= 0x61 && value <= 0x7A
            let isDigitASCII = value >= 0x30 && value <= 0x39
            if isLowercaseASCII || isDigitASCII {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }
}
