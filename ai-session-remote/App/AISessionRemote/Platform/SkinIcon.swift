import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The app icon that goes with the skin. iOS switches its alternate icon (the system shows its
/// own "You have changed the icon" alert). The Mac only changes the Dock icon while the app
/// runs: writing an icon into the signed bundle would break its signature and the keychain
/// would ask for the SSH keys and hub token again.
@MainActor
enum SkinIcon {
    /// The Mac Dock image for a skin (`Assets.xcassets/DockIcon-<Skin>`); nil is the bundle icon.
    nonisolated static func dockIconName(for skin: AppSkin) -> String? {
        switch skin {
        case .standard: nil
        case .neonNoir: "DockIcon-NeonNoir"
        case .phosphor: "DockIcon-Phosphor"
        }
    }

    static func apply(_ skin: AppSkin) {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != skin.iconName else { return }
        app.setAlternateIconName(skin.iconName) { error in
            if let error { print("SkinIcon: couldn't set the icon: \(error.localizedDescription)") }
        }
        #else
        // nil restores the bundle icon. The Dock badge is on `dockTile` and isn't touched.
        NSApp.applicationIconImage = dockIconName(for: skin).flatMap { NSImage(named: $0) }
        #endif
    }
}
