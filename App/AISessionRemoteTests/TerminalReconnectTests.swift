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
    func testHitTargetPutsTheCardInFrontOfTheGrid() {
        XCTAssertEqual(TerminalHitTarget.resolve(isFrontmost: true, isDisconnected: true), .cover)
        XCTAssertEqual(TerminalHitTarget.resolve(isFrontmost: true, isDisconnected: false), .grid)
        XCTAssertEqual(TerminalHitTarget.resolve(isFrontmost: false, isDisconnected: false), .passThrough)
        XCTAssertEqual(TerminalHitTarget.resolve(isFrontmost: false, isDisconnected: true), .passThrough)
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

    /// The close is queued and has not run. `reconnect()` bumps the generation before its
    /// first await, so that close must not fail the session it then opens.
    func testCloseQueuedBeforeReconnectDoesNotFailTheNewSession() async {
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
        made[0].closePane(exitStatus: 1)
        XCTAssertEqual(ended, [])

        await coordinator.reconnect()
        await Self.nextMainTurn()
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertEqual(ended, [])
    }

    #if os(macOS)
    func testReconnectCardIsTheViewInFrontOfTheGrid() {
        let terminal = TerminalView(frame: .zero)
        let gate = TerminalClickGate(terminalView: terminal)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        gate.frame = parent.bounds
        parent.addSubview(gate)

        gate.apply(.grid)
        parent.layoutSubtreeIfNeeded()
        let gridHit = gate.hitTest(NSPoint(x: 40, y: 40))
        XCTAssertTrue(gridHit === terminal || gridHit?.isDescendant(of: terminal) == true)

        let card = NSView()
        gate.apply(.cover, cover: card)
        parent.layoutSubtreeIfNeeded()
        XCTAssertIdentical(gate.subviews.last, card)
        let cardHit = gate.hitTest(NSPoint(x: 40, y: 40))
        XCTAssertTrue(cardHit === card || cardHit?.isDescendant(of: card) == true)

        gate.apply(.passThrough)
        XCTAssertNil(gate.hitTest(NSPoint(x: 40, y: 40)))
    }
    #endif

    private static func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
