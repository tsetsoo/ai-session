import AISessionCore
import SwiftUI

/// Conversation status as a pill (indicator + label) or a bare dot for dense rows.
struct StatusBadge: View {
    enum Style { case pill, dot }

    private let status: ConversationDisplayStatus
    private let style: Style

    @Environment(\.colorScheme) private var colorScheme

    init(_ status: ConversationDisplayStatus, style: Style = .pill) {
        self.status = status
        self.style = style
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label)
    }

    @ViewBuilder private var content: some View {
        switch (status, style) {
        case (.needsYou, .pill):
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? Color(PlatformNativeColor(hex: 0x1C1C1E)) : .white)
                .padding(.horizontal, DS.spacing.s)
                .padding(.vertical, DS.spacing.xs)
                .background(DS.accent, in: Capsule())
        case (.needsYou, .dot):
            Circle().fill(DS.accent).frame(width: 8, height: 8)
        case (.working, .pill):
            HStack(spacing: DS.spacing.xs + 2) {
                WorkingDots()
                label
            }
        case (.working, .dot):
            WorkingDots()
        case (.idle, .pill):
            HStack(spacing: DS.spacing.xs + 2) {
                idleDot
                label
            }
        case (.idle, .dot):
            idleDot
        case (.closed, .pill):
            label
        case (.closed, .dot):
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
        }
    }

    private var label: some View {
        Text(status.label)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var idleDot: some View {
        Circle()
            .strokeBorder(Color.secondary, lineWidth: 1.5)
            .frame(width: 8, height: 8)
    }
}

/// Three dots pulsing in sequence; static when Reduce Motion is on.
private struct WorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion || pulsing ? 1 : 0.3)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(index) * 0.2),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}
