import Foundation

/// A message typed on the phone that the transcript doesn't show yet. `afterCount` is how many
/// transcript entries there were when it was sent, so only a later user entry confirms it.
public struct PendingSend: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let afterCount: Int
    public let sentAt: Date

    public init(id: UUID = UUID(), text: String, afterCount: Int, sentAt: Date = Date()) {
        self.id = id
        self.text = text
        self.afterCount = afterCount
        self.sentAt = sentAt
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
    /// How many items the chat draws at first; "Show earlier messages" adds this many more.
    public static let windowSize = 80

    /// The newest `limit` items, and how many older ones are left out.
    public static func window(_ items: [ChatItem], limit: Int) -> (items: ArraySlice<ChatItem>, hidden: Int) {
        let hidden = max(0, items.count - limit)
        return (items.dropFirst(hidden), hidden)
    }

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

    /// A send nothing in the transcript has confirmed by then is dropped: Codex doesn't log
    /// slash commands at all.
    public static let pendingTimeout: TimeInterval = 30

    /// Sends the transcript doesn't show yet. Each user entry at or after a send's `afterCount`
    /// confirms one send: the one with the same text first, otherwise the oldest, since a tool
    /// may log a message differently (Claude stores `/compact` inside command tags).
    public static func unconfirmed(_ pending: [PendingSend], in entries: [ConversationMessage], now: Date = Date()) -> [PendingSend] {
        let users = entries.indices.filter { entries[$0].role == .user }
        var used = Set<Int>()
        var confirmed = Set<UUID>()
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for send in pending {
            if let match = users.first(where: { $0 >= send.afterCount && !used.contains($0) && trimmed(entries[$0].text) == trimmed(send.text) }) {
                used.insert(match)
                confirmed.insert(send.id)
            }
        }
        for send in pending where !confirmed.contains(send.id) {
            if let match = users.first(where: { $0 >= send.afterCount && !used.contains($0) }) {
                used.insert(match)
                confirmed.insert(send.id)
            }
        }
        return pending.filter { !confirmed.contains($0.id) && now.timeIntervalSince($0.sentAt) <= pendingTimeout }
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
