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
    @State private var canEditHost = false
    /// Set by `NewSessionSheet`'s `onCreated` right before it dismisses itself, so this view can
    /// push straight into the new session's terminal via a real `navigationDestination` (rather
    /// than the sheet trying to push a destination that would outlive it).
    @State private var pendingSession: SessionName?
    @State private var hasLoadedOnce = false
    @State private var query = ""
    @State private var promotingSession: RemoteSession?
    @State private var showingPromoteSheet = false

    private var hostTitle: String {
        host.displayName.isEmpty ? host.hostname : host.displayName
    }

    private var isEmpty: Bool {
        filteredAI.isEmpty && filteredOther.isEmpty
    }

    private var filteredAI: [RemoteSession] { filter(sessions.ai) }
    private var filteredOther: [RemoteSession] { filter(sessions.other) }

    var body: some View {
        Group {
            if !hasLoadedOnce && isLoading {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty && !isLoading {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle(hostTitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search sessions")
        .refreshable { await loadSessions() }
        // `.onAppear` (not `.task`) so returning from `TerminalScreen` — after a kill, a detach,
        // or the session simply exiting — refreshes the list every time this view becomes
        // visible again, not just on first push.
        .onAppear {
            // Fire-and-forget: `warm` never throws and its own dial failures stay silent inside
            // the pool, so a speculative dial can never surface an error the user did not
            // provoke — `loadSessions` below is what reports any real problem with this host.
            if let connection = try? SessionServiceFactory().make(for: host) {
                Task { await NIOSSHClient.shared.warm(connection.config) }
            }
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
            ToolbarItem(placement: .status) {
                if isLoading && hasLoadedOnce {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .navigationDestination(item: $pendingSession) { session in
            terminalDestination(tmuxName: session.tmuxName, title: session.slug)
        }
        .sheet(isPresented: $showingNewSession, onDismiss: { Task { await loadSessions() } }) {
            NewSessionSheet(host: host) { session in
                pendingSession = session
            }
        }
        .sheet(isPresented: $showingHostEditor) {
            HostEditorView(host: host)
        }
        .sheet(isPresented: $showingPromoteSheet, onDismiss: {
            promotingSession = nil
            Task { await loadSessions() }
        }) {
            if let promotingSession {
                PromoteSessionSheet(host: host, session: promotingSession) {
                    bannerMessage = "Session added to Managed"
                }
            }
        }
        .alert("Could not load sessions", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if canEditHost {
                Button("Edit Host") { showingHostEditor = true }
            }
            Button("OK", role: .cancel) { canEditHost = false }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "terminal")
        } description: {
            Text("Start a Claude, Codex, Cursor, or Shell session on \(hostTitle). It keeps running in tmux after you detach.")
        } actions: {
            Button {
                showingNewSession = true
            } label: {
                Text("New Session")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var sessionList: some View {
        List {
            if let bannerMessage {
                Section {
                    Label(bannerMessage, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if !filteredAI.isEmpty {
                Section {
                    ForEach(filteredAI, id: \.tmuxName) { session in
                        sessionRow(session)
                    }
                } header: {
                    Text("AI Sessions")
                }
            }

            if !filteredOther.isEmpty {
                Section {
                    DisclosureGroup("Other tmux (\(filteredOther.count))") {
                        ForEach(filteredOther, id: \.tmuxName) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: RemoteSession) -> some View {
        NavigationLink {
            terminalDestination(for: session)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.color(for: session.tool).opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: AppTheme.iconName(for: session.tool))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.color(for: session.tool))
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.slug)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let tool = session.tool {
                            Text(AppTheme.displayName(for: tool))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.color(for: tool))
                        } else {
                            Text("tmux")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        statusPill(session.status)
                        if let cwd = session.cwd {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(cwd)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel(sessionAccessibilityLabel(session))
        .contextMenu {
            if session.isAIManaged {
                Button {
                    duplicate(session)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            } else {
                Button {
                    promotingSession = session
                    showingPromoteSheet = true
                } label: {
                    Label("Add to Managed…", systemImage: "tray.and.arrow.down")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if session.isAIManaged {
                Button { duplicate(session) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .tint(.blue)
            } else {
                Button {
                    promotingSession = session
                    showingPromoteSheet = true
                } label: {
                    Label("Manage", systemImage: "tray.and.arrow.down")
                }
                .tint(.orange)
            }
        }
    }

    private func statusPill(_ status: SessionActivityStatus) -> some View {
        Text(AppTheme.statusLabel(status))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.statusColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppTheme.statusColor(status).opacity(0.14), in: Capsule())
    }

    private func filter(_ sessions: [RemoteSession]) -> [RemoteSession] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sessions }
        let query = query.lowercased()
        return sessions.filter { session in
            [session.slug, session.tmuxName, session.cwd ?? "", session.tool?.rawValue ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private func duplicate(_ session: RemoteSession) {
        guard let tool = session.tool else { return }
        Task {
            do {
                let connection = try SessionServiceFactory().make(for: host)
                let created = try await connection.service.createSession(
                    config: connection.config,
                    tool: tool,
                    slug: session.slug,
                    cwd: session.cwd ?? host.lastUsedPath ?? "/",
                    title: nil
                )
                pendingSession = created
                await loadSessions()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func sessionAccessibilityLabel(_ session: RemoteSession) -> String {
        let tool = session.tool.map(AppTheme.displayName(for:)) ?? "tmux"
        if let cwd = session.cwd {
            return "\(session.slug), \(tool), \(cwd)"
        }
        return "\(session.slug), \(tool)"
    }

    @ViewBuilder
    private func terminalDestination(for session: RemoteSession) -> some View {
        terminalDestination(tmuxName: session.tmuxName, title: session.slug)
    }

    @ViewBuilder
    private func terminalDestination(tmuxName: String, title: String) -> some View {
        if let connection = try? SessionServiceFactory().make(for: host) {
            TerminalScreen(
                hostConfig: connection.config,
                mode: .attach(TmuxCommandBuilder.attach(tmuxName: tmuxName)),
                title: title,
                onKill: {
                    try await connection.service.killSession(config: connection.config, tmuxName: tmuxName)
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
        defer {
            if generation == loadGeneration {
                isLoading = false
                hasLoadedOnce = true
            }
        }

        do {
            let connection = try SessionServiceFactory().make(for: host)
            try await connection.service.probeTmux(config: connection.config)
            let result = try await connection.service.listSessions(config: connection.config)
            guard generation == loadGeneration else { return }
            sessions = result
            bannerMessage = nil
            AttentionNotifier.notifyWaitingSessions(
                hostName: hostTitle,
                sessions: result.ai + result.other
            )
        } catch let error as SSHRemoteError {
            guard generation == loadGeneration else { return }
            handle(error)
        } catch {
            guard generation == loadGeneration else { return }
            canEditHost = false
            alertMessage = error.localizedDescription
        }
    }

    private func handle(_ error: SSHRemoteError) {
        canEditHost = error == .authenticationFailed
        switch error {
        case .tmuxMissing:
            alertMessage = error.userMessage
        case .binaryMissing, .authenticationFailed:
            alertMessage = error.userMessage
        case .unreachable:
            bannerMessage = error.userMessage
        case .commandFailed:
            alertMessage = error.userMessage
        }
    }
}
