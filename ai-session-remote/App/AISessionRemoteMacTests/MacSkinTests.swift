import SwiftUI
import XCTest
@testable import AI_Session_Remote

/// On the Mac the terminal pane is large and sits beside the sidebar: Phosphor's glow and
/// CRT vignette read as heavy edges there, so the Mac draws neither. Colours, the plain green
/// border and the monospace headings stay.
final class MacSkinTests: XCTestCase {
    override func tearDown() {
        SkinStore.shared.skin = .standard
        super.tearDown()
    }

    func testPhosphorHasNoGlowOrVignetteOnTheMac() {
        SkinStore.shared.skin = .phosphor
        XCTAssertNil(DS.glow)
        XCTAssertEqual(DS.vignetteStrength, 0)
        XCTAssertEqual(AppSkin.phosphor.headingFontDesign, .monospaced)
    }

    func testNeonNoirKeepsItsGlowOnTheMac() {
        SkinStore.shared.skin = .neonNoir
        XCTAssertNotNil(DS.glow)
    }
}
