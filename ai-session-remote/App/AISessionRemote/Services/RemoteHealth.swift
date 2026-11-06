import AISessionCore
import Foundation

/// The computer's doctor report, read over SSH (`ai-todo-status doctor`). Read-only: it
/// starts, stops and updates nothing.
enum RemoteHealth {
    struct ScriptMissing: LocalizedError {
        let computer: String
        var errorDescription: String? {
            "The todo scripts aren't installed on \(computer). Run scripts/todo/install.sh there."
        }
    }

    struct Failed: LocalizedError {
        let detail: String
        var errorDescription: String? { "Couldn't check this computer: \(detail)" }
    }

    static func fetch(config: HostConnectionConfig, computerName: String) async throws -> HostHealth {
        // It asks each CLI for its version and login and lists every process: a few seconds.
        let result = try await NIOSSHClient(execTimeoutSeconds: 45).exec(config, command: TmuxCommandBuilder.doctor)
        if result.exitCode == TmuxCommandBuilder.scriptMissingExitCode {
            throw ScriptMissing(computer: computerName)
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failed(detail: detail.isEmpty ? "exit \(result.exitCode)" : String(detail.prefix(300)))
        }
        do {
            return try HostHealth.decode(Data(result.stdout.utf8))
        } catch {
            throw Failed(detail: "the report wasn't readable")
        }
    }
}
