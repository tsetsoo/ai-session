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
    /// Codex: live web search chosen for this conversation (`--search`); nil when not chosen.
    public var search: Bool?
    /// The scripts report web search at all (older ones leave the key out).
    public var hasSearch: Bool
    public var model: String?
    public var permissionMode: String?
    public var network: Bool?

    private enum CodingKeys: String, CodingKey {
        case chrome, search, model, permissionMode, network
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chrome = try container.decodeIfPresent(Bool.self, forKey: .chrome)
        search = try container.decodeIfPresent(Bool.self, forKey: .search)
        hasSearch = container.contains(.search)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        network = try container.decodeIfPresent(Bool.self, forKey: .network)
    }

    public static func decode(_ data: Data) throws -> LaunchSettings {
        try TodoHubClient.makeDecoder().decode(LaunchSettings.self, from: data)
    }
}

/// Restart Idle… on a computer's Health page: what restarting each outdated conversation in
/// turn came to. A refused one (working, waiting, background tasks, unknown) is left as it is,
/// never forced.
public struct RestartBatch: Equatable, Sendable {
    public private(set) var restarted = 0
    /// Refused because it was working, waiting or running background tasks.
    public private(set) var left = 0
    /// Refused because its state couldn't be read.
    public private(set) var unreadable = 0
    /// "<title>: <why>" for each that failed.
    public private(set) var failures: [String] = []

    public init() {}

    public mutating func add(_ result: RestartResult, title: String) {
        if result.isRefused, result.reason == "unknown" {
            unreadable += 1
        } else if result.isRefused {
            left += 1
        } else if result.result == "failed" {
            failures.append("\(title): \(result.message ?? "The restart failed.")")
        } else {
            restarted += 1
        }
    }

    public mutating func addFailure(_ message: String, title: String) {
        failures.append("\(title): \(message)")
    }

    /// e.g. "Restarted 4. Left 1 that was busy. 1 failed: Fix login: …"
    public var summary: String {
        var parts = ["Restarted \(restarted)."]
        if left > 0 {
            parts.append("Left \(left) that \(left == 1 ? "was" : "were") working, waiting or running background tasks.")
        }
        if unreadable > 0 {
            parts.append("Left \(unreadable) whose state couldn't be read; restart \(unreadable == 1 ? "it" : "them") from \(unreadable == 1 ? "its row" : "their rows") if \(unreadable == 1 ? "it's" : "they're") idle.")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) failed: " + failures.joined(separator: "; "))
        }
        return parts.joined(separator: " ")
    }
}
