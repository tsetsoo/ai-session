import SwiftUI

/// Accent-filled capsule button. The label is dark on the lighter dark-mode accent (like the
/// Needs-you pill) so it keeps its contrast.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(DS.onAccent)
            .padding(.horizontal, DS.spacing.l - 2)
            .padding(.vertical, DS.spacing.xs + 2)
            .background(DS.accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
