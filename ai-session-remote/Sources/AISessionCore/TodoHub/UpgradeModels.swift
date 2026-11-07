import Foundation

// Updating one agent CLI on a computer (`ai-todo-status upgrade TOOL`), from its Health page.
// Only on the user's tap. Running conversations keep their version until they're restarted.

/// What an update did. `result`: updated, current, unsupported (an install the app doesn't
/// update itself; `command` says how) or failed.
public struct UpgradeResult: Decodable, Equatable, Sendable {
    public var tool: String
    public var result: String
    public var method: String?
    public var before: String?
    public var after: String?
    public var message: String?
    /// The update command, as typed in a shell on that computer.
    public var command: String?
    /// Codex: the version its shared server runs afterwards.
    public var daemon: String?

    public var isFailed: Bool { result == "failed" }

    public static func decode(_ data: Data) throws -> UpgradeResult {
        try TodoHubClient.makeDecoder().decode(UpgradeResult.self, from: data)
    }

    /// One line for the Health page, e.g. "Cursor updated to 2026.10.19 (was 2026.10.14)."
    public var summary: String {
        let name = HostHealth.toolName(tool)
        switch result {
        case "updated":
            var text = "\(name) updated"
            if let after { text += " to \(after)" }
            if let before, before != after { text += " (was \(before))" }
            return text + ". Running conversations keep the old version until they're restarted."
        case "current":
            return "\(name) is already the latest version" + (after.map { " (\($0))" } ?? "") + "."
        case "unsupported":
            return command.map { "\(name) isn't updated from here. Run this on the computer: \($0)" }
                ?? "\(name) comes with an app; update that app."
        default:
            return "\(name) wasn't updated: " + (message.flatMap { $0.isEmpty ? nil : $0 } ?? "the update failed.")
        }
    }
}
