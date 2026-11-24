import SwiftUI

/// Shared layout and colour tokens for the redesigned screens: system greys, one accent, and
/// status colours. Each token follows the app skin (`SkinStore`); the `.standard` branch is the
/// app's original look and must stay exactly as it was. The skins are dark only.
enum DS {
    static var skin: AppSkin { SkinStore.shared.skin }

    private static func hex(_ value: UInt32) -> Color { Color(PlatformNativeColor(hex: value)) }

    /// The same colour as the asset catalog's AccentColor (the app's global accent, which the
    /// system uses for list selection); `DesignSystemTests` keeps the two in step for Standard.
    static var accent: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xB4532E), dark: PlatformNativeColor(hex: 0xE8916F))
        case .neonNoir: hex(0xFF2E97)
        case .phosphor: hex(0x5CE892)
        }
    }

    /// The light accent in both modes, for fills whose label the system forces white (swipe
    /// actions).
    static var accentSolid: Color {
        switch skin {
        case .standard: Color(PlatformNativeColor(hex: 0xB4532E))
        case .neonNoir: hex(0xC2186F)
        case .phosphor: hex(0x237A48)
        }
    }

    /// A pale accent fill (the quick-add section chip) and the text that keeps 4.5:1 on it.
    static var accentTint: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xF6E6DF), dark: PlatformNativeColor(hex: 0x4A2E23))
        case .neonNoir: hex(0x3A1030)
        case .phosphor: hex(0x143A24)
        }
    }

    static var accentOnTint: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x8E3F22), dark: PlatformNativeColor(hex: 0xF2B49B))
        case .neonNoir: hex(0xFF8CC6)
        case .phosphor: hex(0x9CF0BA)
        }
    }

    /// Text and symbols on an accent fill: white on the light accent, near-black on the lighter
    /// dark-mode accent, so both keep their contrast.
    static var onAccent: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: .white, dark: PlatformNativeColor(hex: 0x1C1C1E))
        case .neonNoir: hex(0x0B0A1A)
        case .phosphor: hex(0x08130D)
        }
    }

    /// Text on `accentSolid` (your own chat bubbles). Standard keeps `onAccent`; the skins'
    /// darker solid accents take white, which keeps 4.5:1.
    static var onAccentSolid: Color {
        skin == .standard ? onAccent : .white
    }

    /// Something failed: inline error lines in forms and lists.
    static var error: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xC4302B), dark: PlatformNativeColor(hex: 0xFF6B60))
        case .neonNoir: hex(0xFF5A4E)
        case .phosphor: hex(0xF07A66)
        }
    }

    /// Worth a look but nothing failed: a partial load, read-only offline.
    static var warning: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x9A5B00), dark: PlatformNativeColor(hex: 0xFFB648))
        case .neonNoir: hex(0xFFB648)
        case .phosphor: hex(0xF0C46A)
        }
    }

    // MARK: Status colours that were plain system colours

    static var success: Color { pick(.green, neon: 0x39FF88, phosphor: 0x5CE892) }
    static var info: Color { pick(.blue, neon: 0x00F0FF, phosphor: 0x6FE0D0) }
    /// Needs you, waiting, due.
    static var attention: Color { pick(.orange, neon: 0xFFB648, phosphor: 0xF0C46A) }
    static var merged: Color { pick(.purple, neon: 0xB967FF, phosphor: 0x6FE0D0) }
    static var star: Color { pick(.yellow, neon: 0xFFE45C, phosphor: 0xD6F290) }
    /// Delete, remove, failed actions.
    static var destructive: Color { pick(.red, neon: 0xFF5A4E, phosphor: 0xF07A66) }
    static var diffAdded: Color { pick(.green, neon: 0x39FF88, phosphor: 0x5CE892) }
    static var diffRemoved: Color { pick(.red, neon: 0xFF5A4E, phosphor: 0xF07A66) }
    static var memory: Color { pick(.indigo, neon: 0xB967FF, phosphor: 0x6FE0D0) }

    private static func pick(_ standard: Color, neon: UInt32, phosphor: UInt32) -> Color {
        switch skin {
        case .standard: standard
        case .neonNoir: hex(neon)
        case .phosphor: hex(phosphor)
        }
    }

    // MARK: Surfaces and styling (nil / identity for Standard: keep the system look)

    /// Behind windows, lists and sidebars; nil keeps the system background.
    static var windowBackground: Color? {
        switch skin {
        case .standard: nil
        case .neonNoir: hex(0x0B0A1A)
        case .phosphor: hex(0x0A1610)
        }
    }

    /// Cards, chips, the sidebar.
    static var surface: Color? {
        switch skin {
        case .standard: nil
        case .neonNoir: hex(0x110F26)
        case .phosphor: hex(0x11231A)
        }
    }

    static var selectionFill: Color {
        switch skin {
        case .standard: Color.accentColor.opacity(0.15)
        case .neonNoir: hex(0xFF2E97).opacity(0.15)
        case .phosphor: hex(0x5CE892)
        }
    }

    static var selectionStroke: Color {
        switch skin {
        case .standard: .clear
        case .neonNoir: hex(0xFF2E97)
        case .phosphor: hex(0x5CE892)
        }
    }

    /// A static glow around the terminal's edge and primary buttons: magenta in Neon noir,
    /// a faint phosphor-green halo in Phosphor. Never on text. The Mac's large terminal pane
    /// sits beside the sidebar, where the iPhone's strength read as a heavy edge, so the Mac's
    /// is very slight.
    static var glow: Color? {
        switch skin {
        case .standard: nil
        case .neonNoir: hex(0xFF2E97).opacity(0.6)
        case .phosphor:
            #if os(macOS)
            hex(0x5CE892).opacity(0.15)
            #else
            hex(0x5CE892).opacity(0.3)
            #endif
        }
    }

    /// How dark Phosphor's CRT vignette gets at the terminal's corners: 35 % on the iPhone,
    /// a very slight 15 % on the Mac's large pane.
    static var vignetteStrength: Double {
        guard skin == .phosphor else { return 0 }
        #if os(macOS)
        return 0.15
        #else
        return 0.35
        #endif
    }

    /// How far from the centre (0…1 of the way to the edge) the vignette stays fully clear: the
    /// Mac darkens only its very edge.
    static var vignetteClearUntil: Double {
        #if os(macOS)
        0.88
        #else
        0.8
        #endif
    }

    /// How far the glow spreads: Neon noir blooms, Phosphor is a faint halo.
    static var glowRadius: CGFloat {
        guard skin == .phosphor else { return 8 }
        #if os(macOS)
        return 3
        #else
        return 4
        #endif
    }

    /// A list row's background in a skin: the surface, or the accent tint when the row is the
    /// selected one (a painted row background hides the system's selection highlight).
    /// nil in Standard: the system draws both.
    static func rowBackground(selected: Bool) -> Color? {
        guard let surface else { return nil }
        return selected ? accent.opacity(0.24) : surface
    }

    /// The tool-colour bar down a conversation's left edge. Phosphor's bright green read as a
    /// glowing strip, so there it is thinner and dimmer.
    static var toolEdge: (width: CGFloat, opacity: Double) {
        skin == .phosphor ? (1, 0.35) : (4, 1)
    }

    /// Corner radius for a base value: Phosphor is square.
    static func radius(_ base: CGFloat) -> CGFloat {
        skin == .phosphor ? 0 : base
    }

    /// Subtle fill for grouped content.
    static var chipFill: Color {
        switch skin {
        case .standard: Color.secondary.opacity(0.12)
        case .neonNoir: hex(0x00F0FF).opacity(0.12)
        case .phosphor: hex(0x5CE892).opacity(0.14)
        }
    }

    static let spacing: (xs: CGFloat, s: CGFloat, m: CGFloat, l: CGFloat, xl: CGFloat) = (4, 8, 12, 16, 24)

    static let rowMinHeight: CGFloat = 52
}
