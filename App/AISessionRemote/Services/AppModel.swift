import AISessionCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// What the Mac's selection may do with a todo's conversation, from the board and liveness.
enum AttachReadiness: Equatable {
    /// Its tmux session was listed alive: attach.
    case running
    /// Closed, gone, or never started: Start / Resume.
    case closed
    /// Its computer hasn't been listed yet: wait for a liveness refresh.
    case awaitingLiveness
    /// Its computer didn't answer: neither attach nor drop a terminal already attached.
    case unknown
}

/// A "needs you" alert: the todo title and "Needs you", never a status message or any
/// conversation text, so it matches what a push can carry.
struct WaitingAlert: Equatable {
    let todoId: String
    let sessionId: String
    let title: String
    let body: String
}

/// Where a conversation that turned `waiting` goes. Tests inject it.
@MainActor
struct WaitingAlerts {
    /// Settings → Notifications ("notify.needsYou"): off, neither alerts nor buzzes.
    var isEnabled: () -> Bool
    /// The conversation on screen while the app is active (`nil`: none).
    var frontmostTodoID: () -> String?
    var post: (WaitingAlert) -> Void
    /// The buzz instead of an alert for the conversation on screen.
    var feedback: () -> Void

    /// The coordinator owns permission, push-vs-local dedup and the Mac rule; its presence is
    /// what `VisiblePresence` reported, cleared while the app is inactive.
    static var live: WaitingAlerts {
        WaitingAlerts(
            isEnabled: { NotificationCenterCoordinator.shared.isEnabled },
            frontmostTodoID: { NotificationCenterCoordinator.shared.visibleTodoId },
            post: { alert in
                NotificationCenterCoordinator.shared.postWaiting(
                    todoId: alert.todoId, sessionId: alert.sessionId, title: alert.title, body: alert.body
                )
            },
            feedback: { PlatformSupport.needsYouFeedback() }
        )
    }
}

/// App-level state shared by the whole UI: the hub store, which tmux sessions are really alive
/// on each computer, and the navigation selection. Created once in `AISessionRemoteApp`.
@MainActor
@Observable
final class AppModel {
    typealias TmuxListing = @Sendable (Computer) async throws -> Set<String>

    enum SidebarItem: Hashable {
        case needsYou, runningNow, section(TodoSection), projects, computer(String)
    }

    let store: TodoHubStore
    /// computerID to its tmux session names. A computer that is absent is unknown (its hub
    /// status is kept).
    private(set) var liveTmux: [String: Set<String>] = [:]
    /// Computers a liveness refresh has finished for, answered or not. Until then the Mac's
    /// selection waits before attaching.
    private(set) var livenessChecked: Set<String> = []
    /// Bumped when the newest liveness refresh ended without publishing (cancelled, or
    /// superseded by one that was then cancelled) and none is left running. Selections still
    /// waiting on liveness ask again on this, and only on this: re-asking while another
    /// refresh runs would supersede it, and two waiting frames would do that to each other
    /// forever.
    private(set) var livenessAbandoned = 0

    var sidebarSelection: SidebarItem?
    var selectedTodoID: String?
    /// The project shown in the detail column while the sidebar is on Projects.
    var selectedProjectID: String?
    var poppedOut: Set<String> = []
    /// Set by notification taps and the palette.
    var pendingOpenTodoID: String?
    /// The Home-screen "New Todo" quick action: show the Todos list and focus quick-add.
    /// The quick-add field clears it once focused.
    var quickAddFocusRequested = false

    /// Replaces the SSH listing; tests inject it. Production builds it from the hosts.
    private let listTmuxOverride: TmuxListing?
    private let alerts: WaitingAlerts
    /// Conversation statuses at the last refresh (`nil` until the first one after launch or a
    /// reconnect): the baseline for "turned waiting" alerts.
    private var lastStatuses: [String: ConversationStatus]?
    /// Incremented per refresh; only the latest, uncancelled one may publish its result.
    private var livenessGeneration = 0
    /// The generation whose result is in `liveTmux` (0: none yet).
    private var publishedLivenessGeneration = 0
    private var livenessRefreshesRunning = 0
    /// The first load and the start of live updates, owned by the model rather than by the
    /// view that asked first: that view going away (an iPad shell swap at launch, a restored
    /// pop-out window closed) must not cancel it.
    private var firstLoad: Task<Void, Never>?

    var board: ConversationBoard {
        ConversationBoard(todos: store.todos, conversations: store.conversations, liveTmux: liveTmux)
    }

    #if DEBUG
    init(store: TodoHubStore? = nil, demo: Bool = DemoFixtures.isEnabled, listTmux: TmuxListing? = nil,
         alerts: WaitingAlerts? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
        self.alerts = alerts ?? .live
        observeRefreshes()
        if demo {
            store.seedForDemo(
                todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
                sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
            )
            // Demo data never lists tmux: its running conversations count as alive.
            for computer in DemoFixtures.computers {
                liveTmux[computer.id] = Set(DemoFixtures.conversations
                    .filter { $0.computer.id == computer.id && $0.status != .closed }
                    .map(\.tmuxName))
            }
            livenessChecked = Set(DemoFixtures.computers.map(\.id))
        } else if ProcessInfo.processInfo.arguments.contains("-demoProjects") {
            // Screenshots of Projects: canned hub data, no hub contacted.
            store.loadDemo(.sample)
        }
    }
    #else
    init(store: TodoHubStore? = nil, listTmux: TmuxListing? = nil, alerts: WaitingAlerts? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
        self.alerts = alerts ?? .live
        observeRefreshes()
    }
    #endif

    // MARK: "Needs you" alerts

    private func observeRefreshes() {
        store.onRefresh = { [weak self] fetched in self?.alertNewlyWaiting(fetched) }
    }

