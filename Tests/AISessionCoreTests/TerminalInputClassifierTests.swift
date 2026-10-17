import XCTest
@testable import AISessionCore

final class TerminalInputClassifierTests: XCTestCase {
    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    func testDeviceAttributesAndStatusReportsAreTerminalReplies() {
        for reply in [
            "\u{1B}[?1;2c",          // DA1
            "\u{1B}[>0;276;0c",      // DA2
            "\u{1B}[0n",             // DSR "OK"
            "\u{1B}[12;40R",         // cursor position
            "\u{1B}[?12;40;1R",      // DECXCPR
            "\u{1B}[?10n",
        ] {
            XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes(reply)), reply.debugDescription)
        }
    }

    func testFocusReportsAreTerminalReplies() {
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[I")))
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[O")))
    }

    func testMouseReportsAreTerminalReplies() {
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport([0x1B, 0x5B, 0x4D, 0x20, 0x21, 0x21]))   // X10
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[<0;12;5M")))                  // SGR press
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[<0;12;5m")))                  // SGR release
        XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[32;12;5M")))                  // URXVT
    }

    /// tmux asks the outer terminal for its colours, version and modes when a client attaches.
    func testColourVersionAndModeRepliesAreTerminalReplies() {
        for reply in [
            "\u{1B}]11;rgb:fbfb/fafa/f7f7\u{1B}\\",    // OSC 11, ST-terminated
            "\u{1B}]10;rgb:1f1f/1e1e/1c1c\u{07}",      // OSC 10, BEL-terminated
            "\u{1B}P>|SwiftTerm\u{1B}\\",              // XTVERSION
            "\u{1B}P1$r0m\u{1B}\\",                    // DECRQSS
            "\u{1B}[?2004;1$y",                        // DECRPM
            "\u{1B}[8;24;80t",                         // window size
        ] {
            XCTAssertTrue(TerminalInputClassifier.isTerminalReport(bytes(reply)), reply.debugDescription)
        }
    }

    func testTypedKeysAreUserInput() {
        for typed in [
            "1", "y", "hello", "\r", "\u{03}", "\u{7F}", "\u{1B}",
            "\u{1B}[A", "\u{1B}[B", "\u{1B}[C", "\u{1B}[D",   // arrows
            "\u{1B}OA",                                       // application-mode arrow
            "\u{1B}[1;5D",                                    // ctrl-left
            "\u{1B}[3~", "\u{1B}[5~",                         // delete, page up
            "\u{1B}[Z",                                       // shift-tab
            "\u{1B}[99;5u",                                   // kitty-encoded ctrl-c
            "\u{1B}[200~pasted\u{1B}[201~",                   // bracketed paste
            "\u{1B}\r",                                       // ⇧⏎ for Claude
            "\u{1B}]", "\u{1B}P",                             // meta-] / meta-P
            "\u{1B}[", "\u{1B}[M",                            // incomplete
        ] {
            XCTAssertFalse(TerminalInputClassifier.isTerminalReport(bytes(typed)), typed.debugDescription)
        }
        XCTAssertFalse(TerminalInputClassifier.isTerminalReport([]))
    }

    func testTextThatMerelyEndsInAReportByteIsUserInput() {
        XCTAssertFalse(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[run")))
        XCTAssertFalse(TerminalInputClassifier.isTerminalReport(bytes("c")))
        XCTAssertFalse(TerminalInputClassifier.isTerminalReport(bytes("\u{1B}[1;2;xc")))
    }
}
