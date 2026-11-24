#if os(iOS)
import ActivityKit
import AISessionCore
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private typealias SessionActivity = Activity<AgentSessionAttributes>
    private var activities: [String: SessionActivity] = [:]
    private var observations: [String: Task<Void, Never>] = [:]
    private var lifetimes: [String: Task<Void, Never>] = [:]
    private var lastStates: [String: AgentSessionAttributes.ContentState] = [:]
    private var awaitingDeparture: [(AgentSessionAttributes, AgentSessionAttributes.ContentState)] = []

    private init() {
        // Remove any copies left by an older app build.
        UserDefaults.standard.removeObject(forKey: "todoHub.apiToken")
        UserDefaults(suiteName: "group.com.aisessionremote")?.removeObject(forKey: "todoHub.apiToken")
        for activity in SessionActivity.activities {
            observe(activity)
        }
    }

    func sync(conversations: [Conversation], todos: [Todo], projects: [Project]) {
        let todoMap = Dictionary(todos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectNames = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        awaitingDeparture = conversations.compactMap { conversation in
            guard let todo = todoMap[conversation.todoId],
                  !conversation.id.isEmpty,
                  conversation.status == .busy || conversation.status == .waiting else { return nil }
            let state = content(for: conversation)
            return (AgentSessionAttributes(
                todoId: todo.id, conversationId: conversation.id, todoTitle: todo.title,
                tool: conversation.tool, model: conversation.model,
                projectName: conversation.projectId.flatMap { projectNames[$0] } ?? ""
            ), state)
        }
        let active = Set(awaitingDeparture.map { $0.0.conversationId })
        for (id, activity) in activities where !active.contains(id) {
            let completed = conversations.contains { $0.id == id && $0.status == .idle }
            finish(activity, completed: completed)
        }
        for (attributes, state) in awaitingDeparture {
            let id = attributes.conversationId
            guard let activity = activities[id], lastStates[id] != state else { continue }
            lastStates[id] = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        }
    }

    /// ActivityKit requires a foreground request. The app calls this immediately before
    /// relinquishing the foreground, using the last successful Hub snapshot.
    func prepareToLeaveForeground() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for (attributes, state) in awaitingDeparture where activities[attributes.conversationId] == nil {
            var attributes = attributes
            attributes.startedAt = .now
            let content = ActivityContent(state: state, staleDate: nil)
            if let activity = (try? SessionActivity.request(attributes: attributes, content: content, pushType: .token))
                ?? (try? SessionActivity.request(attributes: attributes, content: content, pushType: nil)) {
                lastStates[attributes.conversationId] = state
                observe(activity)
            }
        }
    }

    private func content(for conversation: Conversation) -> AgentSessionAttributes.ContentState {
        let waiting = conversation.status == .waiting
        let message = conversation.statusMessage.map { String($0.prefix(250)) }
        let permission = (conversation.tool == "claude"
                          && (message == "Claude needs approval" || message?.hasPrefix("Claude needs approval: ") == true))
            || (conversation.tool == "codex"
                && (message == "Codex needs approval" || message?.hasPrefix("Codex needs your permission to use ") == true))
        return .init(
            status: conversation.status.rawValue, currentStep: message ?? (conversation.status == .busy ? "Working" : nil),
            promptQuestion: waiting ? (message ?? "Waiting for your input") : nil,
            isWaiting: waiting, statusRevision: conversation.statusRevision, canDecide: waiting && permission && conversation.hasPromptIdentity,
            updatedAt: HubDates.date(from: conversation.statusUpdatedAt) ?? .distantPast
        )
    }

    private func observe(_ activity: SessionActivity) {
        let conversationID = activity.attributes.conversationId
        activities[conversationID] = activity
        lastStates[conversationID] = lastStates[conversationID] ?? activity.content.state
        observations[activity.id] = Task {
            if let token = activity.pushToken { await register(activity, token: token) }
            for await token in activity.pushTokenUpdates {
                await register(activity, token: token)
            }
        }
        lifetimes[activity.id] = Task {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    stopObserving(activity)
                    return
                }
            }
        }
    }

    private func register(_ activity: SessionActivity, token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        for delay in [0, 1, 3, 10] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, activity.activityState == .active || activity.activityState == .stale,
                  let client = TodoHubSettings.makeClient() else { return }
            do {
                try await client.registerLiveActivity(id: activity.id, conversationId: activity.attributes.conversationId,
                                                      token: hex, environment: ApsEnvironment.current)
                return
            } catch {
                continue
            }
        }
    }

    private func finish(_ activity: SessionActivity, completed: Bool) {
        stopObserving(activity)
        let state = AgentSessionAttributes.ContentState(
            status: completed ? "idle" : "closed", finishedMessage: completed ? "Turn complete" : "Session closed"
        )
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: completed ? .after(.now.addingTimeInterval(60)) : .immediate)
        }
    }

    private func stopObserving(_ activity: SessionActivity) {
        let conversationID = activity.attributes.conversationId
        if activities[conversationID]?.id == activity.id {
            activities.removeValue(forKey: conversationID)
            lastStates.removeValue(forKey: conversationID)
        }
        observations.removeValue(forKey: activity.id)?.cancel()
        lifetimes.removeValue(forKey: activity.id)?.cancel()
        Task { try? await TodoHubSettings.makeClient()?.unregisterLiveActivity(id: activity.id) }
    }
}
#endif
