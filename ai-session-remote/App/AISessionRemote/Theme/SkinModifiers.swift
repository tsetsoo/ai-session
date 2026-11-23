import SwiftUI

/// Applies the app skin at a scene root: accent, forced dark for the skins, Phosphor's
/// monospace, and the skin's window background behind lists.
///
/// Every modifier is always applied, with a neutral value for Standard. An `if` here would
/// change the root's identity on a switch and tear down the terminals underneath.
private struct SkinnedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let skin = SkinStore.shared.skin
        content
            .tint(DS.accent)
            .fontDesign(skin == .phosphor ? .monospaced : nil)
            .scrollContentBackground(DS.windowBackground == nil ? .automatic : .hidden)
            .background(DS.windowBackground ?? .clear)
            .preferredColorScheme(skin.isDark ? .dark : nil)
    }
}

extension View {
    /// Put on the root of every window, sheet root that doesn't inherit the shell, and Settings.
    func skinned() -> some View {
        modifier(SkinnedRoot())
    }
}

// MARK: Shared skin styles
//
// Same rule as the root: the modifiers are always there, and Standard gets neutral values
// (clear strokes, no shadow, zero opacity), so switching never changes a view's identity.

private struct SkinnedSelection: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        let skin = SkinStore.shared.skin
        let on = isSelected && skin != .standard
        let shape = RoundedRectangle(cornerRadius: DS.radius(6), style: .continuous)
        // Only Phosphor's inverted row sets a foreground; a row has no terminal under it, so
        // the branch is safe here (and Standard keeps its own foreground styles untouched).
        Group {
            if on && skin == .phosphor {
                content.foregroundStyle(DS.onAccent)
            } else {
                content
            }
        }
        .background(on ? DS.selectionFill : .clear, in: shape)
        .overlay(
            shape.strokeBorder(on && skin == .neonNoir ? DS.selectionStroke : .clear, lineWidth: 1)
                .shadow(color: on ? (DS.glow ?? .clear) : .clear, radius: 6)
                .allowsHitTesting(false)
        )
    }
}

private struct SkinnedCard: ViewModifier {
    func body(content: Content) -> some View {
        let skinned = SkinStore.shared.skin != .standard
        let shape = RoundedRectangle(cornerRadius: DS.radius(10), style: .continuous)
        content
            .background(DS.surface ?? .clear, in: shape)
            .overlay(shape.strokeBorder(skinned ? DS.accent.opacity(0.45) : .clear, lineWidth: 1))
    }
}

private struct SkinnedTerminalFrame: ViewModifier {
    func body(content: Content) -> some View {
        let skin = SkinStore.shared.skin
        let border: Color = switch skin {
        case .standard: .clear
        case .neonNoir: DS.accent
        case .phosphor: Color(PlatformNativeColor(hex: 0x1F7A3D))
        }
        content
            .overlay {
                ScanlineOverlay().opacity(skin == .phosphor ? 1 : 0)
            }
            // The glow is on the border line only: a shadow on the terminal itself would make
            // every frame render offscreen.
            .overlay(
                Rectangle().strokeBorder(border, lineWidth: 1)
                    .shadow(color: skin == .neonNoir ? (DS.glow ?? .clear) : .clear, radius: 8)
                    .allowsHitTesting(false)
            )
    }
}

/// Phosphor's CRT scanlines over the terminal: thin dark lines, static, never in the way of a
/// touch or a click, invisible to VoiceOver.
struct ScanlineOverlay: View {
    static let lineSpacing: CGFloat = 3
    static let lineOpacity: Double = 0.25

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += Self.lineSpacing
            }
            context.fill(path, with: .color(.black.opacity(Self.lineOpacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A selected row in a skin: Neon noir's magenta outline and glow, Phosphor's inverted row.
    /// No change in Standard (the system draws its own selection).
    func skinnedSelection(_ isSelected: Bool) -> some View {
        modifier(SkinnedSelection(isSelected: isSelected))
    }

    /// Cards, chat bubbles and code blocks: the skin's surface and a thin accent border.
    func skinnedCard() -> some View {
        modifier(SkinnedCard())
    }

    /// The terminal's edge: a glowing magenta line, or Phosphor's green line and scanlines.
    func skinnedTerminalFrame() -> some View {
        modifier(SkinnedTerminalFrame())
    }
}
