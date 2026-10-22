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
        case needsYou, review, working, section(TodoSection), projects, computer(String)
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
    /// or reported since). Each shell lists again on this (`.task(id:)`); the first value, 0,
    /// lists every computer, and later values list only the stale ones.
    private(set) var relistRequests = 0

    var sidebarSelection: SidebarItem?
    var selectedTodoID: String?
    /// The conversation row that is selected. Opening a todo sets this to its most urgent conversation.
    var selectedConversationID: String?
    /// The project shown in the detail column while the sidebar is on Projects.
    var selectedProjectID: String?
    var poppedOut: Set<String> = []
    /// Set by notification taps and the palette.
    var pendingOpenTodoID: String?
    /// The Home-screen "New Todo" quick action: show the Todos list and focus quick-add.
    /// The quick-add field clears it once focused.
    var quickAddFocusRequested = false
    /// The ⌘K palette is open: terminals don't take keyboard focus by themselves meanwhile (on
    /// connect, or when a waiting conversation opens), so typing stays in its search field.
    var isPaletteOpen = false
    /// Asks the frame showing a todo to put keyboard focus back in its connected terminal.
    private(set) var terminalFocusRequest: TerminalFocusRequest?

    struct TerminalFocusRequest: Equatable {
        let todoID: String
        /// Makes each ask a change, even for the same todo.
        let serial: Int
    }

    /// Whether a terminal may take keyboard focus by itself now.
    var allowsTerminalAutoFocus: Bool { !isPaletteOpen }

    func requestTerminalFocus(todoID: String) {
        terminalFocusRequest = TerminalFocusRequest(todoID: todoID, serial: (terminalFocusRequest?.serial ?? 0) + 1)
    }

    /// Replaces the SSH listing; tests inject it. Production builds it from the hosts.
    private let listTmuxOverride: TmuxListing?
    private let alerts: WaitingAlerts
    /// Conversation statuses at the last refresh (`nil` until the first one after launch or a
    /// reconnect): the baseline for "turned waiting" alerts.
    private var lastStatuses: [String: ConversationStatus]?
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
    /// A stale listing that failed, asked again after `staleRetryDelay`. One at a time.
    @ObservationIgnored private var staleRetry: Task<Void, Never>?
    /// How long a failed stale listing waits before the shell asks again.
    var staleRetryDelay: Duration = .seconds(2)
    /// Stale and single-computer results waiting to merge after the full listing that was
    /// already in flight, oldest first.
    @ObservationIgnored private var pendingStale: [StaleListing] = []
    /// Full listings in flight. A stale pass does not count, so it cannot hide one.
    @ObservationIgnored private var fullRefreshesRunning = 0
    /// One board for the current inputs. Reads in one turn return this instance.
    @ObservationIgnored private var cachedBoard: ConversationBoard?
    @ObservationIgnored private var cachedBoardInputs: BoardInputs?

    /// Todos, conversations and the listings the cached board was built from.
    private struct BoardInputs: Equatable {
        var todos: [Todo]
        var conversations: [String: Conversation]
        var liveTmux: [String: Set<String>]
        var listedAt: [String: Date]
    }

    var board: ConversationBoard {
        let inputs = BoardInputs(todos: store.todos, conversations: store.conversations, liveTmux: liveTmux,
                                 listedAt: listedAt)
        if let cachedBoard, cachedBoardInputs == inputs { return cachedBoard }
        let built = ConversationBoard(todos: inputs.todos, conversations: inputs.conversations,
                                      liveTmux: inputs.liveTmux, listedAt: inputs.listedAt)
        cachedBoard = built
        cachedBoardInputs = inputs
        return built
    }

    #if DEBUG
    init(store: TodoHubStore? = nil, demo: Bool = DemoFixtures.isEnabled, listTmux: TmuxListing? = nil,
         alerts: WaitingAlerts? = nil, now: @escaping () -> Date = Date.init) {
        // A demo never reads (or shows) the real offline cache.
        let store = store ?? TodoHubStore(cache: demo ? TodoHubStore.scratchCache() : TodoHubStore.defaultCache())
        self.store = store
        self.listTmuxOverride = listTmux
        self.alerts = alerts ?? .live
        self.now = now
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
            // Never stale: demo launches don't list.
            livenessChecked = Dictionary(uniqueKeysWithValues: DemoFixtures.computers.map { ($0.id, Date.distantFuture) })
        } else if ProcessInfo.processInfo.arguments.contains("-demoProjects") {
            // Screenshots of Projects: canned hub data, no hub contacted.
            store.loadDemo(.sample)
        }
        watchForRelist()
    }
    #else
    init(store: TodoHubStore? = nil, listTmux: TmuxListing? = nil, alerts: WaitingAlerts? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
        self.alerts = alerts ?? .live
        self.now = Date.init
        observeRefreshes()
        watchForRelist()
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

    // MARK: Listing again

    /// Follows the board for conversations newer than their computer's listing.
    private func watchForRelist() {
        let stale = withObservationTracking {
            Set(board.newerThanListing.map(Self.relistKey))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchForRelist() }
        }
        let fresh = stale.subtracting(relistedFor)
        // Only what is still stale: a relisted conversation drops out, and the set stays small.
        relistedFor = relistedFor.intersection(stale).union(fresh)
        if !fresh.isEmpty {
            staleRetry?.cancel()
            staleRetry = nil
            relistRequests += 1
        }
    }

    private static func relistKey(_ conversation: Conversation) -> String {
        "\(conversation.todoId)|\(conversation.createdAt)|\(conversation.statusUpdatedAt ?? "")"
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

    /// Which computers `refreshLiveness` lists. The default replaces every computer's listing.
    enum LivenessScope: Sendable {
        /// Every hub computer. The result replaces `liveTmux` and `listedAt`.
        case full
        /// Computers with a conversation in `board.newerThanListing`. Results merge into the
        /// listings already held. Nothing stale: return without listing or a new generation.
        /// A stale pass does not supersede a full pass already running; its result merges
        /// after that full result lands.
        case stale
        /// One computer: what a selection waiting on liveness asks for, so it waits on that
        /// computer alone, not the slowest one. The result applies at once, merges like a stale
        /// pass, and is merged again after a full pass already in flight. A computer that does
        /// not answer is checked and absent, as in a full pass.
        case computer(String)
    }

    /// One stale listing's answers, held when a full listing is still in flight.
    private struct StaleListing {
        var result: [String: Set<String>]
        var targets: [Computer]
        var askedAt: Date
        /// A computer that did not answer counts as checked and unlisted (`.computer`), rather
        /// than keeping its previous listing unchecked (`.stale`).
        var checksFailures = false
    }

    /// Lists tmux sessions on hub computers, in parallel. A computer with no matching host, or
    /// whose listing fails, is left out of a `.full` result. `.stale` writes only the computers
    /// it listed successfully and leaves every other computer's listing in place.
    func refreshLiveness(hosts: [HostEntity], scope: LivenessScope = .full) async {
        #if DEBUG
        // Demo data never touches the network; keep the seeded statuses.
        if DemoFixtures.isEnabled && listTmuxOverride == nil { return }
        #endif
        let computers = store.computers
        let targets: [Computer]
        let isFull: Bool
        switch scope {
        case .full:
            targets = computers
            isFull = true
            // Nothing to list yet: the hub refresh has not filled computers, or no host is
            // saved. Publishing would store an empty result and, with no hosts, stamp every
            // computer checked. The shell task id includes both, so this runs again when they
            // arrive. A test double may list with an empty host array.
            if targets.isEmpty || (listTmuxOverride == nil && hosts.isEmpty) { return }
        case .stale:
            let staleIDs = Set(board.newerThanListing.map(\.computer.id))
            targets = computers.filter { staleIDs.contains($0.id) }
            // Before any generation change: an empty stale pass must not supersede a refresh
            // already running, and must not mark that refresh abandoned.
            if targets.isEmpty { return }
            isFull = false
        case let .computer(id):
            targets = computers.filter { $0.id == id }
            // No hosts yet (SwiftData still loading): every listing would fail and count as
            // checked. Like a full pass, wait for them; the shell lists again when they arrive.
            if targets.isEmpty || (listTmuxOverride == nil && hosts.isEmpty) { return }
            isFull = false
        }
        // Only a full pass takes a generation. A stale pass must not discard one in flight.
        if isFull {
            livenessGeneration += 1
            fullRefreshesRunning += 1
        }
        let generation = livenessGeneration
        livenessRefreshesRunning += 1
        var wrote = false
        defer {
            if isFull {
                fullRefreshesRunning -= 1
                if !wrote, fullRefreshesRunning == 0, !pendingStale.isEmpty {
                    let pending = pendingStale
                    pendingStale = []
                    pending.forEach(mergeStale)
                }
            }
            livenessRefreshesRunning -= 1
            if livenessRefreshesRunning == 0, publishedLivenessGeneration != livenessGeneration {
                livenessAbandoned += 1
            }
        }
        // Anything that changed after this moment may be missing from the listing.
        let askedAt = now()
        let listing = listTmuxOverride ?? Self.sshListing(hosts: hosts, computers: targets)
        var result: [String: Set<String>] = [:]
        await withTaskGroup(of: (String, Set<String>?).self) { group in
            for computer in targets {
                group.addTask { (computer.id, try? await listing(computer)) }
            }
            for await (id, names) in group {
                if let names { result[id] = names }
            }
        }
        guard !Task.isCancelled else { return }
        switch scope {
        case .full:
            guard generation == livenessGeneration else { return }
            liveTmux = result
            // A computer that did not answer still has a stamp, so a conversation that
            // starts afterwards is stale and the next pass can clear the check.
            var listed = result.mapValues { _ in askedAt }
            for computer in computers {
                livenessChecked[computer.id] = askedAt
                if listed[computer.id] == nil { listed[computer.id] = askedAt }
            }
            listedAt = listed
            publishedLivenessGeneration = generation
            wrote = true
            let pending = pendingStale
            pendingStale = []
            pending.forEach(mergeStale)
        case .stale:
            let stale = StaleListing(result: result, targets: targets, askedAt: askedAt)
            if fullRefreshesRunning > 0 {
                pendingStale.append(stale)
            } else {
                mergeStale(stale)
            }
            let failed = Set(targets.lazy.filter { result[$0.id] == nil }.map(\.id))
            if !failed.isEmpty { scheduleStaleRetry(failedComputers: failed) }
        case .computer:
            let listing = StaleListing(result: result, targets: targets, askedAt: askedAt, checksFailures: true)
            // Now, so the selection does not wait on the full pass; and again after it, which
            // would otherwise put its older listing back.
            mergeStale(listing)
            if fullRefreshesRunning > 0 { pendingStale.append(listing) }
        }
    }

    /// Merges a stale listing into the listings already held. A computer that did not answer
    /// keeps its previous names.
    private func mergeStale(_ listing: StaleListing) {
        var sessions = liveTmux
        var listed = listedAt
        var checked = livenessChecked
        for computer in listing.targets {
            // Asked before the listing already held (a full pass that started later and
            // landed first): the older answer must not put back a session that has ended.
            if let current = listed[computer.id], current > listing.askedAt { continue }
            guard let names = listing.result[computer.id] else {
                if listing.checksFailures {
                    sessions.removeValue(forKey: computer.id)
                    listed[computer.id] = listing.askedAt
                    checked[computer.id] = listing.askedAt
                    continue
                }
                // A failed pass is not a check. Leaving the old stamp would make a conversation
                // that started since then `.unknown` (Start) instead of waiting for the retry.
                checked.removeValue(forKey: computer.id)
                continue
            }
            sessions[computer.id] = names
            listed[computer.id] = listing.askedAt
            checked[computer.id] = listing.askedAt
        }
        if sessions != liveTmux { liveTmux = sessions }
        if listed != listedAt { listedAt = listed }
        if checked != livenessChecked { livenessChecked = checked }
    }

    /// Shell task identity. A pass that starts before computers or hosts exist changes this
    /// when they arrive, so the listing runs again instead of keeping the empty result.
    func automaticLivenessID(hostIDs: [UUID]) -> String {
        let computers = store.computers.map(\.id).sorted().joined(separator: ",")
        let hosts = hostIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(relistRequests)|\(computers)|\(hosts)"
    }

    /// The shell asks once per change. A failed computer is forgotten, then asked again after
    /// `staleRetryDelay`, so a throw does not leave the conversation unconfirmed.
    private func scheduleStaleRetry(failedComputers: Set<String>) {
        let keys = Set(board.newerThanListing.filter { failedComputers.contains($0.computer.id) }.map(Self.relistKey))
        guard !keys.isEmpty else { return }
        relistedFor.subtract(keys)
        staleRetry?.cancel()
        let delay = staleRetryDelay
        staleRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.staleRetry = nil
            let still = Set(self.board.newerThanListing.map(Self.relistKey)).subtracting(self.relistedFor)
            guard !still.isEmpty else { return }
            self.relistRequests += 1
        }
    }

    /// Lists the computer of the todo's displayed conversation, the one `attachReadiness`
    /// judges, or every computer when it has none.
    func refreshLiveness(forTodo id: String, hosts: [HostEntity]) async {
        let computerID = store.displayed(forTodo: id, selectedKey: selectedConversationID)?.computer.id
        await refreshLiveness(hosts: hosts, scope: computerID.map(LivenessScope.computer) ?? .full)
    }

    /// Whether the Mac's selection may attach to this todo's conversation. Attaching runs
    /// `ai-todo-open`, which recreates a dead tmux session, so it needs the session seen alive.
    func attachReadiness(forTodo id: String) -> AttachReadiness {
        guard let conversation = store.displayed(forTodo: id, selectedKey: selectedConversationID),
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
