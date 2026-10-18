import AISessionCore
import SwiftData
import SwiftUI

/// 5-hour, weekly and monthly limits for this chat's tool, read on the
/// computer the chat runs on. A window that login does not have is absent,
/// and a computer with no reading shows nothing.
struct UsageLimitsBar: View {
    let computer: Computer
    let tool: String
    let sessionId: String?

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var limits: UsageLimits?

    var body: some View {
        VStack(spacing: 0) {
            if let windows = limits?.windows, !windows.isEmpty {
                chips(windows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: hasWindows ? nil : 0)
        .task(id: taskID) { await poll() }
    }

    private var hasWindows: Bool {
        !(limits?.windows.isEmpty ?? true)
    }

    /// Reloads when the chat's computer, tool, or saved host changes.
    private var taskID: String {
        let ready = HostLookup.host(for: computer, in: hosts) != nil
        return "\(computer.id)|\(tool)|\(sessionId ?? "")|\(ready)"
    }

    private func chips(_ windows: [UsageLimitWindow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.spacing.m) {
                ForEach(windows) { window in
                    Text("\(window.title) \(window.percentText)")
                        .foregroundStyle(window.isElevated ? DS.accent : Color.secondary)
                        .fontWeight(window.isHigh ? .semibold : .regular)
                        .help(window.accessibilityText)
                        .accessibilityLabel(window.accessibilityText)
                }
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, DS.spacing.l)
            .padding(.vertical, DS.spacing.xs)
            Divider()
        }
        .background(.background)
        .accessibilityElement(children: .contain)
    }

    private func poll() async {
        #if DEBUG
        if DemoFixtures.isEnabled { return }
        #endif
        // A host saved later changes `taskID` and starts a new poll.
        guard HostLookup.host(for: computer, in: hosts) != nil else { return }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func load() async {
        guard HostLookup.host(for: computer, in: hosts) != nil else { return }
        do {
            let config = try HostLookup.config(for: computer, in: hosts)
            let next = try await RemoteLimits.fetch(config: config, tool: tool, sessionId: sessionId)
            guard !Task.isCancelled else { return }
            limits = next
        } catch {
            // Keep the last reading. A dropped SSH call should not blank the strip.
        }
    }
}
