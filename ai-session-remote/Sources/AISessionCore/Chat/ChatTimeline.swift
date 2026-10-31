import Foundation

/// A message typed on the phone that the transcript doesn't show yet. `afterCount` is how many
/// transcript entries there were when it was sent, so only a later user entry confirms it.
public struct PendingSend: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let afterCount: Int

    public init(id: UUID = UUID(), text: String, afterCount: Int) {
        self.id = id
        self.text = text
        self.afterCount = afterCount
    }
}

/// A one-line record of a prompt answered from the chat ("✓ Yes: npm test").
public struct AnsweredNote: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let afterCount: Int

    public init(id: UUID = UUID(), text: String, afterCount: Int) {
        self.id = id
        self.text = text
        self.afterCount = afterCount
    }
}

public enum ChatItem: Identifiable, Equatable {
    case time(id: String, Date)
    case message(ConversationMessage)
    /// Consecutive tool steps; the id is the first step's.
    case activity(id: String, steps: [ConversationMessage], summary: String)
    case pending(PendingSend)
    case note(AnsweredNote)

    public var id: String {
        switch self {
        case let .time(id, _): return "time-" + id
        case let .message(message): return message.id
        case let .activity(id, _, _): return "activity-" + id
        case let .pending(pending): return "pending-" + pending.id.uuidString
        case let .note(note): return "note-" + note.id.uuidString
        }
    }
}

/// Turns transcript entries into what the chat draws: messages, collapsed tool steps,
/// timestamps, and the phone's own not-yet-confirmed sends and answered prompts.
public enum ChatTimeline {
    /// A timestamp shows before the first timed entry and after a gap this long.
    public static let timeGap: TimeInterval = 30 * 60

    public static func items(entries: [ConversationMessage], pending: [PendingSend], notes: [AnsweredNote]) -> [ChatItem] {
        var items: [ChatItem] = []
        var steps: [ConversationMessage] = []
        var lastTime: Date?
        var local: [(afterCount: Int, item: ChatItem)] =
            notes.map { ($0.afterCount, .note($0)) } + pending.map { ($0.afterCount, .pending($0)) }
        local.sort { $0.afterCount < $1.afterCount }

        func flushSteps() {
            guard let first = steps.first else { return }
            items.append(.activity(id: first.id, steps: steps, summary: summary(steps)))
            steps = []
        }
        func flushLocal(upTo count: Int) {
            while let next = local.first, next.afterCount <= count {
                flushSteps()
                items.append(next.item)
                local.removeFirst()
            }
        }

        for (index, entry) in entries.enumerated() {
            flushLocal(upTo: index)
            if let time = entry.time {
                if lastTime.map({ time.timeIntervalSince($0) >= timeGap }) ?? true {
                    flushSteps()
                    items.append(.time(id: entry.id, time))
                }
                lastTime = time
            }
            if entry.role == .activity {
                steps.append(entry)
            } else {
                flushSteps()
                items.append(.message(entry))
            }
        }
        flushSteps()
        flushLocal(upTo: .max)
        return items
    }

    /// Sends the transcript doesn't show yet: no user entry at or after `afterCount` has the
    /// same text, ignoring surrounding whitespace.
    public static func unconfirmed(_ pending: [PendingSend], in entries: [ConversationMessage]) -> [PendingSend] {
        pending.filter { send in
            let text = send.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !entries.dropFirst(send.afterCount).contains {
                $0.role == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }
        }
    }

    /// "Read 2 files · edited 1 file · ran 3 commands". Reads and edits count distinct targets.
    public static func summary(_ steps: [ConversationMessage]) -> String {
        func count(_ kind: ActivityKind, distinct: Bool) -> Int {
            let matching = steps.filter { $0.kind ?? .other == kind }
            return distinct ? Set(matching.map { $0.target ?? "" }).count : matching.count
        }
        func phrase(_ n: Int, _ verb: String, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(verb)\(n) \(n == 1 ? one : many)"
        }
        let phrases = [
            phrase(count(.read, distinct: true), "read ", "file", "files"),
            phrase(count(.edit, distinct: true), "edited ", "file", "files"),
            phrase(count(.run, distinct: false), "ran ", "command", "commands"),
            phrase(count(.search, distinct: false), "searched ", "time", "times"),
            phrase(count(.other, distinct: false), "", "other step", "other steps"),
        ].compactMap { $0 }
        let joined = phrases.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
