import XCTest
@testable import AISessionRemote

final class TerminalTouchScrollTests: XCTestCase {
    // MARK: Drag to wheel steps

    func testOneStepPerLineOfTravel() {
        var scroll = TerminalTouchScroll(lineHeight: 20)
        XCTAssertEqual(scroll.steps(forDrag: 20), 1)
        XCTAssertEqual(scroll.steps(forDrag: 60), 3)
    }

    func testDraggingDownShowsEarlierTextAndUpShowsLater() {
        var scroll = TerminalTouchScroll(lineHeight: 20)
        XCTAssertGreaterThan(scroll.steps(forDrag: 40), 0)
        XCTAssertLessThan(scroll.steps(forDrag: -40), 0)
    }

    func testPartialLinesCarryOver() {
        var scroll = TerminalTouchScroll(lineHeight: 20)
        XCTAssertEqual(scroll.steps(forDrag: 12), 0)
        XCTAssertEqual(scroll.steps(forDrag: 12), 1)
        XCTAssertEqual(scroll.steps(forDrag: 12), 0)
        XCTAssertEqual(scroll.steps(forDrag: 12), 1)
    }

    func testReversingDirectionUndoesTheCarry() {
        var scroll = TerminalTouchScroll(lineHeight: 20)
        XCTAssertEqual(scroll.steps(forDrag: 15), 0)
        XCTAssertEqual(scroll.steps(forDrag: -15), 0)
        XCTAssertEqual(scroll.steps(forDrag: -15), 0)
        XCTAssertEqual(scroll.steps(forDrag: -10), -1)
    }

    func testResetDropsTheCarry() {
        var scroll = TerminalTouchScroll(lineHeight: 20)
        _ = scroll.steps(forDrag: 15)
        scroll.reset()
        XCTAssertEqual(scroll.steps(forDrag: 10), 0)
    }

    func testZeroLineHeightNeverScrolls() {
        var scroll = TerminalTouchScroll(lineHeight: 0)
        XCTAssertEqual(scroll.steps(forDrag: 500), 0)
    }

    // MARK: Momentum

    func testMomentumCarriesOnAndSlowsDown() {
        var momentum = TerminalScrollMomentum(velocity: 1500)
        let first = momentum.advance(by: 1.0 / 60)
        let second = momentum.advance(by: 1.0 / 60)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(first!, 0)
        XCTAssertLessThan(second!, first!)
    }

    func testMomentumKeepsTheFlickDirection() {
        var momentum = TerminalScrollMomentum(velocity: -1500)
        XCTAssertLessThan(momentum.advance(by: 1.0 / 60)!, 0)
    }

    func testMomentumStops() {
        var momentum = TerminalScrollMomentum(velocity: 3000)
        var frames = 0
        while momentum.advance(by: 1.0 / 60) != nil {
            frames += 1
            XCTAssertLessThan(frames, 600, "momentum must end within ten seconds")
        }
        XCTAssertNil(momentum.advance(by: 1.0 / 60))
    }

    func testSlowReleaseHasNoMomentum() {
        var momentum = TerminalScrollMomentum(velocity: 20)
        XCTAssertNil(momentum.advance(by: 1.0 / 60))
    }
}
