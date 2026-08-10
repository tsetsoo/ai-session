import AISessionCore
import SwiftUI

struct SessionsListView: View {
    let host: HostEntity

    @State private var sessions: (ai: [RemoteSession], other: [RemoteSession]) = ([], [])
    @State private var isLoading = false
    @State private var showingNewSession = false
    @State private var showingHostEditor = false
    @State private var bannerMessage: String?
    @State private var alertMessage: String?

    var body: some View {
        List {
            if let bannerMessage {
                Label(bannerMessage, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }

            if sessions.ai.isEmpty && sessions.other.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("Create a new session to get started.")
                )
            } else {
                ForEach(sessions.ai, id: \.tmuxName) { session in
                    sessionRow(session)
                }

                if !sessions.other.isEmpty {
                    Section {
                        DisclosureGroup("Other") {
                            ForEach(sessions.other, id: \.tmuxName) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(host.displayName.isEmpty ? host.hostname : host.displayName)
        .refreshable { await loadSessions() }
        .task { await loadSessions() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(host: host)
        }
        .sheet(isPresented: $showingHostEditor) {
            HostEditorView(host: host)
        }
        .alert("Could not load sessions", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if alertMessage == "The SSH key was rejected. Edit the host to update its credentials." {
                Button("Edit Host") { showingHostEditor = true }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: RemoteSession) -> some View {
        NavigationLink {
            TerminalPlaceholderView(session: session)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: session.tool))
                    .foregroundStyle(color(for: session.tool))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.slug)
                        .font(.headline)
                    if let cwd = session.cwd {
                        Text(cwd)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func loadSessions() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let connection = try SessionServiceFactory().make(for: host)
            try await connection.service.probeTmux(config: connection.config)
            sessions = try await connection.service.listSessions(config: connection.config)
            bannerMessage = nil
        } catch let error as SSHRemoteError {
            handle(error)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func handle(_ error: SSHRemoteError) {
        switch error {
        case .tmuxMissing:
            alertMessage = "tmux is required on this host. Install it with `brew install tmux` on macOS or `apt install tmux` on Debian/Ubuntu."
        case let .binaryMissing(binary):
            alertMessage = "The required binary '\(binary)' was not found on this host."
        case .authenticationFailed:
            alertMessage = "The SSH key was rejected. Edit the host to update its credentials."
        case .unreachable:
            bannerMessage = "Host is unreachable. Pull to retry."
        case let .commandFailed(_, stderr):
            alertMessage = stderr.isEmpty ? "The remote command failed." : stderr
        }
    }

    private func iconName(for tool: AITool?) -> String {
        tool == nil ? "terminal" : "sparkles"
    }

    private func color(for tool: AITool?) -> Color {
        switch tool {
        case .claude: .orange
        case .codex: .green
        case .cursor: .purple
        case nil: .secondary
        }
    }
}

private struct TerminalPlaceholderView: View {
    let session: RemoteSession

    var body: some View {
        ContentUnavailableView(
            "Terminal",
            systemImage: "terminal",
            description: Text("Terminal access for \(session.slug) will appear here.")
        )
        .navigationTitle(session.slug)
    }
}
