import Foundation

// A computer's health: its `ai-todo-status doctor` report, read live over SSH or as the last
// one the computer sent the hub (`GET /api/computers/{id}/health`). Every field is optional:
// an older script sends fewer, and an unknown value is shown as unknown, never as fine.

/// The doctor report as the script prints it.
public struct HostHealth: Decodable, Equatable, Sendable {
    /// 3 and up has versions, deliveries and running conversations; nil is an older script.
    public var doctorVersion: Int?
    /// When the computer ran it (nanoseconds since 1970).
    public var checkedNs: Int64?
    public var hostname: String?
    /// The Codex status service wrote its heartbeat in the last 8 seconds.
    public var serviceRunning: Bool?
    public var runtimeConnected: Bool?
    public var runtimeError: String?
    public var claudeService: ClaudeService?
    public var hooks: [Hook]?
    public var tools: [String: Tool]?
    public var deliveries: Deliveries?
    public var helpers: Helpers?
    /// nil: tmux couldn't be asked.
    public var running: [Running]?

    public struct ClaudeService: Decodable, Equatable, Sendable {
        public var fresh: Bool?
        public var runtimeConnected: Bool?
    }

    /// One of the Codex hooks that report status.
    public struct Hook: Decodable, Equatable, Sendable {
        public var eventName: String?
        public var enabled: Bool?
        public var trustStatus: String?
    }

    /// A CLI as a new conversation would start it.
    public struct Tool: Decodable, Equatable, Sendable {
        public var installed: Bool?
        public var path: String?
        public var version: String?
        /// native, managed, homebrew, npm, app or other: which updater owns it.
        public var method: String?
        public var error: String?
        public var auth: Auth?
        /// Codex's shared app-server.
        public var daemon: Daemon?
        /// How it's updated; nil from scripts older than updates from the app.
        public var update: Update?
    }

    /// `runs`: the app can update it (`ai-todo-status upgrade`). Otherwise `command` is what
    /// to run on the computer (npm, Homebrew…); nil for one that comes with an app.
    public struct Update: Decodable, Equatable, Sendable {
        public var runs: Bool?
        public var command: String?
    }

    public struct Auth: Decodable, Equatable, Sendable {
        /// nil: the check gave no answer.
        public var loggedIn: Bool?
        public var method: String?
        public var expiresAt: String?
    }

    public struct Daemon: Decodable, Equatable, Sendable {
        public var status: String?
        public var version: String?
    }

    /// Status updates still on the computer. Only `failing` is a problem: `unlinked` are
    /// conversations the hub doesn't know (not linked to a todo), `inFlight` are being sent.
    public struct Deliveries: Decodable, Equatable, Sendable {
        public var inFlight: Int?
        public var unlinked: Int?
        public var failing: Int?
        public var oldestFailingS: Int?
    }

    /// The installed host scripts.
    public struct Helpers: Decodable, Equatable, Sendable {
        public var commit: String?
        public var dirty: Bool?
        public var installedAt: String?
        /// The same on two computers: the same scripts.
        public var digest: String?
    }

    /// A conversation running in tmux, with the version its process actually runs.
    public struct Running: Decodable, Equatable, Sendable, Identifiable {
        public var tmux: String
        public var tool: String
        public var pid: Int?
        public var sessionId: String?
        public var version: String?
        /// Codex: the backend this conversation's terminal talks to.
        public var backendVersion: String?
        /// Not the installed version; nil when either is unknown.
        public var outdated: Bool?

        public var id: String { tmux }
    }

    /// The doctor's JSON as `ai-todo-status doctor` prints it.
    public static func decode(_ data: Data) throws -> HostHealth {
        try TodoHubClient.makeDecoder().decode(HostHealth.self, from: data)
    }

    public var checkedAt: Date? {
        checkedNs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000_000) }
    }

    /// The script on the computer predates versions and running conversations.
    public var isOldScript: Bool { (doctorVersion ?? 0) < 3 }

    public var outdatedRunning: [Running] { (running ?? []).filter { $0.outdated == true } }

    /// Tools in display order: Claude, Codex, Cursor, then any newer one.
    public var orderedTools: [(name: String, tool: Tool)] {
        let order = ["claude", "codex", "cursor"]
        return (tools ?? [:]).sorted { a, b in
            (order.firstIndex(of: a.key) ?? order.count, a.key) < (order.firstIndex(of: b.key) ?? order.count, b.key)
        }.map { ($0.key, $0.value) }
    }

    /// What needs attention, most important first. Empty: nothing found (not "all unknown").
    public var problems: [HealthProblem] {
        var found: [HealthProblem] = []
        if isOldScript {
            found.append(.init(kind: .oldScript, text: "This computer's scripts are older than the app. Reinstall them to see versions and running conversations."))
        }
        for (name, tool) in orderedTools where tool.installed == true && tool.auth?.loggedIn == false {
            found.append(.init(kind: .loggedOut, text: "\(HostHealth.toolName(name)) isn't logged in."))
        }
        if serviceRunning == false {
            found.append(.init(kind: .monitor, text: "The status monitor isn't running, so Codex statuses don't update."))
        }
        if claudeService?.fresh == false {
            found.append(.init(kind: .monitor, text: "The Claude status monitor stopped reporting."))
        }
        let untrusted = (hooks ?? []).filter { $0.enabled == false || ($0.trustStatus.map { $0 != "trusted" } ?? false) }
        if !untrusted.isEmpty {
            found.append(.init(kind: .hooks, text: "\(untrusted.count) Codex status hook\(untrusted.count == 1 ? " isn't" : "s aren't") trusted or enabled."))
        }
        if let failing = deliveries?.failing, failing > 0 {
            let age = deliveries?.oldestFailingS.map { " (oldest \(HostHealth.duration($0)))" } ?? ""
            found.append(.init(kind: .deliveries, text: "\(failing) status update\(failing == 1 ? " hasn't" : "s haven't") reached the hub\(age)."))
        }
        let outdated = outdatedRunning.count
        if outdated > 0 {
            found.append(.init(kind: .outdated, text: "\(outdated) conversation\(outdated == 1 ? " runs" : "s run") an older version than the one installed."))
        }
        return found
    }

    public static func toolName(_ key: String) -> String {
        switch key {
        case "claude": "Claude"
        case "codex": "Codex"
        case "cursor": "Cursor"
        default: key
        }
    }

    public static func methodName(_ method: String?) -> String? {
        switch method {
        case "native": "native installer"
        case "managed": "Codex managed package"
        case "homebrew": "Homebrew"
        case "npm": "npm"
        case "app": "app bundle"
        case "other": "other"
        default: nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 120 { return "\(seconds) s" }
        if seconds < 7200 { return "\(seconds / 60) min" }
        if seconds < 172_800 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) days"
    }
}

public struct HealthProblem: Equatable, Sendable, Hashable {
    public enum Kind: String, Sendable { case oldScript, loggedOut, monitor, hooks, deliveries, outdated }
    public var kind: Kind
    public var text: String
}

/// The hub's last report from a computer.
public struct ComputerHealthSnapshot: Decodable, Equatable, Sendable {
    public var computerId: String
    /// When the hub received it; nil before the computer has sent one.
    public var reportedAt: String?
    public var report: HostHealth?

    public var reportedDate: Date? { HubDates.date(from: reportedAt) }
}
