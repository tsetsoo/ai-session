import AISessionCore
import SwiftData
import SwiftUI

/// 5-hour, weekly and monthly limits for this chat's tool, read on the
/// computer the chat runs on. A window that login does not have is absent,
/// and a computer without the script shows nothing. A failed read with no
/// earlier numbers says the limits are unavailable.
struct UsageLimitsBar: View {
    let computer: Computer
    let tool: String
    let sessionId: String?
    /// Off for a conversation that is mounted but not the one on screen. Included in `taskID`,
    /// so turning it off cancels an in-flight loop and turning it on starts a load.
    let polls: Bool

    init(computer: Computer, tool: String, sessionId: String?, polls: Bool = true) {
        self.computer = computer
        self.tool = tool
        self.sessionId = sessionId
        self.polls = polls
    }

    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var limits: UsageLimits?
    @State private var unavailable = false

    var body: some View {
        VStack(spacing: 0) {
            if let windows = limits?.windows, !windows.isEmpty {
                chips(windows)
            } else if limits == nil, unavailable {
                strip {
                    Text("Limits unavailable")
                        .foregroundStyle(.secondary)
                        .help("Couldn't read this tool's usage limits on \(computer.name).")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: shows ? nil : 0)
        .task(id: taskID) {
            guard polls else { return }
            await poll()
        }
    }

    private var shows: Bool {
        !(limits?.windows.isEmpty ?? true) || (limits == nil && unavailable)
    }

    /// Reloads when the chat's computer, tool, saved host, or polling gate changes.
    private var taskID: String {
        let ready = HostLookup.host(for: computer, in: hosts) != nil
        return "\(computer.id)|\(tool)|\(sessionId ?? "")|\(ready)|\(polls)"
    }

    private func chips(_ windows: [UsageLimitWindow]) -> some View {
        strip {
            ForEach(windows) { window in
                Text("\(window.title) \(window.percentText)")
                    .foregroundStyle(window.isElevated ? DS.accent : Color.secondary)
                    .fontWeight(window.isHigh ? .semibold : .regular)
                    .help(window.accessibilityText)
                    .accessibilityLabel(window.accessibilityText)
            }
        }
    }

    private func strip(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.spacing.m) {
                content()
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
            unavailable = false
        } catch {
            // Keep the last reading. A dropped SSH call should not blank the strip.
            guard !Task.isCancelled else { return }
            unavailable = true
        }
    }
}
