/// How a terminal session the app didn't close ended, from the PTY command's exit status.
/// A status means the computer ended the command; none means the connection went.
public enum TerminalEnding: Equatable, Sendable {
    /// No exit status: the network or the computer dropped the connection.
    case connectionLost
    /// The command exited cleanly: the tool was quit, tmux closed the session, or the view was
    /// detached from tmux (the tool then keeps running).
    case finished
    /// The command exited with a failure that `OpenFailure` doesn't name.
    case stopped(Int)

    public init(exitStatus: Int?) {
        switch exitStatus {
        case nil: self = .connectionLost
        case 0?: self = .finished
        case let status?: self = .stopped(status)
        }
    }
}
