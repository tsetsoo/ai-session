import AISessionCore
import SwiftUI

/// Poll only while this scene is active; cancellation stops work on backgrounding.
struct StatusMonitoring: ViewModifier {
    let hosts: [HostEntity]
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private struct PollID: Hashable {
        var active: Bool
        var hosts: [UUID]
        var computers: [String]
    }

    func body(content: Content) -> some View {
        content.task(id: PollID(active: scenePhase == .active, hosts: hosts.map(\.id),
                                computers: model.store.computers.map(\.id))) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshStatusMonitoring(hosts: hosts)
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }
}

struct StatusFreshnessLabel: View {
    let conversation: Conversation
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let freshness = model.statusFreshness(for: conversation, at: context.date)
            if let text = RowText.freshness(freshness, now: context.date) {
                Label(text, systemImage: freshness.state == .offline ? "wifi.slash" : "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(text)
            }
        }
    }
}
