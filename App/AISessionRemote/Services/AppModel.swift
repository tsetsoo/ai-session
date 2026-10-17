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
    /// Its computer hasn't been listed yet, or not in the last `AppModel.listingMaxAge`: wait
    /// for a liveness refresh.
    case awaitingLiveness
    /// Its computer didn't answer, or the conversation changed after the listing: neither
    /// attach nor drop a terminal already attached.
    case unknown
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
    /// computerID to when the newest finished liveness refresh listed it, answered or not.
    /// Until then, and once that is older than `listingMaxAge`, the Mac's selection waits for a
    /// fresh listing before attaching.
    private(set) var livenessChecked: [String: Date] = [:]
    /// How old a listing may be for the selection to attach on it: a session started since, or
    /// one a reboot ended, only shows in a newer one.
    static let listingMaxAge: TimeInterval = 45
    /// Bumped when the newest liveness refresh ended without publishing (cancelled, or
    /// superseded by one that was then cancelled) and none is left running. Selections still
    /// waiting on liveness ask again on this, and only on this: re-asking while another
    /// refresh runs would supersede it, and two waiting frames would do that to each other
    /// forever.
    private(set) var livenessAbandoned = 0
    /// computerID to when its `liveTmux` entry was listed (when the listing was asked for).
    private(set) var listedAt: [String: Date] = [:]
    /// Bumped when a conversation changed after its computer's listing and isn't in it (started
    /// or reported since): the views that list tmux sessions list again (`.task(id:)`).
    private(set) var relistRequests = 0

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
    /// The time of a liveness listing; tests fix it.
    private let now: () -> Date
    /// Incremented per refresh; only the latest, uncancelled one may publish its result.
    private var livenessGeneration = 0
    /// The generation whose result is in `liveTmux` (0: none yet).
    private var publishedLivenessGeneration = 0
    private var livenessRefreshesRunning = 0
    /// The first load and the start of live updates, owned by the model rather than by the
    /// view that asked first: that view going away (an iPad shell swap at launch, a restored
    /// pop-out window closed) must not cancel it.
    private var firstLoad: Task<Void, Never>?
    /// The conversation changes (todo, created, status time) a relist was already asked for.
    @ObservationIgnored private var relistedFor: Set<String> = []

    var board: ConversationBoard {
        ConversationBoard(todos: store.todos, conversations: store.conversations, liveTmux: liveTmux,
                          listedAt: listedAt)
    }

    #if DEBUG
    init(store: TodoHubStore? = nil, demo: Bool = DemoFixtures.isEnabled, listTmux: TmuxListing? = nil,
         now: @escaping () -> Date = Date.init) {
        // A demo never reads (or shows) the real offline cache.
        let store = store ?? TodoHubStore(cache: demo ? TodoHubStore.scratchCache() : TodoHubStore.defaultCache())
        self.store = store
        self.listTmuxOverride = listTmux
        self.now = now
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
            // Never stale: demo launches don't list.
            livenessChecked = Dictionary(uniqueKeysWithValues: DemoFixtures.computers.map { ($0.id, Date.distantFuture) })
        } else if ProcessInfo.processInfo.arguments.contains("-demoProjects") {
            // Screenshots of Projects: canned hub data, no hub contacted.
            store.loadDemo(.sample)
        }
        watchForRelist()
    }
    #else
    init(store: TodoHubStore? = nil, listTmux: TmuxListing? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
        self.now = Date.init
        watchForRelist()
    }
    #endif

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

    // MARK: Listing again

    /// Follows the board for conversations newer than their computer's listing.
    private func watchForRelist() {
        let stale = withObservationTracking {
            Set(board.newerThanListing.map { "\($0.todoId)|\($0.createdAt)|\($0.statusUpdatedAt ?? "")" })
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchForRelist() }
        }
        let fresh = stale.subtracting(relistedFor)
        // Only what is still stale: a relisted conversation drops out, and the set stays small.
        relistedFor = relistedFor.intersection(stale).union(fresh)
        if !fresh.isEmpty { relistRequests += 1 }
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
        // Anything that changed after this moment may be missing from the listing.
        let askedAt = now()
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
        listedAt = result.mapValues { _ in askedAt }
        publishedLivenessGeneration = generation
        for computer in computers { livenessChecked[computer.id] = askedAt }
    }

    /// Whether the Mac's selection may attach to this todo's conversation. Attaching runs
    /// `ai-todo-open`, which recreates a dead tmux session, so it needs the session seen alive.
    func attachReadiness(forTodo id: String) -> AttachReadiness {
        guard let conversation = store.conversations[id],
              let status = board.status(forTodo: id), status != .closed else { return .closed }
        let computerID = conversation.computer.id
        let refreshable = store.computers.contains { $0.id == computerID }
        // Never listed, or listed too long ago (a reboot since would have ended the session,
        // and the hub would still say busy): wait for a fresh listing.
        if refreshable {
            guard let checked = livenessChecked[computerID],
                  now().timeIntervalSince(checked) <= Self.listingMaxAge else { return .awaitingLiveness }
        }
        guard let names = liveTmux[computerID] else { return .unknown }
        // Missing from the listing yet not closed: it changed after the listing, which the
        // board's relist request is refreshing. Neither attach nor drop a terminal meanwhile.
        return names.contains(conversation.tmuxName) ? .running : .unknown
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
