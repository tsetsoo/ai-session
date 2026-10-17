import AISessionCore
import Foundation
import Observation

/// A todo's conversation opened on a known SSH host; drives navigation to the terminal.
/// The connection config (with the private key) is resolved once when opening, not on every
/// re-render of the destination.
struct OpenTodoConversation: Identifiable, Hashable {
    let conversation: Conversation
    let hostID: UUID
    let config: HostConnectionConfig
    let title: String

    var id: String { conversation.todoId }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.hostID == rhs.hostID }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Why the conversation frame can't show a terminal; each case maps to one problem card.
enum FrameProblem: Equatable {
    case noComputer(TodoSection)
    case needsAccess(Computer)
    case keyMissing(String)
    case unreachable(String)
    case helpersMissing(String)
    case toolMissing(String)
    case folderMissing(String, String)
    case conversationNotFound(String)
    case hub(String)
}

/// State machine behind the conversation frame: get-or-create the conversation on the hub (or
/// use the offline cache), resolve the SSH host, and map failures to a `FrameProblem`.
@MainActor
@Observable
final class ConversationLoader {
    enum Phase: Equatable {
        /// Not started: the frame shows Start / Resume.
        case idle
        case preparing
        case ready(OpenTodoConversation)
        case problem(FrameProblem)
    }

    struct Dependencies {
        var openConversation: (Todo) async throws -> Conversation
        var cachedConversation: (String) -> Conversation?
        var isOffline: () -> Bool
        /// Throws `HostLookup.Failure`.
        var resolveConfig: (Computer) throws -> (hostID: UUID, config: HostConnectionConfig)

        /// `hosts` is read on every resolve, so a host added while a problem shows counts on retry.
        @MainActor
        static func live(store: TodoHubStore, hosts: @escaping () -> [HostEntity]) -> Dependencies {
            Dependencies(
                openConversation: { try await store.openConversation(for: $0) },
                cachedConversation: { store.conversations[$0] },
                isOffline: { store.isOffline },
                resolveConfig: { computer in
                    guard let host = HostLookup.host(for: computer, in: hosts()) else {
                        throw HostLookup.Failure.noHost(computer)
                    }
                    do {
                        let connection = try SessionServiceFactory().make(for: host)
                        return (host.id, connection.config)
                    } catch {
                        throw HostLookup.Failure.keyUnavailable(host.displayName)
                    }
                }
            )
        }
    }

    private let todo: Todo
    private let dependencies: Dependencies
    private(set) var phase: Phase = .idle

    init(todo: Todo, dependencies: Dependencies) {
        self.todo = todo
        self.dependencies = dependencies
    }

    /// Explicit start: hub get-or-create (the cache when offline), then resolve the host.
    /// A no-op while already preparing; from a problem it retries.
    func start() async {
        guard phase != .preparing else { return }
        phase = .preparing
        let conversation: Conversation
        if dependencies.isOffline(), let cached = dependencies.cachedConversation(todo.id), cached.status != .closed {
            // The hub is down but the computer may not be: attach with what we know.
            conversation = cached
        } else {
            do {
                conversation = try await dependencies.openConversation(todo)
            } catch let TodoHubError.conflict(message) {
                phase = .problem(
                    message.localizedCaseInsensitiveContains("no computer")
                        ? .noComputer(todo.section)
                        : .hub(TodoHubStore.message(for: TodoHubError.conflict(message)))
                )
                return
            } catch {
                phase = .problem(.hub(TodoHubStore.message(for: error)))
                return
            }
        }
        resolve(conversation)
    }

    /// Selection path: attach only to a conversation that is already running. Never creates one.
    /// Synchronous, so a settled selection goes straight to the terminal without an idle frame.
    func attachIfRunning(_ conversation: Conversation?) {
        guard phase != .preparing, let conversation, conversation.status != .closed else { return }
        resolve(conversation)
    }

    /// The terminal session ended with the helper script's exit status. Known failures become a
    /// problem; anything else stays `.ready` (the terminal shows Disconnected).
    func ended(exitStatus: Int?) {
        guard case let .ready(open) = phase, let failure = OpenFailure(exitStatus: exitStatus) else { return }
        let name = open.conversation.computer.name
        switch failure {
        case .helpersMissing: phase = .problem(.helpersMissing(name))
        case .toolMissing: phase = .problem(.toolMissing(name))
        case .folderMissing: phase = .problem(.folderMissing(name, open.conversation.cwd))
        case .conversationNotFound: phase = .problem(.conversationNotFound(name))
        }
    }

    /// The conversation was closed or unlinked: back to Start / Resume.
    func reset() {
        phase = .idle
    }

    /// The frame calls this when the SSH connect fails.
    func connectionFailed() {
        guard case let .ready(open) = phase else { return }
        phase = .problem(.unreachable(open.conversation.computer.name))
    }

    private func resolve(_ conversation: Conversation) {
        do {
            let resolved = try dependencies.resolveConfig(conversation.computer)
            phase = .ready(OpenTodoConversation(
                conversation: conversation,
                hostID: resolved.hostID,
                config: resolved.config,
                title: todo.title
            ))
        } catch let HostLookup.Failure.noHost(computer) {
            phase = .problem(.needsAccess(computer))
        } catch let HostLookup.Failure.keyUnavailable(name) {
            phase = .problem(.keyMissing(name))
        } catch {
            phase = .problem(.hub(TodoHubStore.message(for: error)))
        }
    }
}
