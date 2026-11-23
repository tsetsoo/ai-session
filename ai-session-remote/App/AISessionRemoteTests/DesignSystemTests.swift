import AISessionCore
import SwiftUI
import UIKit
import XCTest
@testable import AISessionRemote

/// The asset catalog's AccentColor (the system's selection colour) and `DS.accent` are one accent.
final class DesignSystemTests: XCTestCase {
    private func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    func testAccentAssetMatchesDesignSystemAccent() throws {
        let asset = try XCTUnwrap(UIColor(named: "AccentColor", in: Bundle(for: AppModel.self), compatibleWith: nil))
        let accent = UIColor(DS.accent)
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (assetValue, accentValue) in zip(rgba(asset, style), rgba(accent, style)) {
                XCTAssertEqual(assetValue, accentValue, accuracy: 0.002, "\(style == .dark ? "dark" : "light")")
            }
        }
    }

    func testEachToolHasAnIcon() {
        for tool in AITool.allCases {
            let image = if let asset = AppTheme.imageName(for: tool) {
                UIImage(named: asset, in: Bundle(for: AppModel.self), compatibleWith: nil)
            } else {
                UIImage(systemName: AppTheme.iconName(for: tool))
            }
            XCTAssertNotNil(image, tool.rawValue)
        }
    }
    // MARK: Skins

    override func tearDown() {
        SkinStore.shared.skin = .standard
        super.tearDown()
    }

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let c = rgba(UIColor(color), style).map { UInt32(($0 * 255).rounded()) }
        return c[0] << 16 | c[1] << 8 | c[2]
    }

    func testStandardTokensMatchToday() {
        SkinStore.shared.skin = .standard
        XCTAssertEqual(hex(DS.accent, .light), 0xB4532E)
        XCTAssertEqual(hex(DS.accent, .dark), 0xE8916F)
        XCTAssertEqual(hex(DS.error, .light), 0xC4302B)
        XCTAssertEqual(DS.success, .green)
        XCTAssertEqual(DS.destructive, .red)
        XCTAssertEqual(DS.attention, .orange)
        XCTAssertNil(DS.windowBackground)
        XCTAssertNil(DS.surface)
        XCTAssertEqual(DS.radius(10), 10)
        XCTAssertNil(DS.glow)
    }

    func testPhosphorTokens() {
        SkinStore.shared.skin = .phosphor
        XCTAssertEqual(DS.radius(10), 0)
        XCTAssertEqual(hex(DS.accent, .dark), 0x33FF77)
        XCTAssertNotNil(DS.windowBackground)
        XCTAssertNil(DS.glow)
    }

    func testNeonNoirAccentIsDistinctFromError() {
        SkinStore.shared.skin = .neonNoir
        let a = rgba(UIColor(DS.accent), .dark), e = rgba(UIColor(DS.error), .dark)
        let distance = sqrt(zip(a, e).prefix(3).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        XCTAssertGreaterThan(distance, 0.25)
        XCTAssertEqual(hex(DS.accent, .dark), 0xFF2E97)
        XCTAssertNotNil(DS.glow)
    }
}
