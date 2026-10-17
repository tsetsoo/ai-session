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
        switch theme {
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
