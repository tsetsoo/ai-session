import XCTest
@testable import AISessionCore

final class TerminalPromptTests: XCTestCase {
    private func parse(_ screen: String) -> TerminalPrompt? {
        TerminalPrompt.parse(screen: screen.components(separatedBy: "\n"))
    }

    func testClaudeBashPrompt() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertTrue(prompt.detail?.contains("touch made-by-test.txt") ?? false)
        XCTAssertFalse(prompt.detail?.contains("Tip:") ?? true)
        XCTAssertEqual(prompt.options.count, 4)
        XCTAssertEqual(prompt.selected, 0)
        XCTAssertEqual(prompt.options[0].label, "Yes")
        XCTAssertTrue(prompt.options[1].label.hasPrefix("Yes, and always allow access to /private"))
        XCTAssertTrue(prompt.options[1].label.hasSuffix("from this project"), "wrapped label is joined")
        XCTAssertEqual(prompt.options[3].label, "No")
        XCTAssertEqual(prompt.options.map(\.needsText), [false, false, false, false])
    }

    func testClaudeBashPromptAtPhoneWidth() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBashNarrow))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes",
            "Yes, and don’t ask again for: grep '\\.swift$'",
            "Yes, and switch to auto mode · auto mode handles these prompts for you",
            "No",
        ])
        let detail = try XCTUnwrap(prompt.detail)
        XCTAssertTrue(detail.contains("List Swift files in the TodoHub folder"), detail)
        XCTAssertFalse(detail.contains("switch to auto mode"), "the wrapped tip's second line is dropped too: \(detail)")
    }

    func testClaudeEditPrompt() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeEdit))
        XCTAssertEqual(prompt.question, "Do you want to make this edit to a.txt?")
        XCTAssertEqual(prompt.options.count, 3)
        XCTAssertTrue(prompt.options[1].label.hasSuffix("for this session"), prompt.options[1].label)
        XCTAssertEqual(prompt.options[2].label, "No")
    }

    func testClaudeQuestionMarksTypeSomethingAsText() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeQuestion))
        XCTAssertEqual(prompt.question, "Which colour do you prefer?")
        XCTAssertEqual(prompt.options.map(\.label), ["Red", "Green", "Blue", "Type something.", "Chat about this"])
        XCTAssertEqual(prompt.options[0].detail, "The colour red")
        XCTAssertEqual(prompt.options.map(\.needsText), [false, false, false, true, false])
        XCTAssertEqual(prompt.selected, 0)
    }

    func testCodexCommandPrompt() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.codexCommand))
        XCTAssertEqual(prompt.question, "Would you like to run the following command?")
        XCTAssertTrue(prompt.detail?.contains("$ touch codex-made.txt") ?? false)
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes, proceed",
            "Yes, and don't ask again for commands that start with `touch codex-made.txt`",
            "No, and tell Codex what to do differently",
        ])
        XCTAssertEqual(prompt.options.map(\.needsText), [false, false, true])
        XCTAssertEqual(prompt.selected, 0)
    }

    func testCodexPatchPrompt() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.codexPatch))
        XCTAssertEqual(prompt.question, "Would you like to make the following edits?")
        XCTAssertTrue(prompt.detail?.contains("a.txt") ?? false)
        XCTAssertEqual(prompt.options.count, 3)
    }

    func testIdleAndNumberedReplyAreNotPrompts() {
        XCTAssertNil(parse(TerminalPromptFixtures.claudeIdle))
        XCTAssertNil(parse(TerminalPromptFixtures.claudeNumberedReply))
        XCTAssertNil(parse(TerminalPromptFixtures.codexIdle))
    }

    func testUnnumberedTrustScreensAreLeftToTheFallback() {
        XCTAssertNil(parse(TerminalPromptFixtures.claudeTrust))
        XCTAssertNil(parse(TerminalPromptFixtures.codexTrust))
    }

    func testDifferentPromptsHaveDifferentSignatures() throws {
        let bash = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash))
        let edit = try XCTUnwrap(parse(TerminalPromptFixtures.claudeEdit))
        XCTAssertNotEqual(bash.signature, edit.signature)
        XCTAssertEqual(bash.signature, try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash)).signature)
    }

    /// Both tools choose an option the moment its number is typed (checked live against Claude
    /// Code 2.1.316 and codex-cli 0.166). If the menu has already gone, a digit is just text;
    /// ↑ would recall the last message and Enter would send it again.
    func testChoosingTypesTheOptionNumber() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash))
        XCTAssertEqual(prompt.keys(toChoose: 2, tool: "claude"), Array("3".utf8))
        XCTAssertEqual(prompt.keys(toChoose: 0, tool: "codex"), Array("1".utf8))
    }

    func testTypeSomethingIsTypedInPlaceButTellCodexIsNot() throws {
        let question = try XCTUnwrap(parse(TerminalPromptFixtures.claudeQuestion))
        XCTAssertTrue(question.options[3].typesInPlace)
        XCTAssertFalse(question.options[0].typesInPlace)
        let codex = try XCTUnwrap(parse(TerminalPromptFixtures.codexCommand))
        XCTAssertFalse(codex.options[2].typesInPlace)
    }

    func testMovesWithoutEnter() throws {
        let prompt = try XCTUnwrap(parse(TerminalPromptFixtures.claudeQuestion))
        XCTAssertEqual(prompt.keys(toChoose: 1, tool: "claude", enter: false), TerminalKey.down.bytes(tool: "claude"))
    }

    /// Older Claude Code drew the prompt in a box, with "(esc)" on the last option and no hint below.
    func testBoxedPromptWithEscOnTheLastOption() throws {
        let screen = """
        ⏺ Update(src/import/rates.rs)
          ⎿  Updated src/import/rates.rs with 6 additions and 1 removal

        ╭────────────────────────────────────────────────────────────╮
        │ Bash command                                               │
        │                                                            │
        │   cargo test import::rates                                 │
        │                                                            │
        │ Do you want to proceed?                                    │
        │ ❯ 1. Yes                                                   │
        │   2. Yes, and don't ask again for cargo test commands      │
        │   3. No, and tell Claude what to do differently (esc)      │
        ╰────────────────────────────────────────────────────────────╯
        """
        let prompt = try XCTUnwrap(parse(screen))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.detail, "Bash command\ncargo test import::rates")
        XCTAssertEqual(prompt.options.map(\.label), [
            "Yes", "Yes, and don't ask again for cargo test commands", "No, and tell Claude what to do differently",
        ])
        XCTAssertEqual(prompt.options.map(\.needsText), [false, false, true])
    }

    func testSameQuestionAboutADifferentCommandHasADifferentSignature() throws {
        let first = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash))
        let other = try XCTUnwrap(parse(TerminalPromptFixtures.claudeBash.replacingOccurrences(of: " touch made-by-test.txt\n╌", with: " rm -rf build\n╌")))
        XCTAssertEqual(first.question, other.question)
        XCTAssertEqual(first.options.map(\.label), other.options.map(\.label))
        XCTAssertNotEqual(first.signature, other.signature)
    }
}
