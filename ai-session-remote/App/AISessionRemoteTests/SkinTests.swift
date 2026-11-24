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
    func testSkinnedModifierRendersForAllSkins() {
        for skin in AppSkin.allCases {
            SkinStore.shared.skin = skin
            let host = UIHostingController(rootView: Text("x").skinned())
            host.loadViewIfNeeded()
            XCTAssertNotNil(host.view, skin.rawValue)
        }
    }

    func testAppearanceSettingsViewBuilds() {
        let host = UIHostingController(rootView: NavigationStack { AppearanceSettingsView() })
        host.loadViewIfNeeded()
        XCTAssertNotNil(host.view)
    }
    func testScanlinesAreFaintAndStatic() {
        XCTAssertEqual(ScanlineOverlay.lineSpacing, 3)
        XCTAssertEqual(ScanlineOverlay.lineOpacity, 0.25)
    }

    func testSkinStylesRenderForAllSkins() {
        for skin in AppSkin.allCases {
            SkinStore.shared.skin = skin
            let view = VStack {
                Text("row").skinnedSelection(true)
                Text("card").skinnedCard()
                Color.black.skinnedTerminalFrame()
                Button("Go") {}.buttonStyle(AccentButtonStyle())
            }
            let host = UIHostingController(rootView: view)
            host.loadViewIfNeeded()
            XCTAssertNotNil(host.view, skin.rawValue)
        }
    }
    /// Views take status colours from `DS`, so the skins can recolour them. Standard's tokens
    /// return the same system colours, so this changes nothing there.
    func testNoHardcodedSystemColorsInViews() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AISessionRemote/Views")
        let pattern = try NSRegularExpression(pattern:
            #"(\.(tint|foregroundStyle)\(\.(red|green|orange|purple|yellow|indigo|blue)\b)|(\bColor\.(red|green|orange|purple|blue|yellow|indigo)\b)|(^\s*case [^:]+:\s*(return )?\.(red|green|orange|purple|blue)\s*$)|(\? \.(red|green|orange|purple|yellow|blue) :)|(: \.(red|green|orange|purple|yellow|blue)\))"#,
            options: [.anchorsMatchLines])
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if pattern.firstMatch(in: line, range: range) != nil {
                    hits.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(hits.isEmpty, "Hardcoded colours:\n" + hits.joined(separator: "\n"))
    }

    func testKeyBarPaletteFollowsSkin() {
        XCTAssertEqual(KeyBarColors(.dark, skin: .standard).bar, KeyBarColors(.dark).bar)
        XCTAssertNotEqual(KeyBarColors(.dark, skin: .phosphor).bar, KeyBarColors(.dark).bar)
        XCTAssertNotEqual(KeyBarColors(.dark, skin: .neonNoir).keyLabel, KeyBarColors(.dark, skin: .phosphor).keyLabel)
    }
    // MARK: Sounds

    func testBundledNameFollowsSkin() {
        XCTAssertEqual(AttentionSound.bundledName(for: .needsYou, skin: .standard), "attention-needs-you")
        XCTAssertEqual(AttentionSound.bundledName(for: .review, skin: .standard), "attention-review")
        XCTAssertEqual(AttentionSound.bundledName(for: .review, skin: .phosphor), "attention-review-phosphor")
        XCTAssertEqual(AttentionSound.bundledName(for: .needsYou, skin: .neonNoir), "attention-needs-you-neon-noir")
    }

    func testSkinSoundFilesAreBundled() {
        for skin in AppSkin.allCases {
            for kind in [AttentionKind.needsYou, .review] {
                let name = AttentionSound.bundledName(for: kind, skin: skin)
                XCTAssertNotNil(Bundle(for: AppModel.self).url(forResource: name, withExtension: "caf"), name)
            }
        }
    }

    func testStandardKeepsDefaultNotificationSound() {
        XCTAssertNil(AttentionSound.skinSound(for: .needsYou, skin: .standard))
        XCTAssertNotNil(AttentionSound.skinSound(for: .needsYou, skin: .phosphor))
    }

    func testSkinSoundFileName() {
        XCTAssertNil(AttentionSound.skinSoundFileName(for: .needsYou, skin: .standard))
        XCTAssertEqual(AttentionSound.skinSoundFileName(for: .needsYou, skin: .neonNoir), "attention-needs-you-neon-noir.caf")
    }

    // MARK: Icons

    func testAlternateIconsAreBundled() throws {
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        XCTAssertNotNil(alternates["AppIcon-NeonNoir"])
        XCTAssertNotNil(alternates["AppIcon-Phosphor"])
    }

    func testDockIconsAreBundled() {
        for name in ["DockIcon-NeonNoir", "DockIcon-Phosphor"] {
            XCTAssertNotNil(UIImage(named: name, in: Bundle(for: AppModel.self), compatibleWith: nil), name)
        }
    }

    func testSkinIconNamesMatchAssets() {
        XCTAssertEqual(AppSkin.neonNoir.iconName, "AppIcon-NeonNoir")
        XCTAssertEqual(AppSkin.phosphor.iconName, "AppIcon-Phosphor")
        XCTAssertEqual(SkinIcon.dockIconName(for: .phosphor), "DockIcon-Phosphor")
        XCTAssertNil(SkinIcon.dockIconName(for: .standard))
    }

    /// Every list and form takes the skin's background (Standard: unchanged), so skinned
    /// screens aren't stock black and grey.
    func testEveryListIsSkinned() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AISessionRemote/Views")
        let list = try NSRegularExpression(pattern: #"(^|[^A-Za-z.])(List|Form)\s*(\(|\{)"#, options: [.anchorsMatchLines])
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lists = list.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let skinned = text.components(separatedBy: ".skinnedList()").count - 1
            if skinned < lists { missing.append("\(file.lastPathComponent): \(lists) lists, \(skinned) skinned") }
        }
        XCTAssertTrue(missing.isEmpty, missing.joined(separator: "\n"))
    }

    func testSkinnedListPaintsTheSkinBackground() throws {
        SkinStore.shared.skin = .phosphor
        let host = UIHostingController(rootView: List { Text("row") }.skinnedList().frame(width: 200, height: 300))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let pixel = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
        let bytesPerRow = try XCTUnwrap(image.cgImage?.bytesPerRow)
        let scale = Int(image.scale)
        let offset = (290 * scale) * bytesPerRow + (100 * scale) * 4
        // Near the bottom, below the one row: the Phosphor window background 0x020A04.
        // 8-bit BGRA (little-endian premultiplied): the Phosphor background is 0x020A04.
        let px = (0..<4).map { Int(pixel[offset + $0]) }
        XCTAssertEqual(px[3], 255, "opaque: \(px)")
        XCTAssertLessThan(abs(px[1] - 0x0A), 6, "green: \(px)")
        XCTAssertLessThan(max(px[0], px[2]), 10, "blue/red: \(px)")
    }

    func testSkinnedRowPaintsTheSkinSurface() throws {
        SkinStore.shared.skin = .phosphor
        let host = UIHostingController(rootView: List { Text("row").frame(height: 200).skinnedRow() }.skinnedList())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        let offset = 150 * cg.bytesPerRow + 28 * 4
        // Inside the row, left of the text: the Phosphor surface 0x031207 (BGRA).
        let px = (0..<4).map { Int(data[offset + $0]) }
        XCTAssertLessThan(abs(px[1] - 0x12), 6, "green: \(px)")
        XCTAssertLessThan(abs(px[0] - 0x07), 6, "blue: \(px)")
    }

    /// Phosphor keeps the system font for the interface (monospace everywhere was hard to read
    /// and cut titles short); the terminal and code blocks stay monospaced.
    func testInterfaceFontStaysSystemInEverySkin() {
        for skin in AppSkin.allCases {
            XCTAssertNil(skin.interfaceFontDesign, skin.rawValue)
        }
    }
}
