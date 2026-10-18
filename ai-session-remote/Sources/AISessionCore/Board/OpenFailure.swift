/// Why opening a conversation over SSH failed, from the helper script's exit status.
public enum OpenFailure: Equatable, Sendable {
    case helpersMissing, toolMissing, folderMissing, conversationNotFound

    public init?(exitStatus: Int?) {
        switch exitStatus {
        case 127: self = .helpersMissing
        case 90: self = .toolMissing
        case 93: self = .folderMissing
        case 94: self = .conversationNotFound
        default: return nil
        }
    }
}
