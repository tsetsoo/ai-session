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
        case .phosphor: hex(0x33FF77)
        }
    }

    /// The light accent in both modes, for fills whose label the system forces white (swipe
    /// actions).
    static var accentSolid: Color {
        switch skin {
        case .standard: Color(PlatformNativeColor(hex: 0xB4532E))
        case .neonNoir: hex(0xC2186F)
        case .phosphor: hex(0x1F7A3D)
        }
    }

    /// A pale accent fill (the quick-add section chip) and the text that keeps 4.5:1 on it.
    static var accentTint: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xF6E6DF), dark: PlatformNativeColor(hex: 0x4A2E23))
        case .neonNoir: hex(0x3A1030)
        case .phosphor: hex(0x0B3D1C)
        }
    }

    static var accentOnTint: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x8E3F22), dark: PlatformNativeColor(hex: 0xF2B49B))
        case .neonNoir: hex(0xFF8CC6)
        case .phosphor: hex(0x7DFFB0)
        }
    }

    /// Text and symbols on an accent fill: white on the light accent, near-black on the lighter
    /// dark-mode accent, so both keep their contrast.
    static var onAccent: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: .white, dark: PlatformNativeColor(hex: 0x1C1C1E))
        case .neonNoir: hex(0x0B0A1A)
        case .phosphor: hex(0x020A04)
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
        case .phosphor: hex(0xFF5F4A)
        }
    }

    /// Worth a look but nothing failed: a partial load, read-only offline.
    static var warning: Color {
        switch skin {
        case .standard: PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x9A5B00), dark: PlatformNativeColor(hex: 0xFFB648))
        case .neonNoir: hex(0xFFB648)
        case .phosphor: hex(0xFFC447)
        }
    }

    // MARK: Status colours that were plain system colours

    static var success: Color { pick(.green, neon: 0x39FF88, phosphor: 0x33FF77) }
    static var info: Color { pick(.blue, neon: 0x00F0FF, phosphor: 0x7DFFB0) }
    /// Needs you, waiting, due.
    static var attention: Color { pick(.orange, neon: 0xFFB648, phosphor: 0xFFC447) }
    static var merged: Color { pick(.purple, neon: 0xB967FF, phosphor: 0x7DFFB0) }
    static var star: Color { pick(.yellow, neon: 0xFFE45C, phosphor: 0xD4FF33) }
    /// Delete, remove, failed actions.
    static var destructive: Color { pick(.red, neon: 0xFF5A4E, phosphor: 0xFF5F4A) }
    static var diffAdded: Color { pick(.green, neon: 0x39FF88, phosphor: 0x33FF77) }
    static var diffRemoved: Color { pick(.red, neon: 0xFF5A4E, phosphor: 0xFF5F4A) }
    static var memory: Color { pick(.indigo, neon: 0xB967FF, phosphor: 0x7DFFB0) }

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
        case .phosphor: hex(0x020A04)
        }
    }

    /// Cards, chips, the sidebar.
    static var surface: Color? {
        switch skin {
        case .standard: nil
        case .neonNoir: hex(0x110F26)
        case .phosphor: hex(0x031207)
        }
    }

    static var selectionFill: Color {
        switch skin {
        case .standard: Color.accentColor.opacity(0.15)
        case .neonNoir: hex(0xFF2E97).opacity(0.15)
        case .phosphor: hex(0x33FF77)
        }
    }

    static var selectionStroke: Color {
        switch skin {
        case .standard: .clear
        case .neonNoir: hex(0xFF2E97)
        case .phosphor: hex(0x33FF77)
        }
    }

    /// A static glow around selected and primary things; Neon noir only.
    static var glow: Color? {
        skin == .neonNoir ? hex(0xFF2E97).opacity(0.6) : nil
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
        case .phosphor: hex(0x33FF77).opacity(0.14)
        }
    }

    static let spacing: (xs: CGFloat, s: CGFloat, m: CGFloat, l: CGFloat, xl: CGFloat) = (4, 8, 12, 16, 24)

    static let rowMinHeight: CGFloat = 52
}
