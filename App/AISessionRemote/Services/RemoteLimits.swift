import AISessionCore
import Foundation

/// The computer's own usage limits (`ai-todo-limits` over SSH). A missing
/// script is an empty result: the chat simply shows no strip. Any other
/// failure throws so the caller can keep the numbers it already has.
enum RemoteLimits {
    struct Unavailable: Error {}

    static func fetch(
        config: HostConnectionConfig,
        tool: String,
        sessionId: String?
    ) async throws -> UsageLimits {
        let result = try await NIOSSHClient(execTimeoutSeconds: 15).exec(
            config,
            command: TmuxCommandBuilder.usageLimits(tool: tool, sessionId: sessionId)
        )
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode {
            return UsageLimits(tool: tool, windows: [])
        }
        guard result.exitCode == 0 else { throw Unavailable() }
        return try UsageLimits.parse(result.stdout)
    }
}
