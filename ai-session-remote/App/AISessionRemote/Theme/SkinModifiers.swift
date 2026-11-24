import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Applies the app skin at a scene root: accent, forced dark for the skins, the interface
/// font, and the skin's window background behind lists.
///
/// Every modifier is always applied, with a neutral value for Standard. An `if` here would
/// change the root's identity on a switch and tear down the terminals underneath.
private struct SkinnedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let skin = SkinStore.shared.skin
        content
            .tint(DS.accent)
            .fontDesign(skin.interfaceFontDesign)
            .scrollContentBackground(DS.windowBackground == nil ? .automatic : .hidden)
            .background(DS.windowBackground ?? .clear)
            .preferredColorScheme(skin.isDark ? .dark : nil)
            #if os(iOS)
            // UIKit's navigation and tab bars keep the tint they had: push the new one to the
            // windows so toolbar buttons don't stay in the old skin's colour after a switch.
            .onChange(of: skin) {
                let tint = UIColor(DS.accent)
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows { window.tintColor = tint }
                }
            }
            #endif
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
        case .phosphor: Color(PlatformNativeColor(hex: 0x2A4A36))
        }
        content
            // The glow is on the border line only: a shadow on the terminal itself would make
            // every frame render offscreen.
            .overlay(
                Rectangle().strokeBorder(border, lineWidth: 1)
                    .shadow(color: skin == .neonNoir ? (DS.glow ?? .clear) : .clear, radius: 8)
                    .allowsHitTesting(false)
            )
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

    /// The terminal's edge: a glowing magenta line, or Phosphor's green line. Nothing is drawn
    /// over the text itself.
    func skinnedTerminalFrame() -> some View {
        modifier(SkinnedTerminalFrame())
    }
}

private struct SkinnedList: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(DS.windowBackground == nil ? .automatic : .hidden)
            // On iPhone the navigation and tab containers paint an opaque system background
            // over the root's, so each list paints the skin's own. Standard: clear, unchanged.
            .background(DS.windowBackground ?? .clear)
    }
}

extension View {
    /// Every `List` and `Form`: the skin's window background behind it. No change in Standard.
    func skinnedList() -> some View {
        modifier(SkinnedList())
    }
}

extension View {
    /// A list row's card in the skin's surface colour. nil (Standard) keeps the system's.
    func skinnedRow() -> some View {
        listRowBackground(DS.surface)
    }
}
