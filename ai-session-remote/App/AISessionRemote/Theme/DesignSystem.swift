import SwiftUI

/// Shared layout and colour tokens for the redesigned screens: system greys, one accent, and
/// two status colours for problems (`error`, `warning`).
enum DS {
    /// The same colour as the asset catalog's AccentColor (the app's global accent, which the
    /// system uses for list selection); `DesignSystemTests` keeps the two in step.
    static let accent = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xB4532E), dark: PlatformNativeColor(hex: 0xE8916F))
    /// The light accent in both modes, for fills whose label the system forces white (swipe
    /// actions).
    static let accentSolid = Color(PlatformNativeColor(hex: 0xB4532E))
    /// A pale accent fill (the quick-add section chip) and the text that keeps 4.5:1 on it.
    static let accentTint = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xF6E6DF), dark: PlatformNativeColor(hex: 0x4A2E23))
    static let accentOnTint = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x8E3F22), dark: PlatformNativeColor(hex: 0xF2B49B))
    /// Text and symbols on an accent fill: white on the light accent, near-black on the lighter
    /// dark-mode accent, so both keep their contrast.
    static let onAccent = PlatformColor.dynamic(light: .white, dark: PlatformNativeColor(hex: 0x1C1C1E))

    /// Something failed: inline error lines in forms and lists.
    static let error = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xC4302B), dark: PlatformNativeColor(hex: 0xFF6B60))
    /// Worth a look but nothing failed: a partial load, read-only offline.
    static let warning = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0x9A5B00), dark: PlatformNativeColor(hex: 0xFFB648))

    /// An unchosen `Chip`.
    static let chipFill = Color.secondary.opacity(0.12)

    static let spacing: (xs: CGFloat, s: CGFloat, m: CGFloat, l: CGFloat, xl: CGFloat) = (4, 8, 12, 16, 24)

    static let rowMinHeight: CGFloat = 52
}
