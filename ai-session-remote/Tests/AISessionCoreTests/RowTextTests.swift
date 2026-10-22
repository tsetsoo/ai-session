import XCTest
@testable import AISessionCore

final class RowTextTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "mac-studio", hostname: "mac", username: "me")
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T09:00:00Z")!

    private func conv(tool: String = "claude", status: ConversationStatus = .busy, message: String? = nil,
                      updated: String? = nil, created: String = "2026-10-17T08:00:00Z") -> Conversation {
        Conversation(todoId: "t", computer: mac, cwd: "~/x", tool: tool, tmuxName: "t", sessionId: "s",
                     status: status, statusMessage: message, statusUpdatedAt: updated, createdAt: created)
    }

    func testComputerLine() {
        XCTAssertEqual(RowText.computerLine(working: 3, review: 2, needsYou: 1), "1 needs you · 2 to review · 3 working")
        XCTAssertEqual(RowText.computerLine(working: 2, review: 0, needsYou: 0), "2 working")
        XCTAssertEqual(RowText.computerLine(working: 0, review: 4, needsYou: 0), "4 to review")
        XCTAssertEqual(RowText.computerLine(working: 0, review: 0, needsYou: 0), "No open conversations")
    }

    func testMetaKeepsSectionAndComputerAndLeavesTheToolOff() {
        XCTAssertEqual(RowText.conversationMeta(conv(), section: .sp), "Sp · mac-studio")
        XCTAssertEqual(RowText.conversationMeta(conv(tool: "codex"), section: .si), "Si · mac-studio")
        XCTAssertEqual(RowText.conversationMeta(conv(), section: nil), "mac-studio")
    }

    func testFrameSubtitleKeepsTheFolderAndLeavesTheToolOff() {
        XCTAssertEqual(RowText.frameSubtitle(section: .sp, computer: "mac-studio", folder: "~/ai-session"),
                       "Sp · mac-studio · ~/ai-session")
        XCTAssertEqual(RowText.frameSubtitle(section: .i, computer: "pi", folder: nil), "I · pi")
    }

    func testSearchTextStillNamesTheTool() {
        XCTAssertTrue(RowText.conversationSearchText(conv(tool: "codex"), section: .si)
            .localizedStandardContains("Codex"))
        XCTAssertTrue(RowText.conversationSearchText(conv(), section: nil)
            .localizedStandardContains("Claude"))
        XCTAssertEqual(RowText.toolName("shell"), "Shell")
        XCTAssertTrue(RowText.conversationSearchText(conv(tool: "shell"), section: .p)
            .localizedStandardContains("Shell"))
    }

    func testAgePrefersStatusUpdate() {
        XCTAssertEqual(RowText.age(of: conv(updated: "2026-10-17T08:58:00Z"), now: now), "2m")
        XCTAssertEqual(RowText.age(of: conv(updated: "2026-10-17T08:59:30Z"), now: now), "now")
        XCTAssertEqual(RowText.age(of: conv(updated: "2026-10-17T07:00:00.250Z"), now: now), "1h")
        XCTAssertEqual(RowText.age(of: conv(), now: now), "1h")
        XCTAssertEqual(RowText.age(of: conv(created: "2026-10-14T09:00:00Z"), now: now), "3d")
        XCTAssertNil(RowText.age(of: conv(created: ""), now: now))
    }

    func testConversationMessage() {
        let waiting = conv(status: .waiting, message: "Needs your permission to use Bash")
        XCTAssertEqual(RowText.conversationMessage(waiting, status: .needsYou, now: now), "Needs your permission to use Bash")
        XCTAssertEqual(RowText.conversationMessage(conv(status: .waiting, message: " "), status: .needsYou, now: now),
                       "Waiting for you")
        XCTAssertEqual(RowText.conversationMessage(conv(updated: "2026-10-17T08:56:00Z"), status: .working, now: now),
                       "Working for 4m")
        XCTAssertEqual(RowText.conversationMessage(conv(updated: "2026-10-17T08:59:40Z"), status: .working, now: now),
                       "Working")
        XCTAssertEqual(RowText.conversationMessage(conv(), status: .working, now: now), "Working")
        XCTAssertEqual(RowText.conversationMessage(conv(status: .idle), status: .idle, now: now), "Ready for review")
        XCTAssertEqual(RowText.conversationMessage(conv(status: .idle, updated: "2026-10-17T08:46:00Z"), status: .idle,
                                                   now: now), "Finished 14m ago")
        XCTAssertEqual(RowText.conversationMessage(conv(status: .idle, updated: "2026-10-17T08:59:30Z"), status: .idle,
                                                   now: now), "Finished just now")
    }

    func testTodoSubtitle() {
        XCTAssertNil(RowText.todoSubtitle(nil, status: nil, now: now))
        let waiting = conv(status: .waiting, message: "Claude needs your permission to use Edit")
        XCTAssertEqual(RowText.todoSubtitle(waiting, status: .needsYou, now: now), "Claude needs your permission to use Edit")
        XCTAssertEqual(RowText.todoSubtitle(conv(status: .waiting), status: .needsYou, now: now), "mac-studio · 1h")
        XCTAssertEqual(RowText.todoSubtitle(conv(updated: "2026-10-17T08:59:00Z"), status: .working, now: now),
                       "mac-studio · 1m")
        XCTAssertEqual(RowText.todoSubtitle(conv(created: ""), status: .idle, now: now), "mac-studio")
    }
}
