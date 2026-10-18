public enum SessionActivityStatus: String, Codable, Sendable, Equatable {
    case busy
    case idle
    case waiting
    case unknown
}
