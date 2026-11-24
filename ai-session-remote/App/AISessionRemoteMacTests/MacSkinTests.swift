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

    /// The Mac draws its own selection highlight (grey, or the built-in terracotta accent)
    /// over a painted row background. In a skin the list hides it, so only the skin's tint
    /// shows; Standard keeps the system highlight.
    @MainActor
    func testSkinnedListsHideTheSystemSelectionHighlight() throws {
        func table(for skin: AppSkin) throws -> NSTableView {
            SkinStore.shared.skin = skin
            var selection: String? = "a"
            let binding = Binding(get: { selection }, set: { selection = $0 })
            let list = List(selection: binding) {
                Text("a").tag("a")
                Text("b").tag("b")
            }
            .skinnedSelectionHighlight()
            let host = NSHostingView(rootView: list)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return try XCTUnwrap(find(host))
        }
        XCTAssertEqual(try table(for: .phosphor).selectionHighlightStyle, .none)
        XCTAssertEqual(try table(for: .neonNoir).selectionHighlightStyle, .none)
        XCTAssertNotEqual(try table(for: .standard).selectionHighlightStyle, .none)
    }
}
