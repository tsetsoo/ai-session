import AISessionCore
import UserNotifications

/// Local (on-device) attention alerts when a refresh finds sessions marked `waiting`.
/// Real remote push still needs APNs + a host agent; this covers the phone-side half.
enum AttentionNotifier {
    static func notifyWaitingSessions(hostName: String, sessions: [RemoteSession]) {
        let waiting = sessions.filter { $0.status == .waiting }
        guard !waiting.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session needs attention"
        if waiting.count == 1, let only = waiting.first {
            content.body = "\(only.slug) on \(hostName)"
        } else {
            content.body = "\(waiting.count) sessions on \(hostName) are waiting"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "waiting-\(hostName)-\(waiting.map(\.tmuxName).sorted().joined(separator: ","))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
