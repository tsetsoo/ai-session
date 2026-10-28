import AISessionCore
import SwiftTerm
import UIKit
import XCTest
@testable import AISessionRemote

@MainActor
final class ChatTextTests: XCTestCase {
    func testPasteReplacesSelectionAtTheCaretWithoutChangingSpacing() {
        let view = UITextView()
        view.text = "before REPLACE after"
        view.selectedRange = NSRange(location: 7, length: 7)
        let handle = ChatDraftEditorHandle()
        handle.view = view
        handle.insert("  pasted\n\n    code  \n")
        XCTAssertEqual(view.text, "before   pasted\n\n    code  \n after")
    }

    func testChatSubmissionPreservesFinalBlankLines() async throws {
        let transport = ChatRecordingTransport()
        let config = HostConnectionConfig(host: "example.test", port: 22, username: "me", privateKeyPEM: Data())
        let coordinator = TerminalCoordinator(hostConfig: config, mode: .attach("unused"), makeTransport: { _, _ in transport })
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        coordinator.attach(to: view)
        view.feed(text: "\u{1B}[?2004h")
        await coordinator.connect()
        let text = "  first\n\n    second  \n\n"
        let sent = await coordinator.sendMessage(text)
        XCTAssertTrue(sent)
        XCTAssertEqual(transport.sent.last, Array(("\u{1B}[200~" + text + "\u{1B}[201~\r").utf8))
        coordinator.disconnect()
        let disconnected = await coordinator.sendMessage(text)
        XCTAssertFalse(disconnected)
    }
}

private final class ChatRecordingTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?
    var sent: [[UInt8]] = []
    func connect(cols: Int, rows: Int) async throws {}
    func send(_ bytes: ArraySlice<UInt8>) { sent.append(Array(bytes)) }
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}
}
