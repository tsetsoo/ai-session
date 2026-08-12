/// What `TerminalCoordinator` needs from whatever moves bytes to and from the remote PTY.
///
/// Deliberately free of any SwiftNIO type: `SSHTerminalSession` is the only conformer today,
/// opening its PTY on the shared `SSHConnectionPool`, but a later Mosh transport can conform
/// with no change to `TerminalCoordinator` or `TerminalScreen`.
protocol TerminalTransport: AnyObject {
    /// Invoked off the main thread. Consumers must hop before touching UI.
    var onOutput: (([UInt8]) -> Void)? { get set }
    /// Invoked once when the connection goes away for any reason other than `disconnect()`.
    var onDisconnect: (() -> Void)? { get set }

    func connect(cols: Int, rows: Int) async throws
    func send(_ bytes: ArraySlice<UInt8>)
    func resize(cols: Int, rows: Int)
    func disconnect()
}
