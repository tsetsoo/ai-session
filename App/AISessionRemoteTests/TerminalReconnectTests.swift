import AISessionCore
import SwiftTerm
import XCTest
@testable import AISessionRemote

/// A terminal that connects instantly and can report a close later, the way a Cursor pane
/// exits after the SSH channel is already up.
private final class ClosingTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?

    func connect(cols: Int, rows: Int) async throws {}
    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}

    func closePane(exitStatus: Int?) {
        onDisconnect?(exitStatus)
    }
}

@MainActor
final class TerminalReconnectTests: XCTestCase {
    func testCoveredGridDoesNotTakeTheClick() {
        XCTAssertFalse(TerminalPointerPolicy.acceptsPointer(isFrontmost: true, isDisconnected: true))
        XCTAssertFalse(TerminalPointerPolicy.acceptsPointer(isFrontmost: false, isDisconnected: false))
        XCTAssertFalse(TerminalPointerPolicy.acceptsPointer(isFrontmost: false, isDisconnected: true))
        XCTAssertTrue(TerminalPointerPolicy.acceptsPointer(isFrontmost: true, isDisconnected: false))
    }

    func testReconnectIgnoresThePaneThatAlreadyExited() async {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        var made: [ClosingTransport] = []
        let coordinator = TerminalCoordinator(
            hostConfig: HostConnectionConfig(host: "mac", port: 22, username: "me", privateKeyPEM: Data()),
            mode: .plainShell
        ) { _, _ in
            let transport = ClosingTransport()
            made.append(transport)
            return transport
        }
        coordinator.attach(to: view)
        var ended: [Int?] = []
        coordinator.onDisconnected = { ended.append($0) }

        await coordinator.connect()
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(made.count, 1)

        made[0].closePane(exitStatus: 1)
        await Self.nextMainTurn()
        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertEqual(ended, [1])

        await coordinator.reconnect()
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(coordinator.state, .connected)

        // The exited pane's close can still arrive after Reconnect has opened a new session.
        made[0].closePane(exitStatus: 1)
        await Self.nextMainTurn()
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(ended, [1])
    }

    #if os(macOS)
    func testClickGateMissesWhenTheCardIsShowing() {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let gate = TerminalClickGate(terminalView: terminal)
        gate.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        gate.layoutSubtreeIfNeeded()
        gate.acceptsPointer = true
        XCTAssertNotNil(gate.hitTest(NSPoint(x: 10, y: 10)))
        gate.acceptsPointer = false
        XCTAssertNil(gate.hitTest(NSPoint(x: 10, y: 10)))
    }
    #endif

    private static func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
