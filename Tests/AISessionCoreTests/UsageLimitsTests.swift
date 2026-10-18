import XCTest
@testable import AISessionCore

final class UsageLimitsTests: XCTestCase {
    func testParseKeepsApplicableWindowsAndDropsUnknownKinds() throws {
        let json = """
        {"tool":"claude","windows":[
          {"kind":"5h","used_percent":25,"resets_at":"2026-10-18T15:00:00Z"},
          {"kind":"weekly","used_percent":40.6},
          {"kind":"weekly","used_percent":90,"scope":"opus","resets_at":null},
          {"kind":"nope","used_percent":1},
          {"kind":"monthly","used_percent":12.2,"scope":"on-demand"}
        ]}
        """
        let limits = try UsageLimits.parse(json)
        XCTAssertEqual(limits.tool, "claude")
        XCTAssertEqual(limits.windows.map(\.kind), ["5h", "weekly", "weekly", "monthly"])
        XCTAssertEqual(limits.windows.map(\.title), ["5h", "week", "opus week", "on-demand"])
        XCTAssertEqual(limits.windows.map(\.percentText), ["25%", "41%", "90%", "12%"])
        XCTAssertEqual(limits.windows.map(\.scope), [nil, nil, "opus", "on-demand"])
        XCTAssertNotNil(limits.windows[0].resetsAt)
        XCTAssertNil(limits.windows[1].resetsAt)
        XCTAssertFalse(limits.windows[0].isElevated)
        XCTAssertTrue(limits.windows[2].isElevated)
        XCTAssertTrue(limits.windows[2].isHigh)
        XCTAssertTrue(limits.windows[0].accessibilityText.hasPrefix("5 hour limit, 25 percent used, resets "))
        XCTAssertEqual(limits.windows[2].accessibilityText, "weekly opus limit, 90 percent used")
    }

    func testParseRejectsABodyThatIsNotLimits() {
        XCTAssertThrowsError(try UsageLimits.parse("[]"))
    }

    func testUsageLimitsCommandQuotesToolAndSession() {
        let command = TmuxCommandBuilder.usageLimits(tool: "cursor", sessionId: "abc-def")
        XCTAssertTrue(command.hasPrefix("export PATH="))
        XCTAssertTrue(command.contains("\"$HOME/.ai-remote/bin/ai-todo-limits\""))
        XCTAssertTrue(command.contains("--tool 'cursor'"))
        XCTAssertTrue(command.contains("--session 'abc-def'"))

        let noSession = TmuxCommandBuilder.usageLimits(tool: "claude", sessionId: nil)
        XCTAssertTrue(noSession.contains("--tool 'claude'"))
        XCTAssertFalse(noSession.contains("--session"))

        let empty = TmuxCommandBuilder.usageLimits(tool: "codex", sessionId: "")
        XCTAssertFalse(empty.contains("--session"))
    }
}
