import AISessionCore
import SwiftTerm
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum TerminalTheme: String, CaseIterable {
    case system, light, dark
}

struct TerminalPalette: Equatable {
    let background: PlatformNativeColor
    let foreground: PlatformNativeColor
    let cursor: PlatformNativeColor
    let selection: PlatformNativeColor
    /// The 16 ANSI colours: 8 normal, then 8 bright.
    let ansi: [PlatformNativeColor]

    private static func hexes(_ values: [UInt32]) -> [PlatformNativeColor] {
        values.map { PlatformNativeColor(hex: $0) }
    }

    static let light = TerminalPalette(
        background: PlatformNativeColor(hex: 0xFBFAF7),
        foreground: PlatformNativeColor(hex: 0x1F1E1C),
        cursor: PlatformNativeColor(hex: 0xB4532E),
        selection: PlatformNativeColor(hex: 0xB4532E).withAlphaComponent(0.25),
        ansi: hexes([
            0x1F1E1C, 0xB3261E, 0x2E7D32, 0x8A6100, 0x1F5FBF, 0x8E3B9E, 0x0F7580, 0x9A9890,
            0x5C5B57, 0xD32F2F, 0x388E3C, 0xA66F00, 0x2F6FDB, 0xA64DB8, 0x12909E, 0x6B6A66,
        ])
    )

    static let dark = TerminalPalette(
        background: PlatformNativeColor(hex: 0x1A1A19),
        foreground: PlatformNativeColor(hex: 0xE9E7E2),
        cursor: PlatformNativeColor(hex: 0xE8916F),
        selection: PlatformNativeColor(hex: 0xE8916F).withAlphaComponent(0.30),
        ansi: hexes([
            0x3A3A38, 0xF2766B, 0x7FCB83, 0xE5B95C, 0x6FA8F0, 0xC792EA, 0x5CC8D6, 0xC8C6C0,
            0x6B6A66, 0xFF9C92, 0xA3E0A6, 0xF2D084, 0x9CC5F7, 0xDDB4F2, 0x8EDDE8, 0xF5F3EE,
        ])
    )

    /// Neon noir: indigo black, lavender text, magenta cursor, neon ANSI colours.
    static let neonNoir = TerminalPalette(
        background: PlatformNativeColor(hex: 0x07061A),
        foreground: PlatformNativeColor(hex: 0xD9D6FF),
        cursor: PlatformNativeColor(hex: 0xFF2E97),
        selection: PlatformNativeColor(hex: 0xFF2E97).withAlphaComponent(0.30),
        ansi: hexes([
            0x1A1838, 0xFF5A6E, 0x39FF88, 0xFFE45C, 0x5C8CFF, 0xFF2E97, 0x00F0FF, 0xC8C4F0,
            0x8784B4, 0xFF8C9A, 0x8CFFB8, 0xFFF08C, 0x8CB0FF, 0xFF7AC0, 0x7AF7FF, 0xF2F0FF,
        ])
    )

    /// Phosphor: a green CRT that's easy on the eyes. Vivid green text that stops short of neon,
    /// on a dark green-grey rather than pure black (pure black under neon makes text glow and
    /// shimmer); coral, amber, teal and lime stay distinct so errors, warnings and diffs read.
    static let phosphor = TerminalPalette(
        background: PlatformNativeColor(hex: 0x0A1610),
        foreground: PlatformNativeColor(hex: 0x7FF0A4),
        cursor: PlatformNativeColor(hex: 0x6CEB98),
        selection: PlatformNativeColor(hex: 0x5CE892).withAlphaComponent(0.25),
        ansi: hexes([
            0x1A2E22, 0xF07A66, 0x5CE892, 0xF0C46A, 0x4FCFC8, 0xC2EA6E, 0x7FE6D6, 0xC0EED0,
            0x6A9E7E, 0xF79A88, 0x8CF2B2, 0xF6D68C, 0x7ADCD6, 0xD6F290, 0xA6F0E4, 0xE6F8EC,
        ])
    )

    /// Whether tmux should be told the terminal is dark (background luminance below half).
    var isDark: Bool {
        let bg = Self.rgb(background)
        let luminance = (0.2126 * Double(bg.r) + 0.7152 * Double(bg.g) + 0.0722 * Double(bg.b)) / 255
        return luminance < 0.5
    }

    var contrastPalette: TerminalContrastGuard.Palette {
        TerminalContrastGuard.Palette(
            foreground: Self.rgb(foreground),
            background: Self.rgb(background),
            ansi: ansi.map(Self.rgb)
        )
    }

    private static func rgb(_ color: PlatformNativeColor) -> TerminalContrastGuard.RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(r), channel(g), channel(b))
    }
}

enum TerminalAppearance {
    static let fontSizeRange: ClosedRange<Double> = 9...24

    static var defaultFontSize: Double {
        #if os(macOS)
        13
        #else
        11
        #endif
    }

    static func clamped(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func stepped(_ size: Double, by delta: Int) -> Double {
        clamped(size + Double(delta))
    }

    static func palette(theme: TerminalTheme, colorScheme: ColorScheme) -> TerminalPalette {
        palette(theme: theme, colorScheme: colorScheme, skin: .standard)
    }

    /// A skin brings its own palette; Standard uses the terminal's own theme setting.
    static func palette(theme: TerminalTheme, colorScheme: ColorScheme, skin: AppSkin) -> TerminalPalette {
        switch skin {
        case .neonNoir: return .neonNoir
        case .phosphor: return .phosphor
        case .standard: break
        }
        return switch theme {
        case .light: .light
        case .dark: .dark
        case .system: colorScheme == .dark ? .dark : .light
        }
    }

    /// Representables call this on every update; it only touches the view when the palette or
    /// the font size changed since the last call for that view (`installColors` repaints).
    static func apply(to view: TerminalView, palette: TerminalPalette, fontSize: Double) {
        let applied = Applied(palette: palette, fontSize: clamped(fontSize))
        if objc_getAssociatedObject(view, &appliedKey) as? Applied == applied { return }
        objc_setAssociatedObject(view, &appliedKey, applied, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.installColors(palette.ansi.map(swiftTermColor))
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.caretColor = palette.cursor
        view.selectedTextBackgroundColor = palette.selection
        let font = PlatformNativeFont.monospacedSystemFont(ofSize: CGFloat(clamped(fontSize)), weight: .regular)
        if view.font.pointSize != font.pointSize {
            view.font = font
        }
        #if os(iOS)
        // SwiftTerm's setup clears `nativeBackgroundColor` onto the layer then
        // sets the property to `.clear`. Re-paint both so unused glyph gaps and
        // safe-area bleed match the terminal chrome (no mismatched bars).
        view.layer.backgroundColor = palette.background.cgColor
        view.backgroundColor = palette.background
        #endif
    }

    /// What `apply` last set on a view, kept on the view itself.
    private final class Applied: NSObject {
        let palette: TerminalPalette
        let fontSize: Double

        init(palette: TerminalPalette, fontSize: Double) {
            self.palette = palette
            self.fontSize = fontSize
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Applied else { return false }
            return palette == other.palette && fontSize == other.fontSize
        }
    }

    private static var appliedKey: UInt8 = 0

    private static func swiftTermColor(_ color: PlatformNativeColor) -> SwiftTerm.Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func channel(_ value: CGFloat) -> UInt16 { UInt16((value * 65535).rounded()) }
        return SwiftTerm.Color(red: channel(r), green: channel(g), blue: channel(b))
    }
}

#if os(iOS)
private typealias PlatformNativeFont = UIFont
#else
private typealias PlatformNativeFont = NSFont
#endif
