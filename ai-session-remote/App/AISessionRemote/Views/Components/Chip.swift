import SwiftUI

/// A capsule choice, such as a section or a project: pale accent when chosen, grey otherwise.
struct Chip<Content: View>: View {
    let isSelected: Bool
    /// Shares the row's width with its neighbours (a fixed set, like the four sections).
    var fillsWidth = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, DS.spacing.m)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 34)
                .foregroundStyle(isSelected ? DS.accentOnTint : Color.primary)
                .background(isSelected ? DS.accentTint : DS.chipFill, in: Capsule())
                .overlay {
                    if isSelected { Capsule().strokeBorder(DS.accent.opacity(0.5), lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        // Borderless: in a form or list row a plain button would take the whole row's taps.
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
