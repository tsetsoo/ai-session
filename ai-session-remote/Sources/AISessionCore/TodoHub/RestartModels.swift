import Foundation

// Restarting one conversation on its computer (`ai-todo-status restart`): on the installed
// CLI version, optionally with other MCP servers or Claude in Chrome. Only on the user's
// request; installing an update never restarts anything.

/// Claude in Chrome for a conversation: Claude's own setting, or on / off for this one.
public enum ChromeChoice: String, CaseIterable, Sendable, Equatable {
    case keep, `default`, on, off

    /// What the conversation has now (`chrome` from `launch show`).
    public init(saved: Bool?) {
        switch saved {
        case true?: self = .on
        case false?: self = .off
        case nil: self = .default
        }
    }

    public var title: String {
        switch self {
        case .keep: "Unchanged"
        case .default: "Claude's setting"
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// What a restart did. `result`: restarted, stopped (the app reattaches), refused or failed.
public struct RestartResult: Decodable, Equatable, Sendable {
    public var result: String
    /// Refused: busy, waiting, unknown or background.
    public var reason: String?
    public var message: String?
    /// Failed: writer (another Codex holds it) or reopen.
    public var stage: String?
    public var before: String?
    public var after: String?
    public var installed: String?
    public var mode: String?

    public var isRefused: Bool { result == "refused" }
    /// Working or waiting can be restarted anyway once the user says so; background tasks can't.
    public var canForce: Bool { isRefused && reason != "background" }

    public static func decode(_ data: Data) throws -> RestartResult {
        try TodoHubClient.makeDecoder().decode(RestartResult.self, from: data)
    }
}

/// A conversation's saved launch settings (`ai-todo-status launch show`).
public struct LaunchSettings: Decodable, Equatable, Sendable {
    public var chrome: Bool?
    public var model: String?
    public var permissionMode: String?
    public var network: Bool?

    public static func decode(_ data: Data) throws -> LaunchSettings {
        try TodoHubClient.makeDecoder().decode(LaunchSettings.self, from: data)
    }
}
