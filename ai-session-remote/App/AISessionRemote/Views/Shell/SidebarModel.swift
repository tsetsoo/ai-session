import AISessionCore
import Foundation

/// The numbers next to the Mac sidebar's rows. Zero shows no number.
struct SidebarCounts: Equatable {
    struct SectionRow: Equatable {
        let section: TodoSection
        let openTodos: Int
        /// A conversation in this section needs you: the accent dot.
        let needsYou: Bool
    }

    struct ComputerRow: Equatable {
        let id: String
        let name: String
        /// Open conversations on it, whatever their status.
        let open: Int
    }

    let needsYou: Int
    let review: Int
    let working: Int
    let sections: [SectionRow]
    let computers: [ComputerRow]

    init(board: ConversationBoard, computers: [Computer]) {
        needsYou = board.needsYou.count
        review = board.review.count
        working = board.working.count
        sections = TodoSection.allCases.map {
            SectionRow(section: $0, openTodos: board.openTodoCount($0), needsYou: board.sectionNeedsYou($0))
        }
        self.computers = computers.map {
            ComputerRow(id: $0.id, name: $0.name, open: board.openCount(computerID: $0.id))
        }
    }

    /// The trailing number, or nil for zero.
    static func label(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }
}

/// The sync line at the bottom of the Mac sidebar.
struct SyncLine: Equatable {
    enum Kind: Equatable {
        case synced, syncing, offline, tokenRejected, notConfigured
    }

    let kind: Kind
    let text: String

    var systemImage: String {
        switch kind {
        case .synced: "checkmark"
        case .syncing: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        case .tokenRejected: "exclamationmark.triangle"
        case .notConfigured: "server.rack"
        }
    }

    /// - Parameter lastSync: when the todos on screen were last fetched (`store.cachedAt`).
    static func make(isConfigured: Bool, hasLoadedOnce: Bool, isOffline: Bool, tokenRejected: Bool,
                     lastSync: Date?, now: Date) -> SyncLine {
        guard isConfigured else { return SyncLine(kind: .notConfigured, text: "Not connected to a todo server") }
        if tokenRejected {
            return SyncLine(kind: .tokenRejected, text: "The server didn't accept the API token")
        }
        if isOffline {
            guard let lastSync else { return SyncLine(kind: .offline, text: "Offline · showing saved todos") }
            return SyncLine(kind: .offline, text: "Offline · showing todos from \(ago(lastSync, now: now))")
        }
        guard hasLoadedOnce else { return SyncLine(kind: .syncing, text: "Syncing…") }
        guard let lastSync else { return SyncLine(kind: .synced, text: "Synced") }
        return SyncLine(kind: .synced, text: "Synced · \(ago(lastSync, now: now))")
    }

    /// "just now", "5m ago", "2h ago", "3d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(date), 0) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 60 * 24 { return "\(minutes / 60)h ago" }
        return "\(minutes / (60 * 24))d ago"
    }
}

/// Title and secondary line above the Mac list column.
enum ContentHeader {
    static func title(for item: AppModel.SidebarItem, computers: [Computer]) -> String {
        switch item {
        case .needsYou: "Needs you"
        case .review: "Ready for review"
        case .working: "Working"
        case let .section(section): section.rawValue
        case .projects: "Projects"
        case let .computer(id): computers.first { $0.id == id }?.name ?? "Computer"
        }
    }

    /// "5 conversations", "12 open · mac-studio", "1 needs you · 3 working".
    static func subtitle(for item: AppModel.SidebarItem, board: ConversationBoard,
                         sectionComputer: (TodoSection) -> String?) -> String {
        switch item {
        case .needsYou:
            return conversations(board.needsYou.count)
        case .review:
            return conversations(board.review.count)
        case .working:
            return conversations(board.working.count)
        case let .section(section):
            let open = "\(board.openTodoCount(section)) open"
            return sectionComputer(section).map { "\(open) · \($0)" } ?? open
        case .projects:
            return ""
        case let .computer(id):
            return RowText.computerLine(working: board.workingCount(computerID: id),
                                        review: board.reviewCount(computerID: id),
                                        needsYou: board.needsYouCount(computerID: id))
        }
    }

    private static func conversations(_ count: Int) -> String {
        count == 1 ? "1 conversation" : "\(count) conversations"
    }
}
