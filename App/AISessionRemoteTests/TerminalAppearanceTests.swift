import SwiftTerm
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

    @MainActor
    func testApplySkipsAnUnchangedPaletteAndFont() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        TerminalAppearance.apply(to: view, palette: .dark, fontSize: 13)
        XCTAssertEqual(view.nativeForegroundColor, TerminalPalette.dark.foreground)
        // Same palette and size: the view is left alone (no repaint per SwiftUI update).
        view.nativeForegroundColor = .red
        TerminalAppearance.apply(to: view, palette: .dark, fontSize: 13)
        XCTAssertEqual(view.nativeForegroundColor, .red)
        // A change applies again.
        TerminalAppearance.apply(to: view, palette: .light, fontSize: 13)
        XCTAssertEqual(view.nativeForegroundColor, TerminalPalette.light.foreground)
        view.nativeForegroundColor = .red
        TerminalAppearance.apply(to: view, palette: .light, fontSize: 14)
        XCTAssertEqual(view.nativeForegroundColor, TerminalPalette.light.foreground)
        XCTAssertEqual(view.font.pointSize, 14)
    }

    func testPalettesHaveSixteenAnsiColors() {
        XCTAssertEqual(TerminalPalette.dark.ansi.count, 16)
        XCTAssertEqual(TerminalPalette.light.ansi.count, 16)
    }
}
