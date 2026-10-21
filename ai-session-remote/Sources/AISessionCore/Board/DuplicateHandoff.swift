import Foundation

/// How a duplicate starts when the destination is the same tool.
public enum ForkCommand {
    /// Claude forks with `claude --resume <id> --fork-session`. Codex and Cursor have no fork.
    public static func arguments(tool: String, sessionId: String) -> [String]? {
        guard tool == "claude" else { return nil }
        return ["claude", "--resume", sessionId, "--fork-session"]
    }
}

/// How much of a transcript the destination can take before the person reviews a summary.
public enum TranscriptBudget {
    public static func fits(tool: String, characterCount: Int) -> Bool {
        let limit = tool == "claude" ? 120_000 : 80_000
        return characterCount <= limit
    }
}

/// Chooses a native fork, the full transcript, or a summary the person confirms.
public enum DuplicateHandoff {
    public enum Decision: Equatable {
        case fork
        case sendTranscript
        case askForSummary
    }

    public enum Plan: Equatable {
        case fork(sourceSessionId: String, label: String)
        case start(text: String, label: String)
        case cancelled
    }

    /// Same tool with a native fork always forks, even when the transcript is over budget.
    /// Anything else sends the transcript when it fits and asks for a summary when it does not.
    public static func decide(sourceTool: String, destinationTool: String, transcript: String) -> Decision {
        if sourceTool == destinationTool, ForkCommand.arguments(tool: destinationTool, sessionId: "") != nil {
            return .fork
        }
        if TranscriptBudget.fits(tool: destinationTool, characterCount: transcript.count) {
            return .sendTranscript
        }
        return .askForSummary
    }

    /// `confirmedSummary == nil` while the decision is `askForSummary` cancels and describes no row.
    public static func plan(
        source: Conversation,
        destinationTool: String,
        label: String,
        transcript: String,
        confirmedSummary: String?
    ) -> Plan {
        switch decide(sourceTool: source.tool, destinationTool: destinationTool, transcript: transcript) {
        case .fork:
            return .fork(sourceSessionId: source.sessionId, label: label)
        case .sendTranscript:
            return .start(text: transcript, label: label)
        case .askForSummary:
            guard let confirmedSummary else { return .cancelled }
            return .start(text: confirmedSummary, label: label)
        }
    }
}
