import Foundation

/// Memories of one kind, in display order.
public struct MemoryGroup: Equatable, Identifiable, Sendable {
    public var kind: MemoryKind
    public var memories: [Memory]

    public var id: MemoryKind { kind }
}

/// How the app orders memories: kinds as in the digest (open threads, decisions, gotchas,
/// done, files changed), and within a list pinned first, then newest.
public enum MemoryGrouping {
    /// One group per kind that has memories, in `MemoryKind.allCases` order.
    public static func grouped(_ memories: [Memory]) -> [MemoryGroup] {
        let byKind = Dictionary(grouping: memories, by: \.kind)
        return MemoryKind.allCases.compactMap { kind in
            guard let items = byKind[kind], !items.isEmpty else { return nil }
            return MemoryGroup(kind: kind, memories: sorted(items))
        }
    }

    /// For the panel next to a conversation: this session's memories first, then the rest of
    /// the project's, each part pinned first, then newest.
    public static func forConversation(_ memories: [Memory], sessionId: String?) -> [Memory] {
        guard let sessionId else { return sorted(memories) }
        let mine = memories.filter { $0.sessionId == sessionId }
        let others = memories.filter { $0.sessionId != sessionId }
        return sorted(mine) + sorted(others)
    }

    /// Pinned first, then newest (`created_at`), then by id so the order is stable.
    public static func sorted(_ memories: [Memory]) -> [Memory] {
        memories
            .map { ($0, $0.createdDate ?? .distantPast) }
            .sorted { lhs, rhs in
                if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .map(\.0)
    }
}

/// Week arithmetic for `GET /api/stats/weekly`, whose weeks run Monday to Sunday.
public enum WeekMath {
    /// The Monday on or before `date` in `calendar`'s time zone, as `YYYY-MM-DD`.
    /// Independent of the calendar's `firstWeekday`.
    public static func monday(of date: Date, calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday … 7 = Saturday
        let back = (weekday + 5) % 7 // Monday → 0, Sunday → 6
        let monday = calendar.date(byAdding: .day, value: -back, to: date) ?? date
        return string(from: monday, calendar: calendar)
    }

    /// `weekStart` moved by whole weeks; `nil` when it isn't a `YYYY-MM-DD` date.
    public static func shift(_ weekStart: String, byWeeks weeks: Int, calendar: Calendar = .current) -> String? {
        addingDays(7 * weeks, to: weekStart, calendar: calendar)
    }

    /// A `YYYY-MM-DD` day moved by whole days (e.g. `+6` for a week's Sunday).
    public static func addingDays(_ days: Int, to day: String, calendar: Calendar = .current) -> String? {
        guard let date = date(from: day, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return string(from: moved, calendar: calendar)
    }

    /// Noon of a `YYYY-MM-DD` day, so DST changes never move it to another day.
    public static func date(from day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func string(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Compact numbers for the stats cards.
public enum StatsFormat {
    /// `1h 30m`, `45m`, `0m`.
    public static func duration(seconds: Int) -> String {
        let minutes = max(seconds, 0) / 60
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// `950`, `51.2k`, `9.1M`; `–` when unknown.
    public static func tokens(_ value: Int?) -> String {
        guard let value else { return "–" }
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(value) / 1_000_000)
        default: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
    }
}
