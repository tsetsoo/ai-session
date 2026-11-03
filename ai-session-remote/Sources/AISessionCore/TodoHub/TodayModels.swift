import Foundation

// Today (`/api/today`, `/api/reminders`, `/api/people`): reminders, people's dates, the
// morning briefing and its settings. Times are Europe/Sofia wall-clock times, sent as
// `YYYY-MM-DD HH:MM`.

public enum TodayTime {
    public static let zone = TimeZone(identifier: "Europe/Sofia")!

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// `YYYY-MM-DD HH:MM` in Sofia.
    public static func wallClock(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: date) }
    public static func date(fromWallClock text: String) -> Date? { formatter("yyyy-MM-dd HH:mm").date(from: text) }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
}

public enum ReminderRepeat: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, daily, weekdays, weekly, monthly, yearly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "Once"
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
}

public struct Reminder: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    /// Sofia wall time, `YYYY-MM-DD HH:MM`.
    public var at: String
    public var nextAt: String
    public var `repeat`: ReminderRepeat
    /// `upcoming`, `due` or `done`.
    public var state: String
    public var source: String
    public var createdAt: String
    public var updatedAt: String

    public var isDue: Bool { state == "due" }
    public var isDone: Bool { state == "done" }
    /// `HH:MM`.
    public var time: String { String(at.suffix(5)) }
    public var day: String { String(at.prefix(10)) }
}

public enum PersonKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case birthday, anniversary, other
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public struct Person: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: PersonKind
    public var month: Int
    public var day: Int
    public var year: Int?
    public var notes: String
    public var source: String
    /// `YYYY-MM-DD`: the next time it falls, today included.
    public var nextDate: String
    public var turns: Int?
    public var createdAt: String
    public var updatedAt: String

    /// "14 Mar 1991" or "14 Mar".
    public var dateText: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let m = (1...12).contains(month) ? months[month - 1] : "?"
        return "\(day) \(m)" + (year.map { " \($0)" } ?? "")
    }
}

public struct TodaySettings: Codable, Equatable, Sendable {
    public var briefingEnabled: Bool
    /// `HH:MM`, Sofia.
    public var briefingTime: String
    /// `auto`, `claude` or `codex`.
    public var assistantModel: String
    public var claudeModel: String
    public var codexModel: String
}

public struct ReadyItem: Codable, Equatable, Hashable, Sendable {
    public var todoId: String
    public var title: String
}

public struct WatchCounts: Codable, Equatable, Sendable {
    public var waiting: Int
    public var working: Int
    public var needsYou: Int
    public var cantFix: Int
    public var fixed: Int
    public var resolving: Int

    public var isEmpty: Bool { waiting + working + needsYou + cantFix + fixed + resolving == 0 }
}

/// The morning briefing, live.
public struct Briefing: Codable, Equatable, Sendable {
    public var reminders: [Reminder]
    public var dates: [String]
    public var people: [Person]
    public var readyForReview: [ReadyItem]
    public var needsYou: Int
    public var watch: WatchCounts

    public var isEmpty: Bool {
        reminders.isEmpty && dates.isEmpty && readyForReview.isEmpty && needsYou == 0 && watch.isEmpty
    }
}

public enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
    case hour, evening, tomorrow
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .hour: "1 hour"
        case .evening: "This evening (18:00)"
        case .tomorrow: "Tomorrow 09:00"
        }
    }

    /// The new time, Sofia wall clock.
    public func until(now: Date = .now) -> String {
        let cal = TodayTime.calendar
        switch self {
        case .hour:
            return TodayTime.wallClock(now.addingTimeInterval(3600))
        case .evening:
            return TodayTime.wallClock(cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now)
        case .tomorrow:
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return TodayTime.wallClock(cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        }
    }

    /// "This evening" only before 18:00.
    public static func available(now: Date = .now) -> [SnoozeOption] {
        TodayTime.calendar.component(.hour, from: now) < 18 ? allCases : [.hour, .tomorrow]
    }
}

public struct ReminderRequestBody: Codable, Equatable, Sendable {
    public var title: String
    public var notes: String
    public var at: String
    public var `repeat`: String
}

/// The reminder form.
public struct ReminderDraft: Equatable, Sendable {
    public var title = ""
    public var notes = ""
    public var date: Date
    public var `repeat` = ReminderRepeat.none

    /// A new reminder starts at the next full hour.
    public init(now: Date = .now) {
        let cal = TodayTime.calendar
        let next = cal.date(byAdding: .hour, value: 1, to: now) ?? now
        date = cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    public init(reminder: Reminder) {
        title = reminder.title
        notes = reminder.notes
        date = TodayTime.date(fromWallClock: reminder.at) ?? .now
        self.repeat = reminder.repeat
    }

    public var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var request: ReminderRequestBody {
        ReminderRequestBody(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes,
                            at: TodayTime.wallClock(date), repeat: self.repeat.rawValue)
    }
}

public struct PersonRequestBody: Codable, Equatable, Sendable {
    public var name: String
    public var kind: String
    public var month: Int
    public var day: Int
    public var year: Int?
    public var notes: String

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(month, forKey: .month)
        try c.encode(day, forKey: .day)
        // null clears the year on an edit.
        try c.encode(year, forKey: .year)
        try c.encode(notes, forKey: .notes)
    }
}

/// The person form.
public struct PersonDraft: Equatable, Sendable {
    public var name = ""
    public var kind = PersonKind.birthday
    public var month = 1
    public var day = 1
    public var hasYear = false
    public var year = 1990
    public var notes = ""

    public init() {}

    public init(person: Person) {
        name = person.name
        kind = person.kind
        month = person.month
        day = person.day
        hasYear = person.year != nil
        year = person.year ?? 1990
        notes = person.notes
    }

    public var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Without a year, checked against a leap year (29 Feb is allowed).
        let comps = DateComponents(year: hasYear ? year : 2024, month: month, day: day)
        guard let date = TodayTime.calendar.date(from: comps) else { return false }
        let back = TodayTime.calendar.dateComponents([.month, .day], from: date)
        return back.month == month && back.day == day
    }

    public var request: PersonRequestBody {
        PersonRequestBody(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind.rawValue,
                          month: month, day: day, year: hasYear ? year : nil, notes: notes)
    }
}

public struct TodaySettingsUpdate: Encodable, Sendable {
    public var briefingEnabled: Bool?
    public var briefingTime: String?
    public var assistantModel: String?

    public init(briefingEnabled: Bool? = nil, briefingTime: String? = nil, assistantModel: String? = nil) {
        self.briefingEnabled = briefingEnabled
        self.briefingTime = briefingTime
        self.assistantModel = assistantModel
    }
}

struct AssistantRequestBody: Encodable {
    var text: String
    var kind: String?
}

struct SnoozeBody: Encodable {
    var until: String
}
