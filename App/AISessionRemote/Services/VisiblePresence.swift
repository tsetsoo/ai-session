import Foundation
import SwiftUI

/// Which conversation is on screen, for `NotificationCenterCoordinator.setVisibleConversation`.
///
/// The coordinator keeps a single slot, but frames come and go out of order: when one frame
/// replaces another (a path replaced on iPhone, a new selection on the Mac, a second window),
/// SwiftUI may call the new frame's `onAppear` before the old frame's `onDisappear`. So each
/// frame registers under its own token; the most recently shown frame still on screen wins,
/// and only when none is left does the coordinator hear `nil`.
@MainActor
final class VisiblePresence {
    static let shared = VisiblePresence { NotificationCenterCoordinator.shared.setVisibleConversation(todoId: $0) }

    /// Frames on screen, oldest first.
    private var frames: [(token: UUID, todoID: String)] = []
    private var lastReported: String??
    private let report: (String?) -> Void

    init(report: @escaping (String?) -> Void) {
        self.report = report
    }

    /// The conversation the coordinator was last told about.
    var visibleTodoID: String? { frames.last?.todoID }

    /// A frame came on screen (or changed conversation): it becomes the visible one.
    func appear(_ token: UUID, todoID: String) {
        frames.removeAll { $0.token == token }
        frames.append((token, todoID))
        publish()
    }

    /// A frame left the screen; the previous one still showing becomes visible again.
    func disappear(_ token: UUID) {
        frames.removeAll { $0.token == token }
        publish()
    }

    private func publish() {
        let current = visibleTodoID
        guard lastReported != .some(current) else { return }
        lastReported = .some(current)
        report(current)
    }
}

extension View {
    /// Reports this frame's conversation as on screen while it is shown and `isActive`.
    func reportsVisibleConversation(_ todoID: String, isActive: Bool = true,
                                    presence: VisiblePresence = .shared) -> some View {
        modifier(VisiblePresenceReporter(todoID: todoID, isActive: isActive, presence: presence))
    }
}

private struct VisiblePresenceReporter: ViewModifier {
    let todoID: String
    let isActive: Bool
    let presence: VisiblePresence
    @State private var token = UUID()
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                update()
            }
            .onDisappear {
                isOnScreen = false
                presence.disappear(token)
            }
            .onChange(of: isActive) { _, _ in update() }
            .onChange(of: todoID) { _, _ in update() }
    }

    private func update() {
        if isOnScreen && isActive {
            presence.appear(token, todoID: todoID)
        } else {
            presence.disappear(token)
        }
    }
}
