import SwiftUI

/// Accent-filled capsule button. The label is dark on the lighter dark-mode accent (like the
/// Needs-you pill) so it keeps its contrast. Neon noir draws it as a glowing cyan outline;
/// Phosphor as a square green block.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    enum Corners: Equatable { case capsule, square }

    /// Standard keeps its capsule exactly; only Phosphor is square.
    static func corners(for skin: AppSkin) -> Corners {
        skin == .phosphor ? .square : .capsule
    }

    func makeBody(configuration: Configuration) -> some View {
        let skin = SkinStore.shared.skin
        let neon = skin == .neonNoir
        let shape = Self.corners(for: skin) == .capsule ? AnyShape(Capsule()) : AnyShape(Rectangle())
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(neon ? DS.info : DS.onAccent)
            .padding(.horizontal, DS.spacing.l - 2)
            .padding(.vertical, DS.spacing.xs + 2)
            .background(neon ? Color.clear : DS.accent, in: shape)
            .overlay(shape.stroke(neon ? DS.info : .clear, lineWidth: 1))
            .shadow(color: neon ? DS.info.opacity(0.6) : (skin == .phosphor ? DS.glow ?? .clear : .clear),
                    radius: skin == .standard ? 0 : (skin == .phosphor ? DS.glowRadius : 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
