import XCTest
@testable import AISessionCore

final class ChatFollowTests: XCTestCase {
    func testStartsPinned() {
        let follow = ChatFollow()
        XCTAssertFalse(follow.showsJumpButton)
        XCTAssertTrue(follow.followsNewContent)
    }

    func testUserScrollingUpUnpinsAndContentGrowthDoesNotRepin() {
        var follow = ChatFollow()
        follow.userScrolled(distanceFromBottom: 300)
        XCTAssertFalse(follow.pinned)
        XCTAssertTrue(follow.showsJumpButton)
        XCTAssertFalse(follow.followsNewContent)
    }

    func testReachingBottomByHandRepins() {
        var follow = ChatFollow()
        follow.userScrolled(distanceFromBottom: 300)
        follow.userScrolled(distanceFromBottom: 39)
        XCTAssertTrue(follow.pinned)
    }

    func testJumpToLatestRepins() {
        var follow = ChatFollow()
        follow.userScrolled(distanceFromBottom: 300)
        follow.jumpToLatest()
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.showsJumpButton)
    }
}
