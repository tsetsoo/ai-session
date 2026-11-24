import SwiftUI
import XCTest
@testable import AI_Session_Remote

/// On the Mac the terminal pane is large and sits beside the sidebar: the iPhone's glow and
/// CRT vignette read as heavy edges there, so the Mac draws a very slight version of each.
final class MacSkinTests: XCTestCase {
    override func tearDown() {
        SkinStore.shared.skin = .standard
        super.tearDown()
    }

    func testPhosphorGlowAndVignetteAreVerySlightOnTheMac() {
        SkinStore.shared.skin = .phosphor
        let glow = try? XCTUnwrap(DS.glow)
        XCTAssertNotNil(glow)
        XCTAssertLessThanOrEqual(NSColor(glow ?? .clear).alphaComponent, 0.15)
        XCTAssertLessThanOrEqual(DS.glowRadius, 3)
        XCTAssertGreaterThan(DS.vignetteStrength, 0)
        XCTAssertLessThanOrEqual(DS.vignetteStrength, 0.15)
        XCTAssertGreaterThanOrEqual(DS.vignetteClearUntil, 0.85, "only the very edge darkens")
        XCTAssertEqual(AppSkin.phosphor.headingFontDesign, .monospaced)
    }

    func testNeonNoirKeepsItsGlowOnTheMac() {
        SkinStore.shared.skin = .neonNoir
        XCTAssertNotNil(DS.glow)
    }

    /// The tests run inside the real app (same preferences): changing the theme here must never
    /// change the person's saved theme. A test run once reset it to Standard on every Mac deploy.
    func testTestsNeverTouchTheSavedTheme() {
        let saved = UserDefaults.standard.string(forKey: SkinStore.defaultsKey)
        SkinStore.shared.skin = .neonNoir
        SkinStore.shared.skin = .standard
        XCTAssertEqual(UserDefaults.standard.string(forKey: SkinStore.defaultsKey), saved)
    }
}
