import Foundation

/// One agent row in the Research Now sheet: a tool and a model (empty: the tool's default).
public struct ResearchAgentRow: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tool: String
    public var model: String

    public init(id: UUID = UUID(), tool: String, model: String = "") {
        self.id = id
        self.tool = tool
        self.model = model
    }
}

/// Research Now asks which agents to use, every time: the sheet's rules, and how each
/// attempt is named on the idea page.
public enum ResearchAgents {
    public static let maxAgents = 10
    /// Cursor's `agent` takes the research prompt as its first message (checked by hand
    /// 2026-11-08; ai-todo-open passes it).
    public static let cursorTakesPrompt = true
    static let allTools = ["claude", "codex", "cursor"]

    /// The tools the sheet offers for a computer: those its runner reported, in a fixed order;
    /// all of them when it reported none.
    public static func offeredTools(installed: [String]?, cursorSupported: Bool = cursorTakesPrompt) -> [String] {
        let known = allTools.filter { cursorSupported || $0 != "cursor" }
        guard let installed else { return known }
        return known.filter(installed.contains)
    }

    /// Claude and Codex at their default models, keeping those offered; else the first offered.
    public static func defaults(offered: [String]) -> [ResearchAgentRow] {
        let picked = ["claude", "codex"].filter(offered.contains)
        return (picked.isEmpty ? Array(offered.prefix(1)) : picked).map { ResearchAgentRow(tool: $0) }
    }

    public static func canAdd(_ rows: [ResearchAgentRow]) -> Bool { rows.count < maxAgents }
    public static func canRemove(_ rows: [ResearchAgentRow]) -> Bool { rows.count > 1 }

    /// Empty (the default) or up to 80 of letters, digits and `._-[]`, as the hub takes it.
    public static func isValidModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 80 && trimmed.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "._-[]".contains($0) }
    }

    public static func countText(_ n: Int) -> String {
        n == 1 ? "Starts 1 conversation." : "Starts \(n) conversations."
    }

    public static func request(rows: [ResearchAgentRow], computerId: String) -> ResearchRequest {
        ResearchRequest(computerId: computerId, attempts: rows.map { AttemptSpec(tool: $0.tool, model: $0.trimmedModel) })
    }

    /// An older hub ignores the agents and starts one Claude run with its default model: say
    /// so when that isn't what was asked for.
    public static func legacyWarning(_ outcome: ResearchOutcome, rows: [ResearchAgentRow]) -> String? {
        guard case .legacy = outcome else { return nil }
        let askedForPlainClaude = rows.count == 1 && rows[0].tool == "claude"
            && rows[0].model.trimmingCharacters(in: .whitespaces).isEmpty
        return askedForPlainClaude ? nil : "This hub started Claude only. Update the hub to research with several agents."
    }

    public static func toolName(_ tool: String) -> String {
        tool.prefix(1).uppercased() + tool.dropFirst()
    }

    /// `Codex · gpt-6.1`, `Claude · default`: the heading of an attempt's findings.
    public static func label(_ attempt: IdeaAttempt) -> String {
        "\(toolName(attempt.tool)) · \(attempt.model ?? "default")"
    }

    /// A failed attempt, or one its computer never picked up, can be tried again.
    public static func canRetry(_ attempt: IdeaAttempt) -> Bool {
        ["failed", "missed"].contains(attempt.state)
    }

    /// Findings saved on the idea that no attempt shows (an older `ai-todo-idea` names no
    /// attempt), so they aren't hidden behind the per-attempt sections.
    public static func unattributedFindings(_ findings: String?, attempts: [IdeaAttempt]) -> String? {
        guard let findings, !findings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return attempts.contains { $0.findings == findings } ? nil : findings
    }

    /// Where an attempt without findings is; nil once it saved findings.
    public static func stateText(_ attempt: IdeaAttempt) -> String? {
        if let findings = attempt.findings, !findings.isEmpty { return nil }
        switch attempt.state {
        case "due", "waiting": return "Waiting to start"
        case "running": return "Starting…"
        case "failed": return "Failed: \(attempt.result ?? "it did not start")"
        case "missed", "skipped": return "Didn't start: its computer didn't pick it up in time"
        default: return "Working…"
        }
    }
}
