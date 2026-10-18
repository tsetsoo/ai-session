import XCTest
@testable import AISessionCore

final class PaletteMatcherTests: XCTestCase {
    func testCaseAndDiacriticInsensitiveSubsequence() {
        XCTAssertNotNil(PaletteMatcher.score(query: "sante", candidate: "Santé party-size rates"))
        XCTAssertNotNil(PaletteMatcher.score(query: "SPR", candidate: "Santé party-size rates"))
    }

    func testNoMatch() {
        XCTAssertNil(PaletteMatcher.score(query: "zzz", candidate: "Santé party-size rates"))
    }

    func testPrefixBeatsScattered() {
        let prefix = PaletteMatcher.score(query: "rat", candidate: "rates screen")!
        let scattered = PaletteMatcher.score(query: "rat", candidate: "fix the rates")!
        let spread = PaletteMatcher.score(query: "rat", candidate: "xxrxxaxxt")!
        XCTAssertGreaterThan(prefix, scattered)
        XCTAssertGreaterThan(scattered, spread)
    }
}
