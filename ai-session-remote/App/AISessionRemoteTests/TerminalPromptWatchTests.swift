import AISessionCore
import SwiftTerm
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

    func testAnswerSendsArrowsAndEnter() async throws {
        try await show(TerminalPromptFixtures.claudeBash)
        let prompt = try XCTUnwrap(coordinator.currentPrompt())
        XCTAssertTrue(coordinator.answer(prompt, option: 1, tool: "claude"))
        XCTAssertEqual(transport.sent.last, down + enter)
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
        let codexDown = TerminalKey.down.bytes(tool: "codex")
        async let answered = coordinator.answer(prompt, option: 2, text: "use pnpm", tool: "codex")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.sent.last, codexDown + codexDown + TerminalKey.enter.bytes(tool: "codex"))
        try await show(TerminalPromptFixtures.codexIdle)
        let result = await answered
        XCTAssertTrue(result)
        XCTAssertEqual(transport.sent.last, Array("\u{1B}[200~use pnpm\u{1B}[201~\r".utf8))
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
