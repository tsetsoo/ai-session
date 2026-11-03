import AISessionCore
import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import AISessionRemote

@MainActor
final class TerminalPromptWatchTests: XCTestCase {
    private var transport: PromptRecordingTransport!
    private var coordinator: TerminalCoordinator!
    private var view: TerminalView!

    override func setUp() async throws {
        transport = PromptRecordingTransport()
        let config = HostConnectionConfig(host: "example.test", port: 22, username: "me", privateKeyPEM: Data())
        coordinator = TerminalCoordinator(hostConfig: config, mode: .attach("unused"), makeTransport: { [transport] _, _ in transport! })
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        coordinator.attach(to: view)
        await coordinator.connect()
        view.getTerminal().resize(cols: 100, rows: 40)
    }

    override func tearDown() async throws {
        coordinator.disconnect()
    }

    /// Paints `screen` the way tmux would: clear, home, then each row.
    private func show(_ screen: String) async throws {
        let rows = screen.components(separatedBy: "\n").joined(separator: "\r\n")
        transport.onOutput?(Array(("\u{1B}[2J\u{1B}[H" + rows).utf8))
        try await Task.sleep(for: .milliseconds(400))
    }

    private var down: [UInt8] { TerminalKey.down.bytes(tool: "claude") }
    private var enter: [UInt8] { TerminalKey.enter.bytes(tool: "claude") }

    func testPromptAppearsAfterScreenShowsIt() async throws {
        var seen: [String] = []
        coordinator.onScreenChange = { seen = $0 }
        try await show(TerminalPromptFixtures.claudeBash)
        XCTAssertEqual(TerminalPrompt.parse(screen: seen)?.options.count, 4)
        XCTAssertEqual(coordinator.currentPrompt()?.question, "Do you want to proceed?")
    }

    func testPromptIsFoundWhileTheTerminalIsScrolledBack() async throws {
        let filler = (1...200).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
        transport.onOutput?(Array(filler.utf8))
        let rows = TerminalPromptFixtures.claudeBash.components(separatedBy: "\n").joined(separator: "\r\n")
        transport.onOutput?(Array(rows.utf8))
        try await Task.sleep(for: .milliseconds(400))
        let terminal = view.getTerminal()
        terminal.buffer.yDisp = 0
        XCTAssertEqual(terminal.getLine(row: 0)?.translateToString(trimRight: true), "line 1", "scrolled to the top")
        XCTAssertEqual(coordinator.currentPrompt()?.question, "Do you want to proceed?")
    }

    func testAnswerSendsArrowsAndEnter() async throws {
        try await show(TerminalPromptFixtures.claudeBash)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        XCTAssertTrue(coordinator.answer(prompt, option: 1, tool: "claude"))
        XCTAssertEqual(transport.sent.last, Array("2".utf8))
    }

    func testAnswerRefusesWhenPromptChanged() async throws {
        try await show(TerminalPromptFixtures.claudeBash)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        try await show(TerminalPromptFixtures.claudeEdit)
        let before = transport.sent.count
        XCTAssertFalse(coordinator.answer(prompt, option: 0, tool: "claude"))
        XCTAssertEqual(transport.sent.count, before)
    }

    func testAnswerRefusesWhenPromptIsGone() async throws {
        try await show(TerminalPromptFixtures.claudeBash)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        try await show(TerminalPromptFixtures.claudeIdle)
        let answered = await coordinator.answer(prompt, option: 3, text: "why", tool: "claude")
        XCTAssertFalse(answered)
        XCTAssertFalse(coordinator.answer(prompt, option: 0, tool: "claude"))
    }

    func testTypeSomethingIsTypedInPlace() async throws {
        transport.onOutput?(Array("\u{1B}[?2004h".utf8))
        try await show(TerminalPromptFixtures.claudeQuestion)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        let answered = await coordinator.answer(prompt, option: 3, text: "Purple", tool: "claude")
        XCTAssertTrue(answered)
        XCTAssertEqual(Array(transport.sent.suffix(2)), [down + down + down, Array("\u{1B}[200~Purple\u{1B}[201~\r".utf8)])
    }

