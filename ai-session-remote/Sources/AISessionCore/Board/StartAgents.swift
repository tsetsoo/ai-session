import Foundation

/// The commit a start's agents all begin from (`ai-todo-workspace base`): a sha and what it
/// is, `origin/main` or `HEAD` when the repo has no origin.
public struct StartBase: Equatable, Sendable {
    public let sha: String
    public let ref: String

    public init(sha: String, ref: String) {
        self.sha = sha
        self.ref = ref
    }
}

/// Starting a todo with several agents: rows of tool + model (the Research Now rules), one
/// first message for all of them, and one base commit, each agent in its own worktree.
public enum StartAgents {
    /// `<sha> <ref>` from `ai-todo-workspace base`; nil for anything else.
    public static func parseBase(_ stdout: String) -> StartBase? {
        guard let line = stdout.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, (7...40).contains(parts[0].count), parts[0].allSatisfy(\.isHexDigit) else { return nil }
        return StartBase(sha: String(parts[0]), ref: String(parts[1]))
    }

    /// `from origin/main @ 8f5a29c`.
    public static func baseLine(_ base: StartBase) -> String {
        let short = base.sha.prefix(7)
        return base.ref == "HEAD" ? "from this computer's current commit @ \(short)" : "from \(base.ref) @ \(short)"
    }

    /// Why the base couldn't be found, from `ai-todo-workspace base`'s exit.
    public static func baseFailure(exitCode: Int32, stderr: String, computer: String) -> String {
        switch exitCode {
        case 66: return "This folder isn't a git repository, so several agents can't each get their own copy."
        case 64, 127: return "Update the scripts on \(computer) to start several agents."
        default:
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Couldn't find the latest main on \(computer)." + (detail.isEmpty ? "" : " \(detail)")
        }
    }

    /// Why this project can't start several agents (they would share one folder), or nil.
    public static func refusal(project: Project?) -> String? {
        guard let project else { return "This todo has no project, so several agents can't each get their own copy." }
        if !project.worktrees {
            return "This project has worktrees turned off. Several agents can't share one folder. Start with one agent, or turn worktrees on in the project's settings."
        }
        if (project.repoUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "This project has no repository, so several agents can't each get their own copy. Start with one agent."
        }
        return nil
    }

    /// The row Add Agent adds: a tool not picked yet, else the last row's.
    public static func addedRow(to rows: [ResearchAgentRow], offered: [String]) -> ResearchAgentRow {
        let tool = offered.first { tool in !rows.contains { $0.tool == tool } } ?? rows.last?.tool ?? offered.first ?? "claude"
        return ResearchAgentRow(tool: tool)
    }

    public static func firstMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One agent starts as it always has. Several need offered tools, valid models, a first
    /// message, the base, and a project that gives each its own worktree.
    public static func canStart(rows: [ResearchAgentRow], text: String, offered: [String], base: StartBase?, refusal: String?) -> Bool {
        if rows.count == 1 { return true }
        guard (2...ResearchAgents.maxAgents).contains(rows.count) else { return false }
        return rows.allSatisfy { offered.contains($0.tool) && ResearchAgents.isValidModel($0.model) }
            && firstMessage(text) != nil && base != nil && refusal == nil
    }

    /// The names of the agents after the first (the todo's main conversation has none):
    /// `Codex`, `Claude · opus`, and ` 2`, ` 3` on repeats.
    public static func labels(_ rows: [ResearchAgentRow]) -> [String] {
        func name(_ row: ResearchAgentRow) -> String {
            let model = row.model.trimmingCharacters(in: .whitespaces)
            return ResearchAgents.toolName(row.tool) + (model.isEmpty ? "" : " · \(model)")
        }
        var counts: [String: Int] = [:]
        return rows.enumerated().compactMap { index, row in
            let base = name(row)
            counts[base, default: 0] += 1
            guard index > 0 else { return nil }
            let n = counts[base]!
            return n == 1 ? base : "\(base) \(n)"
        }
    }

    /// An older hub drops the model or base it was asked for; its agents would not start
    /// from the shown commit.
    public static func hubIgnored(asked: (model: String?, baseSha: String?), got: Conversation) -> Bool {
        if let sha = asked.baseSha, got.worktreeBase != sha { return true }
        if let model = asked.model, got.model != model { return true }
        return false
    }

    /// The open made this row: its id wasn't among the todo's conversations this device knew
    /// just before. Anything else is an existing conversation, never removed or re-prompted.
    public static func createdByThisOpen(_ conversation: Conversation, knownIds: Set<String>) -> Bool {
        !knownIds.contains(conversation.id)
    }

    /// `2 of 3 agents started. Codex didn't start: …`; nil when all started.
    public static func startedNote(total: Int, failures: [(label: String, message: String)]) -> String? {
        guard !failures.isEmpty else { return nil }
        let started = "\(total - failures.count) of \(total) agents started."
        return ([started] + failures.map { "\($0.label) didn't start: \($0.message)" }).joined(separator: " ")
    }

    /// The rows in the order they open: the first Claude or Codex row moves to the front,
    /// because added agents copy the first one's MCP selection and Cursor has none.
    public static func openingOrder(_ rows: [ResearchAgentRow]) -> [ResearchAgentRow] {
        guard let index = rows.firstIndex(where: { $0.tool != "cursor" }), index > 0 else { return rows }
        var ordered = rows
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    public struct Outcome: Sendable {
        public let first: Conversation
        public let failures: [(label: String, message: String)]
    }

    /// Opens the first agent (the todo's main conversation); a failure there throws and nothing
    /// else starts. Then adds the others at once: one that fails is reported, the rest keep
    /// going. Failures come back in row order.
    public static func run(
        rows: [ResearchAgentRow],
        openFirst: @escaping @Sendable (ResearchAgentRow) async throws -> Conversation,
        add: @escaping @Sendable (Conversation, ResearchAgentRow, String) async throws -> Void,
        message: @escaping @Sendable (Error) -> String
    ) async throws -> Outcome {
        let rows = openingOrder(rows)
        guard let firstRow = rows.first else { throw CancellationError() }
        let first = try await openFirst(firstRow)
        let others = Array(zip(rows.dropFirst(), labels(rows)).enumerated())
        let failures = await withTaskGroup(of: (Int, String, String)?.self) { group in
            for (index, (row, label)) in others {
                group.addTask {
                    do {
                        try await add(first, row, label)
                        return nil
                    } catch {
                        return (index, label, message(error))
                    }
                }
            }
            var found: [(Int, String, String)] = []
            for await failure in group { if let failure { found.append(failure) } }
            return found.sorted { $0.0 < $1.0 }.map { (label: $0.1, message: $0.2) }
        }
        return Outcome(first: first, failures: failures)
    }
}
