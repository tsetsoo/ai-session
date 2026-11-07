import AISessionCore
import Foundation

/// Updating one agent CLI on a computer (`ai-todo-status upgrade TOOL` over SSH). Only on the
/// user's tap, from the computer's Health page.
enum RemoteUpgrade {
    /// Updated, current, unsupported and failed come back as results (with the computer's
    /// message); a computer that can't be reached or answers with no JSON throws.
    static func upgrade(_ tool: String, config: HostConnectionConfig, computerName: String) async throws -> UpgradeResult {
        // The script gives the updater 300 s; the rest is SSH and the version checks around it.
        let result = try await NIOSSHClient(execTimeoutSeconds: 360).exec(config, command: TmuxCommandBuilder.upgradeTool(tool))
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode || result.exitCode == 64 {
            throw RemoteRestart.OldScripts(computer: computerName)
        }
        if let decoded = try? UpgradeResult.decode(Data(result.stdout.utf8)) {
            return decoded
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw RemoteRestart.Failed(message: detail.isEmpty ? "The update failed (exit \(result.exitCode))." : String(detail.prefix(300)))
    }
}
