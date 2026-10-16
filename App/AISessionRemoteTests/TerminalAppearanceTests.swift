import SwiftUI
import XCTest
@testable import AISessionRemote

final class TerminalAppearanceTests: XCTestCase {
    func testClampedPinsToRange() {
        XCTAssertEqual(TerminalAppearance.clamped(4), 9)
        XCTAssertEqual(TerminalAppearance.clamped(30), 24)
        XCTAssertEqual(TerminalAppearance.clamped(13), 13)
    }

    func testSteppedIsOnePointAndClamped() {
        XCTAssertEqual(TerminalAppearance.stepped(24, by: 1), 24)
        XCTAssertEqual(TerminalAppearance.stepped(9, by: -1), 9)
        XCTAssertEqual(TerminalAppearance.stepped(12, by: 1), 13)
        XCTAssertEqual(TerminalAppearance.stepped(12, by: -1), 11)
    }

    func testSystemThemeFollowsColorScheme() {
        XCTAssertEqual(TerminalAppearance.palette(theme: .system, colorScheme: .dark), .dark)
        XCTAssertEqual(TerminalAppearance.palette(theme: .system, colorScheme: .light), .light)
    }

    func testExplicitThemeIgnoresColorScheme() {
        XCTAssertEqual(TerminalAppearance.palette(theme: .light, colorScheme: .dark), .light)
        XCTAssertEqual(TerminalAppearance.palette(theme: .dark, colorScheme: .light), .dark)
    }

    func testPalettesHaveSixteenAnsiColors() {
        XCTAssertEqual(TerminalPalette.dark.ansi.count, 16)
        XCTAssertEqual(TerminalPalette.light.ansi.count, 16)
    }
}
