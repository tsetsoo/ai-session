import AISessionCore
import SwiftUI

struct NewSessionSheet: View {
    let host: HostEntity
    @Environment(\.dismiss) private var dismiss
    @State private var tool: AITool = .claude
    @State private var path: String
    @State private var slug: String
    @State private var isStarting = false
    @State private var createdSession: SessionName?
    @State private var errorMessage: String?
    @State private var showingHostEditor = false

    init(host: HostEntity) {
        self.host = host
        let initialPath = host.defaultPaths.first ?? ""
        _path = State(initialValue: initialPath)
        _slug = State(initialValue: initialPath.split(separator: "/").last.map(String.init) ?? "")
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
                                        slug = bookmark.split(separator: "/").last.map(String.init) ?? ""
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
                }

                if let createdSession {
                    NavigationLink(
                        "Open \(createdSession.tmuxName)",
                        destination: NewSessionTerminalPlaceholderView(session: createdSession),
                        isActive: Binding(
                            get: { self.createdSession != nil },
                            set: { if !$0 { dismiss() } }
                        )
                    )
                    .hidden()
                }
            }
            .navigationTitle("New Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .disabled(isStarting || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not start session", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                if errorMessage == "The SSH key was rejected. Edit the host to update its credentials." {
                    Button("Edit Host") { showingHostEditor = true }
                }
                Button("OK", role: .cancel) {}
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
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, !trimmedSlug.isEmpty else { return }
        isStarting = true

        Task {
            defer { isStarting = false }
            do {
                let connection = try SessionServiceFactory().make(for: host)
                try await connection.service.probeTmux(config: connection.config)
                createdSession = try await connection.service.createSession(
                    config: connection.config,
                    tool: tool,
                    slug: trimmedSlug,
                    cwd: trimmedPath,
                    title: nil
                )
            } catch let error as SSHRemoteError {
                handle(error)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handle(_ error: SSHRemoteError) {
        switch error {
        case .tmuxMissing:
            errorMessage = "tmux is required on this host. Install it with `brew install tmux` on macOS or `apt install tmux` on Debian/Ubuntu."
        case let .binaryMissing(binary):
            errorMessage = "The required binary '\(binary)' was not found on this host."
        case .authenticationFailed:
            errorMessage = "The SSH key was rejected. Edit the host to update its credentials."
        case .unreachable:
            errorMessage = "The host is unreachable."
        case let .commandFailed(_, stderr):
            errorMessage = stderr.isEmpty ? "The remote command failed." : stderr
        }
    }
}

private struct NewSessionTerminalPlaceholderView: View {
    let session: SessionName

    var body: some View {
        ContentUnavailableView(
            "Terminal",
            systemImage: "terminal",
            description: Text("Terminal access for \(session.tmuxName) will appear here.")
        )
        .navigationTitle(session.tmuxName)
    }
}
