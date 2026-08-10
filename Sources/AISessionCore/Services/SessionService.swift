import Foundation

public enum SessionServiceError: Error, Equatable, Sendable {
    case invalidSlug(String)
    case metadataEncodingFailed
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

    public func listSessions(
        config: HostConnectionConfig
    ) async throws -> (ai: [RemoteSession], other: [RemoteSession]) {
        do {
            let result = try await ssh.exec(config, command: TmuxCommandBuilder.listSessions())
            if result.exitCode == 0 {
                return TmuxListParser.parse(listSessionsOutput: result.stdout)
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

            let metadata = SessionMetadata(
                tool: tool,
                cwd: cwd,
                title: title ?? slug,
                startedAt: Date(),
                cli: [binary]
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
                    command: TmuxCommandBuilder.newDetachedSession(name: name, cwd: cwd, commandArgs: [binary])
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

    private func requireSuccess(_ result: SSHExecResult) throws {
        guard result.exitCode == 0 else {
            throw SSHRemoteError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    private func isNoServerError(_ stderr: String) -> Bool {
        let message = stderr.lowercased()
        return message.contains("no server running")
            || message.contains("failed to connect to server")
            || message.contains("can't find socket")
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
