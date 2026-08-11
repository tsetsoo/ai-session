import XCTest
@testable import AISessionCore

final class TmuxListParserTests: XCTestCase {
    func testParseSplitsAIAndOther() {
        let output = """
        ai/claude/sigma-revenue: 1 windows (created …)
        ai/codex/overnight: 1 windows (created …)
        random: 1 windows (created …)
        """
        let result = TmuxListParser.parse(listSessionsOutput: output)
        XCTAssertEqual(result.ai.map(\.tmuxName), ["ai/claude/sigma-revenue", "ai/codex/overnight"])
        XCTAssertEqual(result.other.map(\.tmuxName), ["random"])
        XCTAssertTrue(result.ai.allSatisfy(\.isAIManaged))
        XCTAssertTrue(result.other.allSatisfy { !$0.isAIManaged })
    }

    func testParseFormatNamesOnly() {
        let output = "ai/claude/sigma-revenue\nai/codex/overnight\nrandom\n"
        let result = TmuxListParser.parse(listSessionsOutput: output)
        XCTAssertEqual(result.ai.map(\.tmuxName), ["ai/claude/sigma-revenue", "ai/codex/overnight"])
        XCTAssertEqual(result.other.map(\.tmuxName), ["random"])
    }

    func testParseAIFields() throws {
        let result = TmuxListParser.parse(listSessionsOutput: "ai/claude/sigma-revenue\n")
        let session = try XCTUnwrap(result.ai.first)
        XCTAssertEqual(session.tool, .claude)
        XCTAssertEqual(session.slug, "sigma-revenue")
        XCTAssertNil(session.cwd)
        XCTAssertTrue(session.isAIManaged)
    }

    func testParseOtherFields() throws {
        let result = TmuxListParser.parse(listSessionsOutput: "random\n")
        let session = try XCTUnwrap(result.other.first)
        XCTAssertNil(session.tool)
        XCTAssertEqual(session.slug, "random")
        XCTAssertFalse(session.isAIManaged)
    }

    func testParseEmptyOutput() {
        let result = TmuxListParser.parse(listSessionsOutput: "")
        XCTAssertTrue(result.ai.isEmpty)
        XCTAssertTrue(result.other.isEmpty)
    }
}
