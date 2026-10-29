import AppKit
import AISessionCore
import SwiftTerm
import XCTest
@testable import AI_Session_Remote

@MainActor
final class TerminalSelectionTests: XCTestCase {
    private func copied(_ text: String, columns: Int = 12) -> String {
        let view = LocalClipboardTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let terminal = view.getTerminal()
        terminal.resize(cols: columns, rows: 24)
        view.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: terminal.buffer.x, row: terminal.buffer.y))
        let clipboard = NSPasteboard(name: NSPasteboard.Name("ai-command-copy-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        view.copySelection(to: clipboard)
        return clipboard.string(forType: .string) ?? ""
    }

    func testCommandSpaceAtSoftWrapBoundarySurvivesCopy() {
        // Column 12 is a real space separating two arguments, not terminal padding.
        let command = "printf '%s' hello"
        XCTAssertEqual(copied(command), command)
    }

    func testQuotedSpacesAndWrappedLongArgumentsSurviveCopy() {
        for command in ["printf '%s' 'hello  world'", "echo abcdefghijklmnopqrstuvwxyz", "echo '界🙂 café'"] {
            XCTAssertEqual(copied(command), command)
        }
    }

    func testHardNewlinesBackslashContinuationsAndBlankLinesSurviveCopy() {
        let command = "printf '%s\\n' \\\n  'hello  world'\n\ncat <<'END'\n  keep this  \n\nEND"
        XCTAssertEqual(copied(command, columns: 40), command)
    }

    func testCopyThenBracketedPastePreservesBangCommandExactly() {
        let command = "!printf '%s' 'hello  world'"
        XCTAssertEqual(TerminalPaste.bytes(for: copied(command), bracketed: true),
                       TerminalPaste.start + Array(command.utf8) + TerminalPaste.end)
    }

    func testClaudeRenderedCommandCopiesSavedSourceWithNoLayoutNewlines() throws {
        let view = LocalClipboardTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let command = "printf '%s' 'hello  world'"
        view.clipboardCode = CommandClipboard.candidates(in: ["```sh\n\(command)\n```"])
        view.feed(text: "  printf '%s'\r\n    'hello  world'")
        let terminal = view.getTerminal()
        view.selection.setSelection(start: Position(col: 2, row: 0),
                                    end: Position(col: terminal.buffer.x, row: terminal.buffer.y))
        XCTAssertNotEqual(view.getSelection(), command, "reproduce Claude's layout newlines and padding")
        let clipboard = NSPasteboard(name: NSPasteboard.Name("ai-claude-command-\(UUID())"))
        defer { clipboard.releaseGlobally() }
        view.copySelection(to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), command)
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", try XCTUnwrap(clipboard.string(forType: .string))]
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "hello  world")
    }

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
