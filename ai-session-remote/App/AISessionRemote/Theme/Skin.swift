import Observation
import SwiftUI

/// The app-wide look: today's Standard, or one of the two dark cyberpunk skins. Chosen per
/// device in Settings → Appearance.
enum AppSkin: String, CaseIterable, Identifiable {
    case standard, neonNoir, phosphor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .neonNoir: "Neon noir"
        case .phosphor: "Phosphor"
        }
    }

    /// The interface font. Every skin keeps the system font for legibility (Phosphor's CRT
    /// feel comes from its colours, square corners and the monospaced terminal).
    var interfaceFontDesign: Font.Design? { nil }

    /// Headings only (sidebar labels, section headers, screen titles): Phosphor gives them a
    /// terminal look in monospace; body text keeps the system font.
    var headingFontDesign: Font.Design? { self == .phosphor ? .monospaced : nil }

    /// Both skins are dark only; Standard follows the system (and the terminal's own theme).
    var isDark: Bool { self != .standard }

    /// Appended to the bundled attention sound names (`attention-review-phosphor.caf`).
    var soundSuffix: String? {
        switch self {
        case .standard: nil
        case .neonNoir: "neon-noir"
        case .phosphor: "phosphor"
        }
    }

    /// The iOS alternate app icon; nil is the primary icon.
    var iconName: String? {
        switch self {
        case .standard: nil
        case .neonNoir: "AppIcon-NeonNoir"
        case .phosphor: "AppIcon-Phosphor"
        }
    }
}

/// Holds the selected skin. `DS` reads `shared.skin`, so any SwiftUI body that reads a token
/// re-renders when it changes, with no root `.id` (which would tear down the terminals).
@Observable
final class SkinStore: @unchecked Sendable {
    static let shared = SkinStore()
    static let defaultsKey = "app.skin"

    @ObservationIgnored private let defaults: UserDefaults

    var skin: AppSkin {
        didSet {
            // Views read the skin while drawing; it changes only from the Settings picker.
            assert(Thread.isMainThread, "set the app skin on the main thread")
            defaults.set(skin.rawValue, forKey: Self.defaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skin = defaults.string(forKey: Self.defaultsKey).flatMap(AppSkin.init(rawValue:)) ?? .standard
    }
}
