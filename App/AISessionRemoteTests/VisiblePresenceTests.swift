import XCTest
@testable import AISessionRemote

@MainActor
final class VisiblePresenceTests: XCTestCase {
    private var reports: [String?] = []

    private func makePresence() -> VisiblePresence {
        VisiblePresence { [unowned self] in reports.append($0) }
    }

    func testNewFrameAppearingBeforeOldDisappearsStaysVisible() {
        let presence = makePresence()
        let old = UUID(), new = UUID()
        presence.appear(old, todoID: "t1")
        presence.appear(new, todoID: "t2")
        presence.disappear(old)
        XCTAssertEqual(presence.visibleTodoID, "t2")
        XCTAssertEqual(reports, ["t1", "t2"], "the old frame leaving must not clear the new one")
    }

    func testOldFrameDisappearingFirstReportsNilThenNew() {
        let presence = makePresence()
        let old = UUID(), new = UUID()
        presence.appear(old, todoID: "t1")
        presence.disappear(old)
        presence.appear(new, todoID: "t2")
        XCTAssertEqual(reports, ["t1", nil, "t2"])
    }

    func testTwoWindowsFallBackToTheOtherWhenTheFrontOneCloses() {
        let presence = makePresence()
        let main = UUID(), popOut = UUID()
        presence.appear(main, todoID: "t1")
        presence.appear(popOut, todoID: "t2")
        presence.disappear(popOut)
        XCTAssertEqual(presence.visibleTodoID, "t1")
        XCTAssertEqual(reports, ["t1", "t2", "t1"])
    }

    func testLastFrameClosingReportsNil() {
        let presence = makePresence()
        let a = UUID(), b = UUID()
        presence.appear(a, todoID: "t1")
        presence.appear(b, todoID: "t2")
        presence.disappear(b)
        presence.disappear(a)
        XCTAssertNil(presence.visibleTodoID)
        XCTAssertEqual(reports, ["t1", "t2", "t1", nil])
    }

    func testSameConversationInTwoFramesReportsOnce() {
        let presence = makePresence()
        let a = UUID(), b = UUID()
        presence.appear(a, todoID: "t1")
        presence.appear(b, todoID: "t1")
        presence.disappear(a)
        XCTAssertEqual(reports, ["t1"])
        presence.disappear(b)
        XCTAssertEqual(reports, ["t1", nil])
    }
}
