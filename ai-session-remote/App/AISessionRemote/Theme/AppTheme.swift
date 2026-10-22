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

    /// Asset catalog image for the tool's own app icon.
    static func imageName(for tool: AITool) -> String {
        switch tool {
        case .claude: "ToolClaude"
        case .codex: "ToolCodex"
        case .cursor: "ToolCursor"
        case .shell: "ToolShell"
        }
    }

    /// Claude coral, Codex blue, Cursor silver, Shell gray. Darker in light mode so the name stays readable.
    static func color(for tool: AITool?) -> Color {
        switch tool {
        case .claude:
            PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xB04E38), dark: PlatformNativeColor(hex: 0xE07A5F))
        case .codex:
            PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x3A5FE0), dark: PlatformNativeColor(hex: 0x7AA2FF))
        case .cursor:
            PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x3A3A3C), dark: PlatformNativeColor(hex: 0xD4D4D8))
        case .shell:
            PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x636366), dark: PlatformNativeColor(hex: 0xAEAEB2))
        case nil:
            .secondary
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
}

/// The tool's own app icon. Hidden from VoiceOver; the colored name next to it is the label.
struct ToolIcon: View {
    let tool: String
    var side: CGFloat = 28

    var body: some View {
        if let known = AITool(rawValue: tool) {
            Image(AppTheme.imageName(for: known))
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        }
    }
}
