import AISessionCore
import SwiftUI

/// Shared visual tokens for tool identity and connection status across host/session screens.
enum AppTheme {
    static func displayName(for tool: AITool) -> String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .shell: "Shell"
        }
    }

    static func iconName(for tool: AITool?) -> String {
        switch tool {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "pointer.arrow"
        case .shell: "terminal"
        case nil: "terminal"
        }
    }

    static func color(for tool: AITool?) -> Color {
        switch tool {
        case .claude: Color(red: 0.86, green: 0.45, blue: 0.22) // warm amber
        case .codex: Color(red: 0.18, green: 0.62, blue: 0.45) // teal
        case .cursor: Color(red: 0.22, green: 0.48, blue: 0.78) // steel blue
        case .shell: Color(red: 0.45, green: 0.45, blue: 0.50) // neutral slate
        case nil: .secondary
        }
    }

    static func reachabilityColor(_ value: Bool?) -> Color {
        switch value {
        case .some(true): Color(red: 0.20, green: 0.72, blue: 0.40)
        case .some(false): Color(red: 0.90, green: 0.28, blue: 0.28)
        case .none: Color.secondary.opacity(0.35)
        }
    }

    static func reachabilityLabel(_ value: Bool?) -> String {
        switch value {
        case .some(true): "Reachable"
        case .some(false): "Unreachable"
        case .none: "Unknown"
        }
    }

    static func relativeTime(from date: Date?, relativeTo now: Date = .now) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func statusLabel(_ status: SessionActivityStatus) -> String {
        switch status {
        case .busy: "Busy"
        case .idle: "Idle"
        case .waiting: "Needs attention"
        case .unknown: "Unknown"
        }
    }

    static func statusColor(_ status: SessionActivityStatus) -> Color {
        switch status {
        case .busy: Color(red: 0.20, green: 0.72, blue: 0.40)
        case .idle: Color.secondary
        case .waiting: Color(red: 0.95, green: 0.55, blue: 0.15)
        case .unknown: Color.secondary.opacity(0.5)
        }
    }
}
