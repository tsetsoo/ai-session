import SwiftUI

/// Shared layout and colour tokens for the redesigned screens. Only system greys plus one accent.
enum DS {
    static let accent = PlatformColor.dynamic(light: PlatformNativeColor(hex: 0xB4532E), dark: PlatformNativeColor(hex: 0xE8916F))
    /// The light accent in both modes, for fills whose label the system forces white (swipe
    /// actions).
    static let accentSolid = Color(PlatformNativeColor(hex: 0xB4532E))

    static let spacing: (xs: CGFloat, s: CGFloat, m: CGFloat, l: CGFloat, xl: CGFloat) = (4, 8, 12, 16, 24)

    static let rowMinHeight: CGFloat = 52
}