    /// The one place a conversation turning `waiting` is announced: an alert through the
    /// coordinator, or only a buzz when that conversation is on screen in the active app.
    private func alertNewlyWaiting(_ fetched: TodoHubStore.Fetched) {
        let previous = fetched.isBaseline ? nil : lastStatuses
        lastStatuses = Dictionary(fetched.conversations.map { ($0.todoId, $0.status) },
                                  uniquingKeysWith: { _, new in new })
        let flipped = StatusTransitions.newlyWaiting(previous: previous, current: fetched.conversations)
        guard !flipped.isEmpty, alerts.isEnabled() else { return }
        let frontmost = alerts.frontmostTodoID()
        for conversation in flipped {
            if conversation.todoId == frontmost {
                alerts.feedback()
                continue
            }
            alerts.post(WaitingAlert(
                todoId: conversation.todoId,
                sessionId: conversation.sessionId,
                title: fetched.todos.first { $0.id == conversation.todoId }?.title ?? "Conversation",
                body: "Needs you"
            ))
        }
    }

    /// Whether the todo server is set up. Demo launches always are.
    var isConfigured: Bool {
        #if DEBUG
        if DemoFixtures.isEnabled { return true }
        #endif
        return store.isConfigured
    }

    /// The first load, then live updates. Idempotent: each shell calls it, and so does a pop-out
    /// window restored without the main window. Demo launches never touch the network.
    func startSync() async {
        #if DEBUG
        if DemoFixtures.isEnabled || store.demo != nil { return }
        #endif
        guard store.isConfigured else { return }
        if firstLoad == nil {
            let store = store
            firstLoad = Task {
                await store.refresh()
                store.startLiveUpdates()
            }
        }
        await firstLoad?.value
    }

    /// `UIApplicationShortcutItems` type of the Home-screen "New Todo" quick action.
    static let newTodoShortcutType = "com.aisessionremote.newTodo"

    /// Routes notification taps (`pendingOpenTodoID`) and the Home-screen quick action
    /// (`quickAddFocusRequested`) into the shells. The main window calls it; repeating is
    /// harmless. Setting the hooks replays a tap or quick action that launched the app.
    func installSystemEntryPoints() {
        NotificationCenterCoordinator.shared.onOpenTodo = { [weak self] todoId in
            Task { await self?.openFromNotification(todoId) }
        }
        #if os(iOS)
        AppDelegate.onShortcutItem = { [weak self] item in
            guard item.type == Self.newTodoShortcutType else { return false }
            MainActor.assumeIsolated { self?.quickAddFocusRequested = true }
            return true
        }
        #endif
    }

    /// A tapped "needs you" notification: open that todo's conversation, loading the todos
    /// first if it isn't known yet.
    func openFromNotification(_ todoId: String) async {
        if !store.todos.contains(where: { $0.id == todoId }) {
            await store.refresh()
        }
        guard store.todos.contains(where: { $0.id == todoId }) else { return }
        pendingOpenTodoID = todoId
    }

    /// Lists tmux sessions once per hub computer, in parallel. A computer with no matching
    /// host, or whose listing fails, is left out of `liveTmux`.
    func refreshLiveness(hosts: [HostEntity]) async {
        #if DEBUG
        // Demo data never touches the network; keep the seeded statuses.
        if DemoFixtures.isEnabled && listTmuxOverride == nil { return }
        #endif
        livenessGeneration += 1
        let generation = livenessGeneration
        livenessRefreshesRunning += 1
        defer {
            livenessRefreshesRunning -= 1
            if livenessRefreshesRunning == 0, publishedLivenessGeneration != livenessGeneration {
                livenessAbandoned += 1
            }
        }
        let computers = store.computers
        let listing = listTmuxOverride ?? Self.sshListing(hosts: hosts, computers: computers)
        var result: [String: Set<String>] = [:]
        await withTaskGroup(of: (String, Set<String>?).self) { group in
            for computer in computers {
                group.addTask { (computer.id, try? await listing(computer)) }
            }
            for await (id, names) in group {
                if let names { result[id] = names }
            }
        }
        guard generation == livenessGeneration, !Task.isCancelled else { return }
        liveTmux = result
        publishedLivenessGeneration = generation
        livenessChecked.formUnion(computers.map(\.id))
    }

    /// Whether the Mac's selection may attach to this todo's conversation. Attaching runs
    /// `ai-todo-open`, which recreates a dead tmux session, so it needs the session seen alive.
    func attachReadiness(forTodo id: String) -> AttachReadiness {
        guard let conversation = store.conversations[id],
              let status = board.status(forTodo: id), status != .closed else { return .closed }
        let computerID = conversation.computer.id
        // Present means listed, and a listing without its tmux name would have made it closed.
        if liveTmux[computerID] != nil { return .running }
        let refreshable = store.computers.contains { $0.id == computerID }
        return refreshable && !livenessChecked.contains(computerID) ? .awaitingLiveness : .unknown
    }

    /// HostEntity is a SwiftData model, so resolve each computer's connection on the main actor
    /// up front; the returned closure only touches Sendable values.
    private static func sshListing(hosts: [HostEntity], computers: [Computer]) -> TmuxListing {
        struct NoConnection: Error {}
        let factory = SessionServiceFactory()
        var connections: [String: (service: SessionService, config: HostConnectionConfig)] = [:]
        for computer in computers {
            guard let host = HostLookup.host(for: computer, in: hosts),
                  let made = try? factory.make(for: host) else { continue }
            connections[computer.id] = made
        }
        return { computer in
            guard let connection = connections[computer.id] else { throw NoConnection() }
            let sessions = try await connection.service.listSessions(config: connection.config)
            return Set((sessions.ai + sessions.other).map(\.tmuxName))
        }
    }
}
