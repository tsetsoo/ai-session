import Foundation

public enum SessionServiceError: Error, Equatable, Sendable, LocalizedError {
    case invalidSlug(String)
    case metadataEncodingFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidSlug(slug):
            return "\"\(slug)\" is not a valid session name. Use lowercase letters, numbers, and hyphens only."
        case .metadataEncodingFailed:
            return "Could not prepare session metadata for this session. Please try again."
        }
    }
}

public struct SessionService: Sendable {
    private let ssh: any SSHExecuting
    private let binaryOverrides: [AITool: String]

    public init(ssh: any SSHExecuting, binaryOverrides: [AITool: String] = [:]) {
        self.ssh = ssh
        self.binaryOverrides = binaryOverrides
    }

    public func probeTmux(config: HostConnectionConfig) async throws {
        let result = try await ssh.exec(config, command: TmuxCommandBuilder.ensureTmuxInstalledCheck())
        guard result.exitCode == 0 else {
            throw SSHRemoteError.tmuxMissing
        }
    }

    public func probeBinaries(config: HostConnectionConfig) async throws -> HostBinaryHealth {
        let result = try await ssh.exec(config, command: TmuxCommandBuilder.probeBinaries())
        try requireSuccess(result)
        var paths: [String: String?] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            paths[pieces[0]] = pieces[1] == "MISSING" ? nil : pieces[1]
        }
        return HostBinaryHealth(
            tmux: paths["tmux"] ?? nil,
            claude: paths["claude"] ?? nil,
            codex: paths["codex"] ?? nil,
            agent: paths["agent"] ?? nil,
            shell: paths["bash"] ?? nil
        )
    }

    public func listSessions(
        config: HostConnectionConfig
    ) async throws -> (ai: [RemoteSession], other: [RemoteSession]) {
        do {
            let result = try await ssh.exec(config, command: TmuxCommandBuilder.listSessions())
            if result.exitCode == 0 {
                let sessions = TmuxListParser.parse(listSessionsOutput: result.stdout)
                do {
                    let statusResult = try await ssh.exec(config, command: TmuxCommandBuilder.readAgentStatuses())
                    if statusResult.exitCode == 0 {
                        return TmuxListParser.applyAgentStatuses(
                            TmuxListParser.parseAgentStatuses(output: statusResult.stdout),
                            to: sessions
                        )
                    }
                } catch {
                    // Agent status files are supplemental and must not make listing fail.
                }
                return sessions
            }
            guard isNoServerError(result.stderr) else {
                throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            return (ai: [], other: [])
        } catch let error as SSHRemoteError {
            if case let .commandFailed(_, stderr) = error, isNoServerError(stderr) {
                return (ai: [], other: [])
            }
            throw error
        }
    }

    public func createSession(
        config: HostConnectionConfig,
        tool: AITool,
        slug: String,
        cwd: String,
        title: String?
    ) async throws -> SessionName {
        let binary = binaryOverrides[tool] ?? tool.defaultBinary
        var lastDuplicateError: SSHRemoteError?

        for _ in 0..<3 {
            let existing = try await listSessions(config: config)
            let existingNames = Set(existing.ai.map(\.tmuxName) + existing.other.map(\.tmuxName))
            guard let name = SessionName.makeUnique(tool: tool, slug: slug, existing: existingNames) else {
                throw SessionServiceError.invalidSlug(slug)
            }

            let whichResult = try await ssh.exec(config, command: TmuxCommandBuilder.which(binary: binary))
            guard whichResult.exitCode == 0 else {
                throw SSHRemoteError.binaryMissing(binary)
            }
            let resolvedBinary = whichResult.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)
            guard let resolvedBinary, !resolvedBinary.isEmpty else {
                throw SSHRemoteError.binaryMissing(binary)
            }

            let metadata = SessionMetadata(
                tool: tool,
                cwd: cwd,
                title: title ?? slug,
                startedAt: Date(),
                cli: [resolvedBinary]
            )
            guard let json = String(data: try metadata.jsonData(), encoding: .utf8) else {
                throw SessionServiceError.metadataEncodingFailed
            }

            let metadataResult = try await ssh.exec(
                config,
                command: TmuxCommandBuilder.writeMetadata(tmuxName: name.tmuxName, json: json)
            )
            try requireSuccess(metadataResult)

            do {
                let sessionResult = try await ssh.exec(
                    config,
                    command: TmuxCommandBuilder.newDetachedSession(
                        name: name,
                        cwd: cwd,
                        commandArgs: [resolvedBinary]
                    )
                )
                guard sessionResult.exitCode == 0 else {
                    let error = SSHRemoteError.commandFailed(
                        exitCode: sessionResult.exitCode,
                        stderr: sessionResult.stderr
                    )
                    guard isDuplicateSessionError(sessionResult.stderr) else {
                        throw error
                    }
                    lastDuplicateError = error
                    continue
                }
                return name
            } catch let error as SSHRemoteError {
                guard isDuplicateSessionError(error) else {
                    throw error
                }
                lastDuplicateError = error
            }
        }

        guard let lastDuplicateError else {
            fatalError("Session creation retry loop exited without a result")
        }
        throw lastDuplicateError
    }

    public func killSession(config: HostConnectionConfig, tmuxName: String) async throws {
        let result = try await ssh.exec(
            config,
            command: TmuxCommandBuilder.killSession(tmuxName: tmuxName)
        )
        try requireSuccess(result)
    }

    public func promoteSession(
        config: HostConnectionConfig,
        fromTmuxName: String,
        to name: SessionName
    ) async throws {
        let renameResult = try await ssh.exec(
            config,
            command: TmuxCommandBuilder.renameSession(from: fromTmuxName, to: name.tmuxName)
        )
        try requireSuccess(renameResult)

        let metadata = SessionMetadata(
            tool: name.tool,
            cwd: "/",
            title: name.slug,
            startedAt: Date(),
            cli: [name.tool.defaultBinary]
        )
        guard let json = String(data: try metadata.jsonData(), encoding: .utf8) else {
            throw SessionServiceError.metadataEncodingFailed
        }
        let metadataResult = try await ssh.exec(
            config,
            command: TmuxCommandBuilder.writeMetadata(tmuxName: name.tmuxName, json: json)
        )
        try requireSuccess(metadataResult)
    }

    private func requireSuccess(_ result: SSHExecResult) throws {
        guard result.exitCode == 0 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private func isNoServerError(_ stderr: String) -> Bool {
        let message = stderr.lowercased()
        // Fresh hosts (never started tmux) often report a missing socket path
        // rather than the friendlier "no server running" wording.
        return message.contains("no server running")
            || message.contains("failed to connect to server")
            || message.contains("can't find socket")
            || message.contains("error connecting to")
            || message.contains("no such file or directory")
            || message.contains("no sessions")
    }

    private func isDuplicateSessionError(_ stderr: String) -> Bool {
        stderr.lowercased().contains("duplicate session")
    }

    private func isDuplicateSessionError(_ error: SSHRemoteError) -> Bool {
        guard case let .commandFailed(_, stderr) = error else { return false }
        return isDuplicateSessionError(stderr)
    }
}
