import AISessionCore
import Foundation
import Observation

/// App-level state shared by the whole UI: the hub store, which tmux sessions are really alive
/// on each computer, and the navigation selection. Created once in `AISessionRemoteApp`.
@MainActor
@Observable
final class AppModel {
    typealias TmuxListing = @Sendable (Computer) async throws -> Set<String>

    enum SidebarItem: Hashable {
        case needsYou, runningNow, section(TodoSection), computer(String)
    }

    let store: TodoHubStore
    /// computerID to its tmux session names. A computer that is absent is unknown (its hub
    /// status is kept).
    private(set) var liveTmux: [String: Set<String>] = [:]

    var sidebarSelection: SidebarItem?
    var selectedTodoID: String?
    var poppedOut: Set<String> = []
    /// Set by notification taps and the palette.
    var pendingOpenTodoID: String?

    /// Replaces the SSH listing; tests inject it. Production builds it from the hosts.
    private let listTmuxOverride: TmuxListing?
    /// Incremented per refresh; only the latest, uncancelled one may publish its result.
    private var livenessGeneration = 0

    var board: ConversationBoard {
        ConversationBoard(todos: store.todos, conversations: store.conversations, liveTmux: liveTmux)
    }

    #if DEBUG
    init(store: TodoHubStore? = nil, demo: Bool = DemoFixtures.isEnabled, listTmux: TmuxListing? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
        if demo {
            store.seedForDemo(
                todos: DemoFixtures.todos, conversations: DemoFixtures.conversations,
                sectionComputers: DemoFixtures.sectionComputers, computers: DemoFixtures.computers
            )
        }
    }
    #else
    init(store: TodoHubStore? = nil, listTmux: TmuxListing? = nil) {
        let store = store ?? TodoHubStore()
        self.store = store
        self.listTmuxOverride = listTmux
    }
    #endif

    /// Lists tmux sessions once per hub computer, in parallel. A computer with no matching
    /// host, or whose listing fails, is left out of `liveTmux`.
    func refreshLiveness(hosts: [HostEntity]) async {
        #if DEBUG
        // Demo data never touches the network; keep the seeded statuses.
        if DemoFixtures.isEnabled && listTmuxOverride == nil { return }
        #endif
        livenessGeneration += 1
        let generation = livenessGeneration
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
