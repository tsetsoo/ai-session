import AISessionCore
import SwiftUI

/// In the Mac's conversation toolbar while delegated work runs: how many workers, amber when
/// one waits on you. From the hub's list, so it costs no check on the computer. Click: Workers.
struct WorkersChip: View {
    let tally: WorkerTally
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacing.xs) {
                Image(systemName: tally.needsYou > 0 ? "hand.raised.fill" : "person.2")
                    .foregroundStyle(tally.needsYou > 0 ? WorkerStateLabel.needsYouColor : Color.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(tally.needsYou > 0 ? WorkerStateLabel.needsYouColor : Color.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.spacing.xs)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help("Workers: \(tally.summary)")
        #endif
        .accessibilityLabel("Workers: \(tally.summary)")
        .accessibilityHint("Opens the Workers panel")
    }

    /// "1 needs you", else "2 working".
    private var label: String {
        tally.needsYou > 0 ? "\(tally.needsYou) needs you" : "\(tally.working) working"
    }

    /// Shown only while something runs or waits: finished work is in the panel.
    static func shows(_ tally: WorkerTally) -> Bool { tally.active > 0 }
}
