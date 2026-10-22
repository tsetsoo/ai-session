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

final class TerminalWheelAnchorTests: XCTestCase {
    private let size = CGSize(width: 400, height: 200)

    func testAnchorIsTheCellUnderThePoint() {
        let anchor = TerminalWheelAnchor(point: CGPoint(x: 105, y: 55), size: size, cols: 40, rows: 20)
        XCTAssertEqual(anchor, TerminalWheelAnchor(point: CGPoint(x: 109, y: 59), size: size, cols: 40, rows: 20))
        XCTAssertEqual(anchor.col, 10)
        XCTAssertEqual(anchor.row, 5)
    }

    func testAnchorStaysOffTheStatusRows() {
        XCTAssertEqual(TerminalWheelAnchor(point: CGPoint(x: 0, y: 199), size: size, cols: 40, rows: 20).row, 18)
        XCTAssertEqual(TerminalWheelAnchor(point: CGPoint(x: 0, y: 1), size: size, cols: 40, rows: 20).row, 1)
    }

    func testAnchorClampsOutsidePoints() {
        let anchor = TerminalWheelAnchor(point: CGPoint(x: 900, y: -50), size: size, cols: 40, rows: 20)
        XCTAssertEqual(anchor.col, 39)
        XCTAssertEqual(anchor.row, 1)
    }

    func testTinyGridUsesWhatRowsItHas() {
        XCTAssertEqual(TerminalWheelAnchor(point: CGPoint(x: 0, y: 199), size: size, cols: 40, rows: 2).row, 1)
        let empty = TerminalWheelAnchor(point: CGPoint(x: 50, y: 50), size: .zero, cols: 0, rows: 0)
        XCTAssertEqual(empty.col, 0)
        XCTAssertEqual(empty.row, 0)
    }
}
