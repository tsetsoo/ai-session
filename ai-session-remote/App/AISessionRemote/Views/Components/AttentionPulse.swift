import SwiftUI
#if os(macOS)
import AppKit
#endif

extension AttentionKind {
    /// Pulse colour: the app's accent for Needs you, the system accent for To review.
    var pulseTint: Color {
        self == .needsYou ? DS.accent : Color.accentColor
    }
}

extension View {
    /// Pulses a tinted background three times (~2 s) whenever `serial` changes, or when the row
    /// appears within `AttentionPulseModifier.freshFor` of the arrival at `at` (a row that just
    /// moved into this list is a new view). Older arrivals never replay on scroll or list switch.
    /// With Reduce Motion, one highlight that fades out instead.
    func attentionPulse(serial: Int?, at: Date?, tint: Color) -> some View {
        modifier(AttentionPulseModifier(serial: serial, at: at, tint: tint))
    }
}

private struct AttentionPulseModifier: ViewModifier {
    static let freshFor: TimeInterval = 3
    let serial: Int?
    let at: Date?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 0
    @State private var run: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(opacity))
                    .allowsHitTesting(false)
            }
            .onChange(of: serial) { old, new in
                guard let new, new != old else { return }
                pulse()
            }
            .onAppear {
                if let at, Date().timeIntervalSince(at) < Self.freshFor { pulse() }
            }
            .onDisappear { run?.cancel() }
    }

    private func pulse() {
        run?.cancel()
        run = Task { @MainActor in
            if reduceMotion {
                opacity = 0.3
                withAnimation(.easeOut(duration: 1.6)) { opacity = 0 }
                return
            }
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.33)) { opacity = 0.35 }
                try? await Task.sleep(for: .milliseconds(330))
                withAnimation(.easeInOut(duration: 0.33)) { opacity = 0 }
                try? await Task.sleep(for: .milliseconds(330))
                if Task.isCancelled { break }
            }
            opacity = 0
        }
    }
}

/// The Mac's Dock icon shows how many conversations need you (Settings can turn it off).
enum DockBadge {
    static let enabledKey = "attention.dockBadge"

    struct Input: Equatable {
        var count: Int
        var enabled: Bool
    }

    @MainActor static func apply(_ input: Input) {
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = input.enabled && input.count > 0 ? "\(input.count)" : nil
        #endif
    }
}
