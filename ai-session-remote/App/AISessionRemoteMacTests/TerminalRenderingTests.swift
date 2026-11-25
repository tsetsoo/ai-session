import AppKit
import AISessionCore
import SwiftTerm
import XCTest
@testable import AI_Session_Remote

@MainActor
final class TerminalRenderingTests: XCTestCase {
    func testQueuedOutputIsDrainedAtTheOldWidthBeforeShowing() async {
        let view = LocalClipboardTerminalView(frame: .zero)
        let gate = TerminalClickGate(terminalView: view)
        gate.frame.size = NSSize(width: 320, height: 200)
        let transport = RenderingTransport()
        let coordinator = TerminalCoordinator(
            hostConfig: HostConnectionConfig(host: "test", port: 22, username: "test", privateKeyPEM: Data()),
            mode: .plainShell, makeTransport: { _, _ in transport }
        )
        coordinator.attach(to: view)
        await coordinator.connect()
        defer { coordinator.disconnect() }
        let columns = view.terminalDimensions.cols
        coordinator.setShown(false)
        gate.apply(.passThrough)
        // This enqueues a drain, but it cannot run until this main-actor turn yields.
        transport.onOutput?(Array((String(repeating: "x", count: columns) + "Y").utf8))
        gate.frame.size = NSSize(width: 900, height: 400)
        gate.beforeGridResize = {
            coordinator.flushHeldOutput()
            XCTAssertEqual(view.terminalStateSnapshot().cursor.row, 1)
            XCTAssertEqual(view.terminalStateSnapshot().cursor.col, 1)
        }
        gate.apply(.grid)
        coordinator.setShown(true)
        let cursor = view.terminalStateSnapshot().cursor.col
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(view.terminalStateSnapshot().cursor.col, cursor, "scheduled drain must not replay bytes")
    }

    func testHiddenGridParsesHeldOutputBeforeResizing() {
        let view = LocalClipboardTerminalView(frame: .zero)
        let gate = TerminalClickGate(terminalView: view)
        gate.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        gate.apply(.grid)
        let columns = view.terminalDimensions.cols
        gate.apply(.passThrough)

        gate.frame.size = NSSize(width: 900, height: 400)
        gate.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.terminalDimensions.cols, columns)
        XCTAssertEqual(view.frame.size, NSSize(width: 320, height: 200))

        var flushed = 0
        gate.beforeGridResize = {
            flushed += 1
            XCTAssertEqual(view.terminalDimensions.cols, columns)
            // A full row followed by the next character wraps only at the original width.
            view.feed(text: String(repeating: "x", count: columns) + "Y")
            XCTAssertEqual(view.terminalStateSnapshot().cursor.row, 1)
            XCTAssertEqual(view.terminalStateSnapshot().cursor.col, 1)
        }
        gate.apply(.grid)
        XCTAssertEqual(flushed, 1)
        XCTAssertEqual(view.frame, gate.bounds)
        XCTAssertGreaterThan(view.terminalDimensions.cols, columns)
        gate.layoutSubtreeIfNeeded()
        XCTAssertEqual(flushed, 1, "unchanged layout must not replay held output")
    }

    func testVisibleGridFollowsHostSize() {
        let view = LocalClipboardTerminalView(frame: .zero)
        let gate = TerminalClickGate(terminalView: view)
        gate.apply(.grid)
        gate.frame.size = NSSize(width: 640, height: 320)
        XCTAssertEqual(view.frame, gate.bounds)
        gate.frame.size = NSSize(width: 800, height: 480)
        XCTAssertEqual(view.frame, gate.bounds)
    }
}

private final class RenderingTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?
    func connect(cols: Int, rows: Int) async throws {}
    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}
}
