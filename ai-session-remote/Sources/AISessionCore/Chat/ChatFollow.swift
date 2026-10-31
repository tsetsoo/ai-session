import Foundation

/// Whether the chat keeps the newest text in view. Only the user's own scrolling changes it:
/// content growing below, or the app scrolling, never unpins.
public struct ChatFollow: Equatable, Sendable {
    /// Within this many points of the end counts as at the bottom.
    public static let tolerance: Double = 40

    public private(set) var pinned = true

    public init() {}

    public mutating func userScrolled(distanceFromBottom: Double) {
        pinned = distanceFromBottom < Self.tolerance
    }

    public mutating func jumpToLatest() { pinned = true }

    public var showsJumpButton: Bool { !pinned }
    public var followsNewContent: Bool { pinned }
}
