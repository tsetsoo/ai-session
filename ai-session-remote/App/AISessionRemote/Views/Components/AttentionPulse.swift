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

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        // Mac only: the phone's lists stay as they were.
        content
        #else
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
        #endif
    }

    private func pulse() {
        run?.cancel()
        run = Task { @MainActor in
            if reduceMotion {
                opacity = 0.3
                // Let the highlight render before fading it, or SwiftUI animates 0 → 0.
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 1.6)) { opacity = 0 }
                return
            }
            // A newer pulse cancels this one: stop without touching `opacity`, which is its now.
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.33)) { opacity = 0.35 }
                try? await Task.sleep(for: .milliseconds(330))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.33)) { opacity = 0 }
                try? await Task.sleep(for: .milliseconds(330))
                if Task.isCancelled { return }
            }
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

    /// From `AppModel` after every refresh, so the badge stays right with no window open.
    @MainActor static func apply(count: Int) {
        apply(Input(count: count, enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true))
    }

    @MainActor static func apply(_ input: Input) {
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = input.enabled && input.count > 0 ? "\(input.count)" : nil
        #endif
    }
}