    func testTellCodexChoosesTheOptionThenSubmitsOnceTheMenuCloses() async throws {
        transport.onOutput?(Array("\u{1B}[?2004h".utf8))
        try await show(TerminalPromptFixtures.codexCommand)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        async let answered = coordinator.answer(prompt, option: 2, text: "use pnpm", tool: "codex")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.sent.last, Array("3".utf8))
        try await show(TerminalPromptFixtures.codexIdle)
        let result = await answered
        XCTAssertTrue(result)
        XCTAssertEqual(transport.sent.last, Array("\u{1B}[200~use pnpm\u{1B}[201~\r".utf8))
    }

    func testChatMessageIsNotSentWhileAQuestionIsOnScreen() async throws {
        transport.onOutput?(Array("\u{1B}[?2004h".utf8))
        try await show(TerminalPromptFixtures.claudeBash)
        let before = transport.sent.count
        let sent = await coordinator.sendMessage("yes")
        XCTAssertFalse(sent)
        XCTAssertEqual(transport.sent.count, before)
    }

    func testTypedAnswerGivesUpWhenTheMenuStaysOpen() async throws {
        transport.onOutput?(Array("\u{1B}[?2004h".utf8))
        try await show(TerminalPromptFixtures.codexCommand)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        let answered = await coordinator.answer(prompt, option: 2, text: "use pnpm", tool: "codex")
        XCTAssertFalse(answered)
        XCTAssertEqual(transport.sent.last, Array("3".utf8), "no paste after the choice")
    }

    func testLosingTheConnectionClearsTheQuestion() {
        let handle = TerminalHandle()
        handle.screenChanged(TerminalPromptFixtures.claudeBash.components(separatedBy: "\n"))
        XCTAssertNotNil(handle.prompt)
        XCTAssertFalse(handle.screenTail.isEmpty)
        handle.connectionChanged(to: .failed)
        XCTAssertNil(handle.prompt)
        XCTAssertTrue(handle.screenTail.isEmpty)
    }

    func testFallbackKeepsTheWholeScreenIncludingLongApprovalOptions() {
        let lines = (1...30).map { "Approval warning line \($0)" } + [
            "Do you want to proceed?", "❯ 1. Yes", "  2. Always allow", "  3. No",
        ]
        let handle = TerminalHandle()
        handle.screenChanged(lines)
        XCTAssertEqual(handle.screenTail, lines)
        handle.screenChanged(lines.map { $0.replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  3.", with: "❯ 3.") })
        XCTAssertEqual(handle.screenTail.last, "❯ 3. No")
    }

    func testLongFallbackCanScrollVerticallyAndHorizontally() async throws {
        let lines = (1...30).map { "Warning \($0): " + String(repeating: "long command ", count: 12) } + [
            "Do you want to proceed?", "❯ 1. Yes", "  2. Always allow", "  3. No",
        ]
        let handle = TerminalHandle()
        handle.screenChanged(lines)
        let host = UIHostingController(rootView: FallbackPromptTestView(terminal: handle))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 260))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()

        func scrollViews(in view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 100,
                             "The options must remain below the warning in scrollable content, never truncated")
        XCTAssertGreaterThan(scroll.contentOffset.y, 0, "The highlighted option should be revealed on first display")
        XCTAssertLessThanOrEqual(scroll.contentOffset.x, 8, "Scrolling may consume the padding, but must keep each option's start visible")

        // Inspecting the warning is allowed; the next menu repaint must reveal its new cursor.
        scroll.setContentOffset(.zero, animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let moved = lines.map { $0.replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "❯ 2.") }
        handle.screenChanged(moved)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        // Flush the hosting view's rendering before inspecting the updated scroll position.
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let updatedScroll = try XCTUnwrap(scrollViews(in: host.view).first)
        XCTAssertGreaterThan(updatedScroll.contentOffset.y, 0, "Arrow navigation should reveal the newly highlighted option")
        let attachment = XCTAttachment(image: image)
        attachment.name = "Long approval prompt in a compact card"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct FallbackPromptTestView: View {
    let terminal: TerminalHandle

    var body: some View {
        ChatScreenFallbackCard(lines: terminal.screenTail, onKey: { _ in }, onOpenTerminal: {})
    }
}

private final class PromptRecordingTransport: TerminalTransport {
    var onOutput: (([UInt8]) -> Void)?
    var onDisconnect: ((Int?) -> Void)?
    var sent: [[UInt8]] = []
    func connect(cols: Int, rows: Int) async throws {}
    func send(_ bytes: ArraySlice<UInt8>) { sent.append(Array(bytes)) }
    func resize(cols: Int, rows: Int) {}
    func disconnect() {}
}
