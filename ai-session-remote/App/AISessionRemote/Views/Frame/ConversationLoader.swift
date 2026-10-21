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

    /// The conversation, not the todo: two conversations on one todo are two terminals.
    var id: String { conversation.listKey }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.hostID == rhs.hostID }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(hostID)
    }
}

/// Why the conversation frame can't show a terminal; each case maps to one problem card.
enum FrameProblem: Equatable {
    case noComputer(TodoSection)
    case needsAccess(Computer)
    case keyMissing(String)
    case unreachable(String)
    /// The computer turned this device's key down (or the key couldn't be read).
    case signInFailed(String)
    /// The computer's identity isn't the one this device trusted when it first connected.
    case hostKeyChanged(String)
    /// Signed in, but the computer wouldn't open a terminal.
    case terminalFailed(String)
    case helpersMissing(String)
    case toolMissing(String)
    case folderMissing(String, String)
    case conversationNotFound(String)
    /// The todo server turned the API token down.
    case tokenRejected
    case hub(String)
}

/// Why a terminal couldn't connect, in the frame's terms.
enum TerminalConnectFailure: Equatable {
    case unreachable
    case signIn
    case hostKeyChanged
    /// Anything else: the terminal itself couldn't be opened.
    case terminal

    /// A terminal's channel fails alike for a network, identity or key problem, so what the
    /// newest handshake with the host noted (`SSHSignInRecord`) decides between them; a failure
    /// to reach the host at all stays unreachable whatever an earlier attempt noted.
    static func classify(_ error: Error, signInProblem: SSHSignInRecord.Problem?) -> TerminalConnectFailure {
        if let failure = error as? SSHChannelOpenFailure {
            return classify(failure.underlying, signInProblem: signInProblem)
        }
        switch error {
        case SSHRemoteError.unreachable, SSHTerminalSessionError.connectionFailed:
            return .unreachable
        default:
            break
        }
        switch signInProblem {
        case .hostKeyChanged?: return .hostKeyChanged
        case .keyRejected?: return .signIn
        case nil: break
        }
        switch error {
        case SSHRemoteError.authenticationFailed, SSHTerminalSessionError.invalidPrivateKey:
            return .signIn
        default:
            return .terminal
        }
    }
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
                cachedConversation: { store.mostUrgent(forTodo: $0) },
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
            } catch TodoHubError.unauthorized {
                phase = .problem(.tokenRejected)
                return
            } catch {
                phase = .problem(.hub(TodoHubStore.message(for: error)))
                return
            }
        }
        resolve(conversation)
    }

    /// Attach this conversation even when another one of the same todo is already on screen.
    /// A closed conversation stays put: opening that one goes through the hub, which resets it.
    func show(_ conversation: Conversation) {
        guard phase != .preparing else { return }
        guard conversation.status != .closed else { return }
        guard ConversationStart.hasStartedSession(conversation.sessionId) else { return }
        if case let .ready(open) = phase, open.conversation.listKey == conversation.listKey { return }
        resolve(conversation)
    }

    /// The hub conversation already exists (the tool step just created it). Attach without
    /// opening a second one.
    func attachOpened(_ conversation: Conversation) {
        guard phase != .preparing else { return }
        phase = .preparing
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

    /// The frame calls this when the terminal's connect fails.
    func connectionFailed(_ failure: TerminalConnectFailure) {
        guard case let .ready(open) = phase else { return }
        let name = open.conversation.computer.name
        switch failure {
        case .unreachable: phase = .problem(.unreachable(name))
        case .signIn: phase = .problem(.signInFailed(name))
        case .hostKeyChanged: phase = .problem(.hostKeyChanged(name))
        case .terminal: phase = .problem(.terminalFailed(name))
        }
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
