import Foundation

/// A direct read of the host's monitor heartbeats, independent of status-change dates.
public struct StatusMonitorSnapshot: Sendable {
    private struct Pulse: Decodable, Sendable {
        var checked_ns: Double?
        var runtime_connected: Bool?
    }
    private struct Wire: Decodable {
        var host_time_s: Double
        var codex: Pulse?
        var claude: Pulse?
        var codex_runtime: Runtime?
        var claude_runtime: Runtime?
    }
    private struct Runtime: Decodable, Sendable {
        var observed_ns: Double?
        var threads: [String: [String?]]?
    }
    public let receivedAt: Date
    private let hostTime: Double
    private let codex: Pulse?
    private let claude: Pulse?
    private let codexRuntime: Runtime?
    private let claudeRuntime: Runtime?

    public init(data: Data, receivedAt: Date) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        self.receivedAt = receivedAt
        hostTime = wire.host_time_s
        codex = wire.codex
        claude = wire.claude
        codexRuntime = wire.codex_runtime
        claudeRuntime = wire.claude_runtime
    }

    /// Use the host's clock to age its own heartbeat, avoiding cross-machine clock skew.
    public func confirmedAt(tool: String, sessionID: String? = nil) -> Date? {
        let pulse: Pulse?
        let runtime: Runtime?
        let maximumAge: Double
        switch tool {
        case "claude": pulse = claude; runtime = claudeRuntime; maximumAge = 12
        case "codex": pulse = codex; runtime = codexRuntime; maximumAge = 8
        default: return nil
        }
        guard pulse?.runtime_connected == true, let checked = pulse?.checked_ns else { return nil }
        var age = hostTime - checked / 1_000_000_000
        guard age >= -1, age < maximumAge else { return nil }
        if let sessionID {
            guard let state = runtime?.threads?[sessionID], let value = state.first ?? nil,
                  ["busy", "idle", "waiting"].contains(value), let observed = runtime?.observed_ns else { return nil }
            let runtimeAge = hostTime - observed / 1_000_000_000
            guard runtimeAge >= -1, runtimeAge < maximumAge else { return nil }
            age = max(age, runtimeAge)
        }
        return receivedAt.addingTimeInterval(-max(0, age))
    }
}

public struct StatusFreshness: Equatable, Sendable {
    public enum State: Equatable, Sendable { case live, checking, offline, unavailable, stale }
    public var state: State
    public var lastConfirmedAt: Date?

    public init(state: State, lastConfirmedAt: Date? = nil) {
        self.state = state
        self.lastConfirmedAt = lastConfirmedAt
    }
}
