import AppKit
import Foundation
import XCTest

/// The Mac tests run inside the app, with the app's real preferences. Its window saves its
/// frame there, under a key that changes with every test build, so each run used to leave a
/// new pair of entries behind. This removes the keys the run added and the test window's.
@objc(TestPreferencesGuard)
final class TestPreferencesGuard: NSObject, XCTestObservation {
    private var keysAtStart: Set<String> = []

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        keysAtStart = Set(UserDefaults.standard.persistentDomain(forName: Self.domain)?.keys.map { $0 } ?? [])
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let now = Set(UserDefaults.standard.persistentDomain(forName: Self.domain)?.keys.map { $0 } ?? [])
        // Keys the run added, plus the test window's saved frames (written when the window
        // opened, before the run started, under a name unique to this test build).
        let names = MainActor.assumeIsolated { NSApp.windows.map(\.frameAutosaveName).filter { !$0.isEmpty } }
        let windowKeys = now.filter { key in
            names.contains { key == "NSWindow Frame \($0)" || key.hasPrefix("NSSplitView Subview Frames \($0)") }
        }
        for key in now.subtracting(keysAtStart).union(windowKeys) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The app saves window frames again when it quits; stop that for these windows.
        MainActor.assumeIsolated { NSApp.windows.forEach { $0.setFrameAutosaveName("") } }
    }

    private static var domain: String { Bundle.main.bundleIdentifier ?? "com.aisessionremote.mac" }
}
