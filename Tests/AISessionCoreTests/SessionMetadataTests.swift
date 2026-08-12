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
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            cli: ["agent"]
        )
        let data = try meta.jsonData()
        let decoded = try SessionMetadata.from(jsonData: data)
        XCTAssertEqual(decoded, meta)
    }

    func testPrintfTemplateHasExactlyOneSubstitutionSlot() throws {
        let template = try SessionMetadata.printfTemplate(
            tool: .claude,
            cwd: "/tmp/demo",
            title: "Demo",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(template.components(separatedBy: "%s").count - 1, 1)
        XCTAssertTrue(template.contains("\"cli\":[\"%s\"]"))
    }

    /// A literal `%` in user text must survive printf. Without escaping, a title of
    /// "100% done" makes printf consume "% d" as a conversion and corrupt the metadata file.
    func testPrintfTemplateEscapesLiteralPercentInTitle() throws {
        let template = try SessionMetadata.printfTemplate(
            tool: .claude,
            cwd: "/tmp",
            title: "100% done",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(template.contains("100%% done"))
        XCTAssertEqual(template.components(separatedBy: "%s").count - 1, 1)
    }

    /// The template is only useful if feeding it through printf yields JSON that decodes back
    /// into the same metadata. This is the end-to-end guard on escaping.
    func testPrintfTemplateRoundTripsThroughPrintf() throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let template = try SessionMetadata.printfTemplate(
            tool: .claude, cwd: "/tmp", title: "100% done", startedAt: startedAt
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = [template, "/usr/local/bin/claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let decoded = try SessionMetadata.from(jsonData: data)
        XCTAssertEqual(decoded.title, "100% done")
        XCTAssertEqual(decoded.cli, ["/usr/local/bin/claude"])
        XCTAssertEqual(decoded.tool, .claude)
        XCTAssertEqual(decoded.cwd, "/tmp")
    }
}
