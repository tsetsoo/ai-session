import SwiftUI

/// Accent-filled capsule button. The label is dark on the lighter dark-mode accent (like the
/// Needs-you pill) so it keeps its contrast. Neon noir draws it as a glowing cyan outline;
/// Phosphor as a square green block.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let neon = SkinStore.shared.skin == .neonNoir
        let shape = RoundedRectangle(cornerRadius: DS.radius(100), style: .continuous)
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(neon ? DS.info : DS.onAccent)
            .padding(.horizontal, DS.spacing.l - 2)
            .padding(.vertical, DS.spacing.xs + 2)
            .background(neon ? Color.clear : DS.accent, in: shape)
            .overlay(shape.strokeBorder(neon ? DS.info : .clear, lineWidth: 1))
            .shadow(color: neon ? DS.info.opacity(0.6) : .clear, radius: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
