import Foundation

/// What an added agent starts from: a summary of the conversation it comes from (the default,
/// edited before it's sent), the whole conversation, or the todo's first message afresh.
public enum AddAgentHandoff: String, CaseIterable, Sendable {
    case summary, full, fresh

    public static let defaultChoice: AddAgentHandoff = .summary
}

/// How an added agent is created and started.
public struct AddAgentPlan: Equatable, Sendable {
    /// Which commit a new worktree starts from.
    public enum Base: Equatable, Sendable {
        /// The source conversation's current state, uncommitted work included (a snapshot).
        case sourceSnapshot
        /// The commit the source started from (a fresh attempt at the same task).
        case sourceBase
    }

    public enum Start: Equatable, Sendable {
        /// Claude to Claude, the whole conversation: `claude --resume <id> --fork-session`.
        case fork(sourceSessionId: String)
        /// The new tool's first message (`ai-todo-open --prompt-file`).
        case firstPrompt(String)
        /// Nothing is created. `reason` is shown when there is one.
        case cancelled(reason: String?)
    }

    public var tool: String
    public var model: String?
    public var label: String
    /// A worktree of its own (else it shares the source's folder).
    public var ownWorktree: Bool
    public var base: Base
    public var start: Start
    /// The sheet says both agents will work in the same folder.
    public var sharesFolderWarning: Bool { !ownWorktree }
}

public enum AddAgent {
    public static func plan(
        source: Conversation, tool: String, model: String?, label: String, handoff: AddAgentHandoff,
        projectWorktrees: Bool, transcript: String, firstUserMessage: String?, confirmedSummary: String?
    ) -> AddAgentPlan {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = confirmedSummary.flatMap { nonEmpty($0) }
        let start: AddAgentPlan.Start
        switch handoff {
        case .summary:
            start = summary.map { .firstPrompt($0) } ?? .cancelled(reason: nil)
        case .full:
            if source.tool == tool, ForkCommand.arguments(tool: tool, sessionId: source.sessionId) != nil {
                start = .fork(sourceSessionId: source.sessionId)
            } else if let text = nonEmpty(transcript), TranscriptBudget.fits(tool: tool, characterCount: text.count) {
                start = .firstPrompt(text)
            } else {
                start = summary.map { .firstPrompt($0) } ?? .cancelled(reason: nil)
            }
        case .fresh:
            start = firstUserMessage.flatMap { nonEmpty($0) }.map { .firstPrompt($0) }
                ?? .cancelled(reason: "No first message found")
        }
        return AddAgentPlan(
            tool: tool, model: model?.isEmpty == false ? model : nil, label: label,
            ownWorktree: projectWorktrees && source.worktreeSource != nil,
            base: handoff == .fresh ? .sourceBase : .sourceSnapshot, start: start
        )
    }

    /// The first thing the user asked in a conversation (Fresh with the same first message).
    public static func firstUserMessage(_ messages: [ConversationMessage]) -> String? {
        messages.first { $0.role == .user }.flatMap { nonEmpty($0.text) }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
