import Foundation

/// Saved user/assistant text, without terminal line wrapping or padding. Keep text verbatim
/// so copying a message preserves blank lines, indentation and trailing spaces.
public struct ConversationMessage: Decodable, Identifiable, Equatable, Sendable {
    public enum Role: String, Decodable, Sendable {
        case user, assistant
    }

    public let id: String
    public let role: Role
    public let text: String

    public init(id: String, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
