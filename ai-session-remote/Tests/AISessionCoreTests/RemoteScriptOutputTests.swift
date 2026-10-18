import XCTest
@testable import AISessionCore

final class RemoteScriptOutputTests: XCTestCase {
    private let marker = RemoteScriptOutput.statusMarker

    func testSplitsAtMarkerLine() {
        let stdout = "ai/claude/demo\t123\t0\n\(marker)\n---x.json---\n{}\n"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "ai/claude/demo\t123\t0")
        XCTAssertEqual(tail, "---x.json---\n{}")
    }

    func testMissingMarkerYieldsNilTail() {
        let (head, tail) = RemoteScriptOutput.split("only-sessions\n", at: marker)
        XCTAssertEqual(head, "only-sessions")
        XCTAssertNil(tail)
    }

    func testEmptyHeadAndEmptyTailAreDistinguishedFromMissing() {
        let (head, tail) = RemoteScriptOutput.split("\(marker)\n", at: marker)
        XCTAssertEqual(head, "")
        XCTAssertEqual(tail, "")
    }

    /// A tmux session whose name merely contains the marker text must not split the output.
    /// Only a line exactly equal to the marker counts.
    func testMarkerAsSubstringOfLongerLineDoesNotSplit() {
        let stdout = "prefix\(marker)suffix\t1\t0\n"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "prefix\(marker)suffix\t1\t0")
        XCTAssertNil(tail)
    }

    func testSplitsAtFirstMarkerOnly() {
        let stdout = "a\n\(marker)\nb\n\(marker)\nc"
        let (head, tail) = RemoteScriptOutput.split(stdout, at: marker)
        XCTAssertEqual(head, "a")
        XCTAssertEqual(tail, "b\n\(marker)\nc")
    }
}
