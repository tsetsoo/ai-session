#if os(iOS)
import ActivityKit
import AppIntents
import Foundation
import AISessionCore

struct ApprovePromptIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Respond to Permission Prompt"
    static var isDiscoverable: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Conversation ID") var conversationId: String
    @Parameter(title: "Status Revision") var statusRevision: Int
    @Parameter(title: "Reject") var reject: Bool

    init() {}

    init(conversationId: String, statusRevision: Int, reject: Bool) {
        self.conversationId = conversationId
        self.statusRevision = statusRevision
        self.reject = reject
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LIVE_ACTIVITY_WIDGET
        guard let client = TodoHubSettings.makeClient(),
              Activity<AgentSessionAttributes>.activities.contains(where: {
                  $0.attributes.conversationId == conversationId &&
                  $0.content.state.statusRevision == statusRevision &&
                  $0.content.state.canDecide == true
              }) else { throw DecisionUnavailable() }

        try await client.decidePermission(id: conversationId, statusRevision: statusRevision, reject: reject)
        #endif
        return .result()
    }

    private struct DecisionUnavailable: LocalizedError {
        var errorDescription: String? { "This permission prompt is no longer available." }
    }
}
#endif
