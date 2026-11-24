import AISessionCore
import SwiftUI

/// Shared visual tokens for tool identity and connection status across host/session screens.
enum AppTheme {
    static func displayName(for tool: AITool) -> String {
        switch tool {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .shell: "Shell"
        }
    }

    static func iconName(for tool: AITool?) -> String {
        switch tool {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "pointer.arrow"
        case .antigravity: "sparkle.magnifyingglass"
        case .shell: "terminal"
        case nil: "terminal"
        }
    }

    /// Asset catalog image when the tool has a bundled icon.
    static func imageName(for tool: AITool) -> String? {
        switch tool {
        case .claude: "ToolClaude"
        case .codex: "ToolCodex"
        case .cursor: "ToolCursor"
        case .antigravity: nil
        case .shell: "ToolShell"
        }
    }

    /// Tool colors. Darker in light mode so the name stays readable.
    /// The skins swap in their own neon or phosphor hues.
    static func color(for tool: AITool?) -> Color {
        switch DS.skin {
        case .standard: break
        case .neonNoir:
            switch tool {
            case .claude: return hexColor(0xFF2E97)
            case .codex: return hexColor(0x00F0FF)
            case .antigravity: return hexColor(0xB967FF)
            case .cursor, .shell: return hexColor(0xB9B6E8)
            case nil: return .secondary
            }
        case .phosphor:
            switch tool {
            case .claude: return hexColor(0x7FD99A)
            case .codex: return hexColor(0x8ADCD0)
            case .antigravity: return hexColor(0x6CC4C0)
            case .cursor, .shell: return hexColor(0x8FB89C)
            case nil: return .secondary
            }
        }
        switch tool {
        case .claude:
            return PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xB04E38), dark: PlatformNativeColor(hex: 0xE07A5F))
        case .codex:
            return PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x3A5FE0), dark: PlatformNativeColor(hex: 0x7AA2FF))
        case .cursor:
            return PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x3A3A3C), dark: PlatformNativeColor(hex: 0xD4D4D8))
        case .antigravity:
            return PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x315DAD), dark: PlatformNativeColor(hex: 0x8CB4FF))
        case .shell:
            return PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x636366), dark: PlatformNativeColor(hex: 0xAEAEB2))
        case nil:
            return .secondary
        }
    }

    static func reachabilityColor(_ value: Bool?) -> Color {
        switch value {
        case .some(true): DS.skin == .standard ? Color(red: 0.20, green: 0.72, blue: 0.40) : DS.success
        case .some(false): DS.skin == .standard ? Color(red: 0.90, green: 0.28, blue: 0.28) : DS.error
        case .none: Color.secondary.opacity(0.35)
        }
    }

    private static func hexColor(_ value: UInt32) -> Color { Color(PlatformNativeColor(hex: value)) }

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

/// The tool's own app icon, or a terminal symbol in the same square for a tool the app doesn't
/// know, so rows keep their alignment. Hidden from VoiceOver; the name next to it is the label.
struct ToolIcon: View {
    let tool: String
    var side: CGFloat = 28

    var body: some View {
        let known = AITool(rawValue: tool)
        if let known, let imageName = AppTheme.imageName(for: known) {
            Image(imageName)
                .resizable()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                }
                .accessibilityHidden(true)
        } else {
            Image(systemName: AppTheme.iconName(for: known))
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(AppTheme.color(for: known))
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }
}
