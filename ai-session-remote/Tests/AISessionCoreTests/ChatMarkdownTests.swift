import XCTest
@testable import AISessionCore

final class ChatMarkdownTests: XCTestCase {
    func testFencedCodeKeepsExactContent() {
        let text = "before\n```swift\n  let a = 1  \n\n    b\n```\nafter"
        XCTAssertEqual(ChatMarkdown.blocks(text), [
            .text("before"), .code(language: "swift", code: "  let a = 1  \n\n    b"), .text("after"),
        ])
    }

    func testTildeFenceWithoutLanguage() {
        XCTAssertEqual(ChatMarkdown.blocks("~~~\nx\n~~~"), [.code(language: nil, code: "x")])
    }

    func testUnclosedFenceRunsToEnd() {
        XCTAssertEqual(ChatMarkdown.blocks("intro\n```sh\nnpm test\n\nmore"), [
            .text("intro"), .code(language: "sh", code: "npm test\n\nmore"),
        ])
    }

    func testPipeTableBecomesRows() {
        XCTAssertEqual(ChatMarkdown.blocks("| a | b |\n|---|---|\n| 1 | 2 |"), [.table(rows: [["a", "b"], ["1", "2"]])])
    }

    func testPipeLineWithoutSeparatorStaysText() {
        XCTAssertEqual(ChatMarkdown.blocks("a | b"), [.text("a | b")])
    }

    func testPlainTextStripsMarkersButKeepsCode() {
        let text = "# Title\n**bold** and `x`\n- item\n```\ncode  \n```"
        XCTAssertEqual(ChatMarkdown.plainText(text), "Title\nbold and x\n• item\ncode  ")
    }

    func testFoldingThresholds() {
        let lines = { (n: Int) in Array(repeating: "line", count: n).joined(separator: "\n") }
        XCTAssertTrue(ChatMarkdown.isLong(lines(31)))
        XCTAssertFalse(ChatMarkdown.isLong(lines(30)))
        XCTAssertTrue(ChatMarkdown.isLong(String(repeating: "x", count: 2001)))
        XCTAssertEqual(ChatMarkdown.preview(lines(40)).components(separatedBy: "\n").count, 20)
    }

    func testPreviewNeverCutsACodeBlock() {
        let prose = (1...15).map { "line \($0)" }.joined(separator: "\n")
        let code = (1...20).map { "echo \($0)" }.joined(separator: "\n")
        let preview = ChatMarkdown.preview(prose + "\n```sh\n" + code + "\n```\nafter")
        XCTAssertFalse(ChatMarkdown.blocks(preview).contains { if case .code = $0 { return true } else { return false } })
        XCTAssertTrue(preview.hasSuffix("line 15"))
    }

    func testPreviewKeepsAWholeCodeBlockThatStartsTheReply() {
        let code = (1...25).map { "echo \($0)" }.joined(separator: "\n")
        let text = "```sh\n" + code + "\n```\n" + (1...20).map { "tail \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ChatMarkdown.blocks(ChatMarkdown.preview(text)).first, .code(language: "sh", code: code))
    }
}
