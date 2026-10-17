import XCTest
@testable import AISessionRemote

final class TextSizeShortcutsTests: XCTestCase {
    func testCommandEqualsIsAlias() {
        XCTAssertTrue(TextSizeShortcuts.isBiggerTextAlias(characters: "=", command: true, otherModifiers: false))
    }

    func testCommandShiftEqualsIsNotAlias() {
        XCTAssertFalse(TextSizeShortcuts.isBiggerTextAlias(characters: "=", command: true, otherModifiers: true))
    }

    func testCommandPlusIsNotAlias() {
        XCTAssertFalse(TextSizeShortcuts.isBiggerTextAlias(characters: "+", command: true, otherModifiers: false))
    }

    func testEqualsWithoutCommandIsNotAlias() {
        XCTAssertFalse(TextSizeShortcuts.isBiggerTextAlias(characters: "=", command: false, otherModifiers: false))
    }

    func testStepWritesClampedSizeToDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TextSizeShortcutsTests"))
        defaults.removePersistentDomain(forName: "TextSizeShortcutsTests")
        TextSizeShortcuts.step(by: 1, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: TextSizeShortcuts.fontSizeKey), TerminalAppearance.defaultFontSize + 1)
        defaults.set(24.0, forKey: TextSizeShortcuts.fontSizeKey)
        TextSizeShortcuts.step(by: 1, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: TextSizeShortcuts.fontSizeKey), 24)
    }
}
