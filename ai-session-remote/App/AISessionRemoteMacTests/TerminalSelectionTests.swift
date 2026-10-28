import AppKit
import SwiftTerm
import XCTest
@testable import AI_Session_Remote

@MainActor
final class TerminalSelectionTests: XCTestCase {
    func testDragSelectsLocallyWhileRemoteMouseModeIsOnAndOutputContinues() throws {
        let view = LocalClipboardTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.feed(text: "copy this text\r\n\u{1B}[?1000h\u{1B}[?1002h")
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off)
        XCTAssertTrue(view.allowMouseReporting)
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: view.bounds.height - 8),
                                             modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 2))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 10))
        view.mouseDragged(with: try event(.leftMouseDragged, x: 90))
        view.mouseUp(with: try event(.leftMouseUp, x: 90))
        XCTAssertTrue(view.selectionActive)
        let selection = try XCTUnwrap(view.getSelection())
        XCTAssertFalse(selection.isEmpty)
        view.feedPreservingSelection(Array("more output\r\n".utf8)[...])
        XCTAssertTrue(view.selectionActive)
        XCTAssertEqual(view.getSelection(), selection)
        let clipboard = NSPasteboard(name: NSPasteboard.Name("ai-session-selection-test-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        view.copySelection(to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), selection)
        XCTAssertTrue(view.allowMouseReporting, "wheel scrolling must keep remote reporting")
        window.contentView = nil
    }
}
