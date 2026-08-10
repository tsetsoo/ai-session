import AISessionCore
import SwiftUI

struct SessionsListView: View {
    let host: HostEntity

    @State private var sessions: (ai: [RemoteSession], other: [RemoteSession]) = ([], [])
    @State private var isLoading = false
    /// Bumped on every `loadSessions()` call so a stale, still-in-flight load (e.g. one started by
    /// `.onAppear` right before a push into `TerminalScreen`) can't clobber a fresher one's result
    /// — or, via the old `guard !isLoading` check this replaced, get dropped entirely and leave the
    /// list stale when returning from the terminal while the previous load was still running.
    @State private var loadGeneration = 0
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
        // `.onAppear` (not `.task`) so returning from `TerminalScreen` — after a kill, a detach,
        // or the session simply exiting — refreshes the list every time this view becomes
        // visible again, not just on first push.
        .onAppear {
            Task { await loadSessions() }
        }
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
            terminalDestination(for: session)
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

    @ViewBuilder
    private func terminalDestination(for session: RemoteSession) -> some View {
        if let connection = try? SessionServiceFactory().make(for: host) {
            TerminalScreen(
                hostConfig: connection.config,
                attachCommand: TmuxCommandBuilder.attach(tmuxName: session.tmuxName),
                title: session.slug,
                onKill: {
                    try await connection.service.killSession(config: connection.config, tmuxName: session.tmuxName)
                }
            )
        } else {
            ContentUnavailableView(
                "Terminal Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The private key for this host is unavailable. Edit the host and save its key again.")
            )
        }
    }

    private func loadSessions() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        // Only clear the spinner if no newer load superseded this one — otherwise that newer
        // load's own `defer` is the one responsible for turning it off.
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let connection = try SessionServiceFactory().make(for: host)
            try await connection.service.probeTmux(config: connection.config)
            let result = try await connection.service.listSessions(config: connection.config)
            guard generation == loadGeneration else { return }
            sessions = result
            bannerMessage = nil
        } catch let error as SSHRemoteError {
            guard generation == loadGeneration else { return }
            handle(error)
        } catch {
            guard generation == loadGeneration else { return }
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

