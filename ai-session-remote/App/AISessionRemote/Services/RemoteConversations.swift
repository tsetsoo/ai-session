import AISessionCore
import Foundation

/// Conversations that live on a computer (Claude / Codex), reached over SSH through the
/// host-side `ai-todo-sessions` script. The todo hub only stores which one a todo links to.
enum RemoteConversations {
    struct ScriptMissing: LocalizedError {
        let computer: String
        var errorDescription: String? {
            "The todo scripts aren't installed on \(computer), or are too old for this. Run scripts/todo/install.sh there."
        }
    }

    /// The conversation has no transcript, or none with text, on that computer. Retrying won't help.
    struct NoTranscript: LocalizedError {
        let computer: String
        var errorDescription: String? { "This conversation has no transcript on \(computer)." }
    }

    struct UnreadableList: LocalizedError {
        let detail: String
        var errorDescription: String? { "Couldn't read the conversation list: \(detail)" }
    }

    struct UnreadableMCPList: LocalizedError {
        let detail: String
        var errorDescription: String? { "Couldn't read the MCP server list: \(detail)" }
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

    /// The MCP server files on the computer, or nil when it has no `ai-todo-mcp` helper (127).
    static func listMCPServers(config: HostConnectionConfig, computerName: String) async throws -> [MCPServer]? {
        let result = try await NIOSSHClient().exec(config, command: TmuxCommandBuilder.listMCPServers())
        return try mcpServers(from: result, computerName: computerName)
    }

    static func mcpServers(from result: SSHExecResult, computerName: String) throws -> [MCPServer]? {
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode { return nil }
        try check(result, computerName: computerName)
        do {
            return try MCPServer.decodeList(Data(result.stdout.utf8))
        } catch {
            throw UnreadableMCPList(detail: String(describing: error))
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

    /// Gives the conversation on its computer the todo's new name. One that isn't there (66)
    /// has nothing to rename; 64 means scripts too old to know `rename`.
    static func rename(_ conversation: Conversation, to name: String, config: HostConnectionConfig) async throws {
        let result = try await NIOSSHClient().exec(
            config,
            command: TmuxCommandBuilder.renameRemoteConversation(
                tool: conversation.tool, sessionId: conversation.sessionId, name: name
            )
        )
        try checkRename(result, computerName: conversation.computer.name)
    }

    static func checkRename(_ result: SSHExecResult, computerName: String) throws {
        switch result.exitCode {
        case 66: return
        case 64: throw ScriptMissing(computer: computerName)
        default: try check(result, computerName: computerName)
        }
    }

    /// The conversations that carry their own name on the computer: Claude and Codex ones
    /// that have started (Cursor chats have no name to set).
    static func renamable(_ conversations: [Conversation]) -> [Conversation] {
        conversations.filter { ["claude", "codex"].contains($0.tool) && !$0.sessionId.isEmpty }
    }

    /// Maps the host scripts' exit codes: 127 the scripts are missing, 90 a program they need is
    /// (stderr is `<name> not found`), 94 no transcript. Anything else non-zero is a failure.
    static func check(_ result: SSHExecResult, computerName: String) throws {
        switch result.exitCode {
        case TmuxCommandBuilder.scriptMissingExitCode:
            throw ScriptMissing(computer: computerName)
        case TmuxCommandBuilder.binaryMissingExitCode:
            if let binary = missingBinary(in: result.stderr) { throw SSHRemoteError.binaryMissing(binary) }
        case TmuxCommandBuilder.noTranscriptExitCode:
            throw NoTranscript(computer: computerName)
        default:
            break
        }
        guard result.exitCode == 0 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private static func missingBinary(in stderr: String) -> String? {
        let line = stderr.split(separator: "\n").last { $0.hasSuffix(" not found") }
        guard let name = line?.dropLast(" not found".count), !name.isEmpty, !name.contains(" ") else { return nil }
        return String(name)
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
