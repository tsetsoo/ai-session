import XCTest
@testable import AISessionCore

final class TerminalEscapeScannerTests: XCTestCase {
    private enum Seen: Equatable {
        case csi(marker: UInt8?, intermediate: UInt8?, params: String, final: Character)
        case escape(Character)
    }

    private func scan(_ chunks: [String]) -> [Seen] {
        var scanner = TerminalEscapeScanner()
        var seen: [Seen] = []
        for byte in chunks.flatMap({ Array($0.utf8) }) {
            switch scanner.step(byte) {
            case .csi(let csi)?:
                seen.append(.csi(marker: csi.marker, intermediate: csi.intermediate,
                                 params: String(decoding: csi.params, as: UTF8.self),
                                 final: Character(UnicodeScalar(csi.final))))
            case .escape(let final)?:
                seen.append(.escape(Character(UnicodeScalar(final))))
            case nil:
                break
            }
        }
        return seen
    }

    func testReadsMarkersIntermediatesAndParamsAcrossChunks() {
        XCTAssertEqual(scan(["a\u{1B}[?20", "31hb\u{1B}[!p\u{1B}[48:2::1:2:3m\u{1B}7"]), [
            .csi(marker: 0x3F, intermediate: nil, params: "2031", final: "h"),
            .csi(marker: nil, intermediate: 0x21, params: "", final: "p"),
            .csi(marker: nil, intermediate: nil, params: "48:2::1:2:3", final: "m"),
            .escape("7"),
        ])
    }

    func testSkipsStringsUntilTheirTerminator() {
        XCTAssertEqual(scan(["\u{1B}]0;[?996n\u{07}\u{1B}P[1m\u{1B}\\\u{1B}[1m"]), [
            .escape("\\"),
            .csi(marker: nil, intermediate: nil, params: "1", final: "m"),
        ])
    }

    func testCancelledOverlongAndDoubleIntermediateSequencesAreDropped() {
        let long = String(repeating: "1;", count: 100)
        XCTAssertEqual(scan(["\u{1B}[1\u{18}m", "\u{1B}[\(long)m", "\u{1B}[ !p", "\u{1B}[2m"]), [
            .csi(marker: nil, intermediate: nil, params: "2", final: "m"),
        ])
    }

    func testNumbersDropSubParameters() {
        var scanner = TerminalEscapeScanner()
        var numbers: [Int] = []
        for byte in Array("\u{1B}[38:2:1:2:3;;7m".utf8) {
            if case .csi(let csi)? = scanner.step(byte) { numbers = csi.numbers }
        }
        XCTAssertEqual(numbers, [38, 0, 7])
    }
}
