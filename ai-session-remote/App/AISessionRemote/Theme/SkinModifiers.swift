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
