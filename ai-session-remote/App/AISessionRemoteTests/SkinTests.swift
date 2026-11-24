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
    /// Nothing is drawn over the terminal's text in Phosphor: scanlines cut through the letters
    /// and made it hard to read. Every row inside the frame stays the terminal's own colour.
    func testPhosphorTerminalHasNoLinesThroughText() throws {
        SkinStore.shared.skin = .phosphor
        let host = UIHostingController(rootView: Color(PlatformNativeColor(hex: 0x33FF77))
            .skinnedTerminalFrame().frame(width: 200, height: 200))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
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
        // Ten consecutive rows in the middle: the green channel never dips (BGRA).
        let greens = (95..<105).map { Int(data[$0 * cg.bytesPerRow + 100 * 4 + 1]) }
        XCTAssertEqual(Set(greens).count, 1, "rows differ: \(greens)")
        XCTAssertGreaterThan(greens[0], 0xF0)
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
        // Near the bottom, below the one row, in 8-bit BGRA: the Phosphor background 0x0A1610.
        let px = (0..<4).map { Int(pixel[offset + $0]) }
        XCTAssertEqual(px[3], 255, "opaque: \(px)")
        XCTAssertLessThan(abs(px[1] - 0x16), 4, "green: \(px)")
        XCTAssertLessThan(abs(px[0] - 0x10), 4, "blue: \(px)")
        XCTAssertLessThan(abs(px[2] - 0x0A), 4, "red: \(px)")
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
        // Inside the row, left of the text: the Phosphor surface 0x11231A (BGRA).
        let px = (0..<4).map { Int(data[offset + $0]) }
        XCTAssertLessThan(abs(px[1] - 0x23), 4, "green: \(px)")
        XCTAssertLessThan(abs(px[0] - 0x1A), 4, "blue: \(px)")
    }

    /// Phosphor keeps the system font for the interface (monospace everywhere was hard to read
    /// and cut titles short); the terminal and code blocks stay monospaced.
    func testInterfaceFontStaysSystemInEverySkin() {
        for skin in AppSkin.allCases {
            XCTAssertNil(skin.interfaceFontDesign, skin.rawValue)
        }
    }

    /// Screen backgrounds take the skin's (Standard: the same system colour), so no skinned
    /// screen sits on stock black: Phosphor is meant to be off pure black.
    func testScreenBackgroundsFollowTheSkin() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AISessionRemote/Views")
        let bare = try NSRegularExpression(pattern: #"\.background\(Color\(uiColor: \.system(Grouped)?Background\)\)"#)
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where bare.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertTrue(hits.isEmpty, hits.joined(separator: "\n"))
    }
}
