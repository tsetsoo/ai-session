import XCTest
@testable import AISessionCore

final class SessionMetadataTests: XCTestCase {
    func testFilenameReplacesSlashes() {
        XCTAssertEqual(
            SessionMetadataStore.filename(for: "ai/claude/sigma-revenue"),
            "ai__claude__sigma-revenue.json"
        )
    }

    func testRoundTripJSON() throws {
        let meta = SessionMetadata(
            tool: .cursor,
            cwd: "~/programming/portfolio-tracker",
            title: "portfolio",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cli: ["agent"]
        )
        let data = try meta.jsonData()
        let decoded = try SessionMetadata.from(jsonData: data)
        XCTAssertEqual(decoded, meta)
    }
}
