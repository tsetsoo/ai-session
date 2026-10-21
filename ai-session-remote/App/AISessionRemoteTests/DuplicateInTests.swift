import AISessionCore
import XCTest
@testable import AISessionRemote

final class DuplicateInTests: XCTestCase {
    func testMenuProposesDuplicate2() {
        XCTAssertEqual(DuplicateIn.proposedName(existingLabels: ["duplicate"]), "duplicate 2")
    }

    func testSummaryCancelDoesNotCallCreate() async {
        var calls = 0
        await DuplicateIn.perform(.cancelled) { calls += 1 }
        XCTAssertEqual(calls, 0)
    }
}
