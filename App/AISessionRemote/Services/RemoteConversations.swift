import AISessionCore
import Foundation

/// Conversations that live on a computer (Claude / Codex), reached over SSH through the
/// host-side `ai-todo-sessions` script. The todo hub only stores which one a todo links to.
enum RemoteConversations {
    struct ScriptMissing: LocalizedError {
        let computer: String
        var errorDescription: String? {
            "The todo scripts aren't installed on \(computer) (or are too old to list conversations). Run scripts/todo/install.sh there."
        }
    }

    struct UnreadableList: LocalizedError {
        let detail: String
        var errorDescription: String? { "Couldn't read the conversation list: \(detail)" }
    }

    /// Newest first, as the script returns them.
    static func list(config: HostConnectionConfig, computerName: String) async throws -> [RemoteConversation] {
        let result = try await NIOSSHClient().exec(config, command: TmuxCommandBuilder.listRemoteConversations())
        try check(result, computerName: computerName)
        do {
            return try RemoteConversation.decodeList(Data(result.stdout.utf8))
        } catch {
            throw UnreadableList(detail: String(describing: error))
        }
    }

    /// Ends the conversation's tmux session (if any), waits for it to stop, and deletes the
    /// conversation on the computer (Claude: its files; Codex: archived), all in one script
    /// run. A conversation that's already gone counts as deleted. The script refuses while
    /// another process still runs it, e.g. in a terminal outside tmux.
    static func delete(_ conversation: Conversation, config: HostConnectionConfig) async throws {
        let result = try await NIOSSHClient().exec(
            config,
            command: TmuxCommandBuilder.deleteRemoteConversation(
                tool: conversation.tool,
                sessionId: conversation.sessionId,
                tmuxName: conversation.tmuxName
            )
        )
        try check(result, computerName: conversation.computer.name)
    }

    private static func check(_ result: SSHExecResult, computerName: String) throws {
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode {
            throw ScriptMissing(computer: computerName)
        }
        guard result.exitCode == 0 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }
}

/// Finds the saved SSH host for a hub computer (same hostname, port and user) and loads its
/// connection config, including the private key from the Keychain.
enum HostLookup {
    enum Failure: LocalizedError {
        case noHost(Computer)
        case keyUnavailable(String)

        var errorDescription: String? {
            switch self {
            case let .noHost(computer):
                "No SSH host matches \(computer.username)@\(computer.hostname):\(computer.port). Add it under Hosts with its SSH key."
            case let .keyUnavailable(name):
                "The private key for \(name) is unavailable. Edit the host under Hosts and save its key again."
            }
        }
    }

    static func host(for computer: Computer, in hosts: [HostEntity]) -> HostEntity? {
        hosts.first {
            $0.hostname.caseInsensitiveCompare(computer.hostname) == .orderedSame
                && $0.port == computer.port
                && $0.username == computer.username
        }
    }

    static func config(for computer: Computer, in hosts: [HostEntity]) throws -> HostConnectionConfig {
        guard let host = host(for: computer, in: hosts) else { throw Failure.noHost(computer) }
        do {
            return try SessionServiceFactory().make(for: host).config
        } catch {
            throw Failure.keyUnavailable(host.displayName)
        }
    }
}
