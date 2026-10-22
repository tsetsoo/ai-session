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
    /// A warning that stays until the next successful load (the computer is unreachable).
    @State private var bannerMessage: String?
    /// A short success note ("Added to Managed"). Separate from `bannerMessage` so the reload
    /// that follows the success doesn't clear it; it fades on its own.
    @State private var confirmationMessage: String?
    @State private var alertTitle = "Could not load sessions"
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
                .keyboardShortcut("n", modifiers: [.command, .option])
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
                    confirmationMessage = "Added to Managed"
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let confirmationMessage {
                Label(confirmationMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, DS.spacing.l)
                    .padding(.vertical, DS.spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, DS.spacing.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: confirmationMessage)
        .task(id: confirmationMessage) {
            guard confirmationMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            confirmationMessage = nil
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            if canEditHost {
                Button("Edit Access…") { showingHostEditor = true }
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
            Text("Start Claude, Codex, Cursor, or a shell on \(hostTitle). It keeps running after you leave.")
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
                        .foregroundStyle(DS.accent)
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
                    DisclosureGroup("Other sessions (\(filteredOther.count))") {
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
                if let tool = session.tool {
                    ToolIcon(tool: tool.rawValue, side: 36)
                } else {
                    Image(systemName: AppTheme.iconName(for: nil))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.slug)
                        .font(.headline)
                    HStack(spacing: 6) {
                        if let tool = session.tool {
                            Text(AppTheme.displayName(for: tool))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.color(for: tool))
                        } else {
                            Text("Other session")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        // Only AI sessions report a status; a plain shell would always read Idle.
                        if session.tool != nil {
                            StatusBadge(displayStatus(session.status))
                        }
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
                .tint(DS.accentSolid)
            } else {
                Button {
                    promotingSession = session
                    showingPromoteSheet = true
                } label: {
                    Label("Manage", systemImage: "tray.and.arrow.down")
                }
                .tint(.gray)
            }
        }
    }

    /// The session's hook status in the shared badge vocabulary. A listed session is alive.
    private func displayStatus(_ status: SessionActivityStatus) -> ConversationDisplayStatus {
        ConversationDisplayStatus(ConversationStatus(rawValue: status.rawValue) ?? .unknown, tmuxAlive: true)
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
                show(error, title: "Could not duplicate session")
            }
        }
    }

    private func sessionAccessibilityLabel(_ session: RemoteSession) -> String {
        let tool = session.tool.map(AppTheme.displayName(for:)) ?? "Other session"
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
                description: Text("This device has no key for \(hostTitle). Add it under Settings → Access & keys.")
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
            NotificationCenterCoordinator.shared.postSessionsWaiting(
                hostName: hostTitle,
                sessions: result.ai + result.other
            )
        } catch SSHRemoteError.unreachable {
            guard generation == loadGeneration else { return }
            bannerMessage = ComputerErrorText.message(for: SSHRemoteError.unreachable, computer: hostTitle)
        } catch {
            guard generation == loadGeneration else { return }
            show(error, title: "Could not load sessions")
        }
    }

    private func show(_ error: Error, title: String) {
        alertTitle = title
        canEditHost = ComputerErrorText.isAccessProblem(error)
        alertMessage = ComputerErrorText.message(for: error, computer: hostTitle)
    }
}

/// Plain sentences, each with a next step, for what can go wrong reaching a computer. The SSH
/// and tmux detail stays out of these screens (see "Vocabulary on screen" in the redesign spec).
enum ComputerErrorText {
    static func message(for error: Error, computer: String) -> String {
        switch error {
        case SessionServiceFactoryError.missingPrivateKey:
            return "This device has no key for \(computer). Add it with Edit Access."
        case let error as SSHRemoteError:
            switch error {
            case .unreachable:
                return "Couldn't reach \(computer). Check that it's on and connected to Tailscale, then pull to refresh."
            case .authenticationFailed:
                return "\(computer) didn't accept this device's key. Check the user name and key with Edit Access."
            case .tmuxMissing:
                return "\(computer) can't keep sessions running yet. Install tmux on it (brew install tmux), then try again."
            case let .binaryMissing(binary):
                return "\(binary) isn't installed on \(computer). Install it there, then try again."
            case let .commandFailed(_, stderr):
                // The computer's own words name the cause, e.g. a session name already in use.
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "Something went wrong on \(computer). Try again in a moment."
                    : "\(computer) said: \(detail)"
            }
        default:
            return "Something went wrong talking to \(computer). Try again in a moment."
        }
    }

    /// Whether Edit Access is the fix: the key is missing or was refused.
    static func isAccessProblem(_ error: Error) -> Bool {
        switch error {
        case SessionServiceFactoryError.missingPrivateKey, SSHRemoteError.authenticationFailed: true
        default: false
        }
    }
}
