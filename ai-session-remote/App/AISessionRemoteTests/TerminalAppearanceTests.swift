import AISessionCore
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
    // MARK: Skins

    func testSkinOverridesTheme() {
        XCTAssertEqual(TerminalAppearance.palette(theme: .light, colorScheme: .light, skin: .neonNoir), .neonNoir)
        XCTAssertEqual(TerminalAppearance.palette(theme: .dark, colorScheme: .light, skin: .phosphor), .phosphor)
        XCTAssertEqual(TerminalAppearance.palette(theme: .light, colorScheme: .light, skin: .standard), .light)
    }

    func testSkinPalettesHaveSixteenAnsiColors() {
        XCTAssertEqual(TerminalPalette.neonNoir.ansi.count, 16)
        XCTAssertEqual(TerminalPalette.phosphor.ansi.count, 16)
    }

    func testSkinPalettesAreLegible() {
        for (name, palette) in [("neonNoir", TerminalPalette.neonNoir), ("phosphor", TerminalPalette.phosphor)] {
            let p = palette.contrastPalette
            XCTAssertGreaterThanOrEqual(TerminalContrastGuard.contrast(p.foreground, p.background), 7, name)
            for i in 1..<16 {
                XCTAssertGreaterThanOrEqual(TerminalContrastGuard.contrast(p.ansi[i], p.background), 3, "\(name) ansi \(i)")
            }
            // Bright black carries Claude's dimmed hints: body-text contrast.
            XCTAssertGreaterThanOrEqual(TerminalContrastGuard.contrast(p.ansi[8], p.background), 4.5, "\(name) dimmed")
        }
    }

    func testSkinPalettesReportDark() {
        XCTAssertTrue(TerminalPalette.neonNoir.isDark)
        XCTAssertTrue(TerminalPalette.phosphor.isDark)
        XCTAssertTrue(TerminalPalette.dark.isDark)
        XCTAssertFalse(TerminalPalette.light.isDark)
    }

    func testPhosphorAnsiColorsAreDistinct() {
        let ansi = TerminalPalette.phosphor.contrastPalette.ansi
        func d(_ a: TerminalContrastGuard.RGB, _ b: TerminalContrastGuard.RGB) -> Double {
            let dr = Double(a.r) - Double(b.r), dg = Double(a.g) - Double(b.g), db = Double(a.b) - Double(b.b)
            return (dr * dr + dg * dg + db * db).squareRoot() / 255
        }
        for i in 1...6 {
            for j in (i + 1)..<7 {
                XCTAssertGreaterThan(d(ansi[i], ansi[j]), 0.15, "ansi \(i) vs \(j)")
            }
        }
    }

    /// Phosphor is easy on the eyes: no near-black background (halation), text that isn't
    /// glaring neon (contrast capped, saturation low), while staying well above the legibility
    /// floors checked in `testSkinPalettesAreLegible`.
    func testPhosphorIsEasyOnTheEyes() {
        let p = TerminalPalette.phosphor.contrastPalette
        let contrast = TerminalContrastGuard.contrast(p.foreground, p.background)
        XCTAssertLessThanOrEqual(contrast, 13.5, "glare")
        XCTAssertGreaterThanOrEqual(contrast, 7)
        let fg = [p.foreground.r, p.foreground.g, p.foreground.b].map(Double.init)
        let saturation = (fg.max()! - fg.min()!) / fg.max()!
        XCTAssertLessThanOrEqual(saturation, 0.35, "neon")
        let bg = [p.background.r, p.background.g, p.background.b]
        XCTAssertGreaterThanOrEqual(bg.max()!, 0x16, "pure black background")
    }
}
