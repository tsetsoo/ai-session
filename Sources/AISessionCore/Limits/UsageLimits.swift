import Foundation

/// Usage limits for the tool login on one computer, as printed by
/// `ai-todo-limits`. A window the plan does not have is absent.
public struct UsageLimits: Equatable, Sendable {
    public var tool: String
    public var windows: [UsageLimitWindow]

    public init(tool: String, windows: [UsageLimitWindow]) {
        self.tool = tool
        self.windows = windows
    }

    /// Decodes the script's JSON. Unknown window kinds are dropped. A body
    /// that is not this object throws.
    public static func parse(_ json: String) throws -> UsageLimits {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(Payload.self, from: Data(json.utf8))
        let windows = decoded.windows.compactMap { window -> UsageLimitWindow? in
            guard allowedKinds.contains(window.kind), let used = window.usedPercent, used >= 0 else { return nil }
            return UsageLimitWindow(
                kind: window.kind,
                usedPercent: used,
                resetsAt: HubDates.date(from: window.resetsAt),
                scope: window.scope.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return UsageLimits(tool: decoded.tool, windows: windows)
    }

    private static let allowedKinds: Set<String> = ["5h", "weekly", "monthly"]

    private struct Payload: Decodable {
        var tool: String
        var windows: [Window]

        struct Window: Decodable {
            var kind: String
            var usedPercent: Double?
            var resetsAt: String?
            var scope: String?
        }
    }
}

public struct UsageLimitWindow: Equatable, Sendable, Identifiable {
    public var kind: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var scope: String?

    public init(kind: String, usedPercent: Double, resetsAt: Date? = nil, scope: String? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    public var id: String { "\(kind)|\(scope ?? "")" }

    /// Short label in the chat strip: `5h`, `week`, `opus`, `month`, `on-demand`.
    public var title: String {
        switch kind {
        case "5h": "5h"
        case "weekly": scope.map { "\($0) week" } ?? "week"
        case "monthly": scope == "on-demand" ? "on-demand" : "month"
        default: kind
        }
    }

    public var percentText: String { "\(Int(usedPercent.rounded()))%" }

    /// The accent colour: three quarters of the window is gone.
    public var isElevated: Bool { usedPercent >= 75 }

    /// Semibold: the window is nearly used up.
    public var isHigh: Bool { usedPercent >= 90 }

    public var accessibilityText: String {
        var parts = ["\(spoken) limit", "\(Int(usedPercent.rounded())) percent used"]
        if let resetsAt {
            parts.append("resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: ", ")
    }

    private var spoken: String {
        switch kind {
        case "5h": "5 hour"
        case "weekly": scope.map { "weekly \($0)" } ?? "weekly"
        case "monthly": scope.map { "monthly \($0)" } ?? "monthly"
        default: kind
        }
    }
}
