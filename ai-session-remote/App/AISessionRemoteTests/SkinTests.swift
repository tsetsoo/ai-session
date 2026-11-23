import SwiftUI
import XCTest
@testable import AISessionRemote

@MainActor
final class SkinTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    override func tearDown() {
        SkinStore.shared.skin = .standard
        super.tearDown()
    }

    func testDefaultsToStandard() {
        XCTAssertEqual(SkinStore(defaults: freshDefaults()).skin, .standard)
    }

    func testPersistsSelection() {
        let defaults = freshDefaults()
        SkinStore(defaults: defaults).skin = .phosphor
        XCTAssertEqual(SkinStore(defaults: defaults).skin, .phosphor)
    }

    func testUnknownRawValueFallsBack() {
        let defaults = freshDefaults()
        defaults.set("vaporwave", forKey: SkinStore.defaultsKey)
        XCTAssertEqual(SkinStore(defaults: defaults).skin, .standard)
    }

    func testMetadata() {
        XCTAssertEqual(AppSkin.neonNoir.soundSuffix, "neon-noir")
        XCTAssertEqual(AppSkin.phosphor.soundSuffix, "phosphor")
        XCTAssertNil(AppSkin.standard.soundSuffix)
        XCTAssertNil(AppSkin.standard.iconName)
        XCTAssertEqual(AppSkin.neonNoir.iconName, "AppIcon-NeonNoir")
        XCTAssertTrue(AppSkin.phosphor.isDark)
        XCTAssertTrue(AppSkin.neonNoir.isDark)
        XCTAssertFalse(AppSkin.standard.isDark)
        XCTAssertEqual(AppSkin.neonNoir.displayName, "Neon noir")
    }
}
