import XCTest
@testable import AISessionCore

final class TerminalContrastGuardTests: XCTestCase {
    /// The app's light palette.
    private let light = TerminalContrastGuard.Palette(
        foreground: (0x1F, 0x1E, 0x1C),
        background: (0xFB, 0xFA, 0xF7),
        ansi: Array(repeating: (0x1F, 0x1E, 0x1C), count: 8) + Array(repeating: (0x5C, 0x5B, 0x57), count: 8)
    )

    private let fix = "\u{1B}[38;2;251;250;247m"

    private func run(_ chunks: [String], palette: TerminalContrastGuard.Palette? = nil) -> String {
        var guardian = TerminalContrastGuard(palette: palette ?? light)
        let out = chunks.flatMap { guardian.process(Array($0.utf8)) }
        return String(decoding: out, as: UTF8.self)
    }

    /// A Codex message block tinted for a dark terminal, drawn under the light palette.
    func testDefaultTextOnADarkTruecolorBackgroundGetsTheLightColour() {
        XCTAssertEqual(
            run(["\u{1B}[48;2;58;58;58mremove the null check\u{1B}[49m done"]),
            "\u{1B}[48;2;58;58;58m\(fix)remove the null check\u{1B}[49m\u{1B}[39m done"
        )
    }

    func testIndexedDarkBackgroundIsGuardedToo() {
        // 237 is a dark grey in the xterm ramp; 40 is ANSI black from the palette.
        XCTAssertEqual(run(["\u{1B}[48;5;237mx"]), "\u{1B}[48;5;237m\(fix)x")
        XCTAssertEqual(run(["\u{1B}[40mx\u{1B}[0my"]), "\u{1B}[40m\(fix)x\u{1B}[0my")
    }

    func testReadableBackgroundsAndExplicitForegroundsAreLeftAlone() {
        for text in [
            "\u{1B}[48;2;240;239;236mlight block\u{1B}[0m",  // Codex's tint for a light terminal
            "\u{1B}[37;48;2;58;58;58mprogram chose the text colour\u{1B}[0m",
            "\u{1B}[7m\u{1B}[48;2;58;58;58minverse\u{1B}[0m",
            "\u{1B}[?2004h\u{1B}]11;rgb:0000/0000/0000\u{07}plain",
        ] {
            XCTAssertEqual(run([text]), text, text.debugDescription)
        }
    }

    func testAnExplicitForegroundAfterTheFixReplacesItWithoutAReset() {
        XCTAssertEqual(
            run(["\u{1B}[48;2;58;58;58ma\u{1B}[31mb\u{1B}[39mc"]),
            "\u{1B}[48;2;58;58;58m\(fix)a\u{1B}[31mb\u{1B}[39m\(fix)c"
        )
    }

    func testSequencesSplitAcrossChunks() {
        XCTAssertEqual(
            run(["\u{1B}[48;2;5", "8;58;58", "mx\u{1B}", "[0my"]),
            "\u{1B}[48;2;58;58;58m\(fix)x\u{1B}[0my"
        )
    }

    func testColonFormIsRead() {
        XCTAssertEqual(run(["\u{1B}[48:2::58:58:58mx"]), "\u{1B}[48:2::58:58:58m\(fix)x")
    }

    func testDarkPaletteLeavesTheDarkTintAlone() {
        let dark = TerminalContrastGuard.Palette(
            foreground: (0xE9, 0xE7, 0xE2), background: (0x1A, 0x1A, 0x19), ansi: []
        )
        let text = "\u{1B}[48;2;58;58;58mreadable\u{1B}[0m"
        XCTAssertEqual(run([text], palette: dark), text)
        // A block tinted for a light terminal, drawn under the dark palette, gets the dark colour.
        XCTAssertEqual(
            run(["\u{1B}[48;2;240;239;236mx"], palette: dark),
            "\u{1B}[48;2;240;239;236m\u{1B}[38;2;26;26;25mx"
        )
    }

    func testUnderlineColourArgumentsAreNotReadAsCodes() {
        // Read as codes, `0` would reset the dark background and `40` would set ANSI black.
        XCTAssertEqual(
            run(["\u{1B}[48;2;58;58;58ma\u{1B}[58;2;0;0;255mb"]),
            "\u{1B}[48;2;58;58;58m\(fix)a\u{1B}[58;2;0;0;255mb"
        )
        let text = "\u{1B}[58;2;40;40;40mplain\u{1B}[39m"
        XCTAssertEqual(run([text]), text)
    }

    func testResetsAndCursorRestoreAreFollowed() {
        // After RIS or DECSTR the terminal is back to defaults, so a later `39m` needs no fix.
        for reset in ["\u{1B}c", "\u{1B}[!p"] {
            XCTAssertEqual(
                run(["\u{1B}[48;2;58;58;58m", reset, "\u{1B}[39mx"]),
                "\u{1B}[48;2;58;58;58m\(fix)\(reset)\u{1B}[39mx",
                reset.debugDescription
            )
        }
        // DECRC brings back the dark background saved with DECSC, substitute and all.
        XCTAssertEqual(
            run(["\u{1B}[48;2;58;58;58m\u{1B}7\u{1B}[0m\u{1B}8\u{1B}[1mx"]),
            "\u{1B}[48;2;58;58;58m\(fix)\u{1B}7\u{1B}[0m\u{1B}8\u{1B}[1mx"
        )
        XCTAssertEqual(
            run(["\u{1B}[?1049h\u{1B}[48;2;58;58;58mx\u{1B}[?1049l\u{1B}[1my"]),
            "\u{1B}[?1049h\u{1B}[48;2;58;58;58m\(fix)x\u{1B}[?1049l\u{1B}[1my"
        )
    }

    func testPaletteSwitchFixesTheCurrentForegroundRightAway() {
        let dark = TerminalContrastGuard.Palette(
            foreground: (0xE9, 0xE7, 0xE2), background: (0x1A, 0x1A, 0x19), ansi: []
        )
        var guardian = TerminalContrastGuard(palette: dark)
        _ = guardian.process(Array("\u{1B}[48;2;58;58;58m".utf8))
        XCTAssertEqual(guardian.setPalette(light).map { String(decoding: $0, as: UTF8.self) }, fix)
        XCTAssertEqual(guardian.setPalette(dark).map { String(decoding: $0, as: UTF8.self) }, "\u{1B}[39m")
        XCTAssertNil(guardian.setPalette(dark))
    }

    func testResetClearsASubstituteTheTerminalStillHas() {
        var guardian = TerminalContrastGuard(palette: light)
        XCTAssertNil(guardian.reset())
        _ = guardian.process(Array("\u{1B}[48;2;58;58;58m".utf8))
        XCTAssertEqual(guardian.reset().map { String(decoding: $0, as: UTF8.self) }, "\u{1B}[39m")
        XCTAssertEqual(guardian.process(Array("\u{1B}[39mx".utf8)), Array("\u{1B}[39mx".utf8))
    }
}
