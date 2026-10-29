import XCTest
@testable import AISessionCore

final class CommandClipboardTests: XCTestCase {
    func testRestoreClaudeLayoutWrapsAndIndentationFromSavedCommand() {
        let command = "curl --header 'X-Name: a  b' https://example.test/some/long/path"
        let source = CommandClipboard.candidates(in: ["Run this:\n```sh\n\(command)\n```"])
        let selected = "curl --header 'X-Name: a  b'\n  https://example.test/some/long/path"
        XCTAssertEqual(CommandClipboard.text(for: selected, candidates: source), command)
    }

    func testKeepRealNewlinesContinuationsQuotedSpacesAndHeredocs() {
        let command = "printf '%s\\n' \\\n  'a  b'\n\ncat <<'EOF'\n  keep this  \n\nEOF"
        let snippets = CommandClipboard.candidates(in: ["```bash\n\(command)\n```"])
        let selected = command.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
        XCTAssertEqual(CommandClipboard.text(for: selected, candidates: snippets), command)
    }

    func testCopyUnmatchedAndAmbiguousSelectionsVerbatim() {
        let selected = "echo a\n  b"
        XCTAssertEqual(CommandClipboard.text(for: selected, candidates: ["echo ab", "echo a b"]), selected)
        XCTAssertEqual(CommandClipboard.text(for: "echo 'a  b'", candidates: ["echo 'a b'"]), "echo 'a  b'")
        XCTAssertEqual(CommandClipboard.text(for: "some text\n  here", candidates: ["git status"]), "some text\n  here")
    }

    func testInlineSnippetsTildeFencesAndDuplicateIdenticalCommands() {
        let snippets = CommandClipboard.candidates(in: ["Try `git status`.\n~~~sh\ngit status\n~~~"])
        XCTAssertEqual(snippets, ["git status"])
        XCTAssertEqual(CommandClipboard.text(for: "git\n status", candidates: snippets), "git status")
    }

    func testIncompleteStreamingCodeBlockIsNotUsed() {
        XCTAssertEqual(CommandClipboard.candidates(in: ["```sh\necho partial"]), [])
    }

    func testSelectOneWrappedCommandFromABlockWithSeveralCommands() {
        let snippets = CommandClipboard.candidates(in: ["```sh\ngit status\nprintf '%s' 'hello  world'\ngit diff\n```"])
        XCTAssertEqual(CommandClipboard.text(for: "printf '%s'\n  'hello  world'", candidates: snippets), "printf '%s' 'hello  world'")
    }
}
