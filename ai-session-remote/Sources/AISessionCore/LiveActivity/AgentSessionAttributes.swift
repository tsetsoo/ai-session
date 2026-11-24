#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

/// Shared ActivityKit attributes for tracking an active agent task on Lock Screen and Dynamic Island.
public struct AgentSessionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: String // "busy", "waiting", "idle"
        public var currentStep: String?
        public var promptQuestion: String?
        public var isWaiting: Bool
        public var statusRevision: Int?
        public var canDecide: Bool?
        public var finishedMessage: String?
        public var updatedAt: Date

        public init(
            status: String,
            currentStep: String? = nil,
            promptQuestion: String? = nil,
            isWaiting: Bool = false,
            statusRevision: Int? = nil,
            canDecide: Bool? = nil,
            finishedMessage: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.status = status
            self.currentStep = currentStep
            self.promptQuestion = promptQuestion
            self.isWaiting = isWaiting
            self.statusRevision = statusRevision
            self.canDecide = canDecide
            self.finishedMessage = finishedMessage
            self.updatedAt = updatedAt
        }
    }

    public var todoId: String
    public var conversationId: String
    public var todoTitle: String
    public var tool: String
    public var model: String?
    public var projectName: String
    public var startedAt: Date

    public var conversationURL: URL? {
        var components = URLComponents()
        components.scheme = "aisessionremote"
        components.host = "conversation"
        components.queryItems = [URLQueryItem(name: "id", value: conversationId)]
        return components.url
    }

    public init(
        todoId: String,
        conversationId: String,
        todoTitle: String,
        tool: String,
        model: String? = nil,
        projectName: String,
        startedAt: Date = Date()
    ) {
        self.todoId = todoId
        self.conversationId = conversationId
        self.todoTitle = todoTitle
        self.tool = tool
        self.model = model
        self.projectName = projectName
        self.startedAt = startedAt
    }
}
#endif
