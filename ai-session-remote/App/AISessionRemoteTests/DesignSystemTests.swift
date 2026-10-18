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
}
