import XCTest
@testable import AISessionCore

final class SessionNameTests: XCTestCase {
    func testTmuxNameFormat() {
        let name = SessionName(tool: .claude, slug: "sigma-revenue")
        XCTAssertEqual(name.tmuxName, "ai/claude/sigma-revenue")
    }

    func testParseValid() {
        let parsed = SessionName.parse("ai/codex/overnight")
        XCTAssertEqual(parsed?.tool, .codex)
        XCTAssertEqual(parsed?.slug, "overnight")
    }

    func testParseRejectsNonAI() {
        XCTAssertNil(SessionName.parse("dev"))
        XCTAssertNil(SessionName.parse("ai/unknown/x"))
    }

    func testMakeUniqueSuffixes() {
        let existing = Set(["ai/claude/app", "ai/claude/app-2"])
        let name = SessionName.makeUnique(tool: .claude, slug: "app", existing: existing)
        XCTAssertEqual(name.tmuxName, "ai/claude/app-3")
    }

    func testDefaultBinaries() {
        XCTAssertEqual(AITool.claude.defaultBinary, "claude")
        XCTAssertEqual(AITool.codex.defaultBinary, "codex")
        XCTAssertEqual(AITool.cursor.defaultBinary, "agent")
    }
}
