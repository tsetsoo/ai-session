import Foundation
import Testing
@testable import AISessionCore

@Suite("Review: diff, anchors, message, commands")
struct ReviewTests {
    static let patch = """
    diff --git a/src/app.rs b/src/app.rs
    index 1111111..2222222 100644
    --- a/src/app.rs
    +++ b/src/app.rs
    @@ -1,5 +1,6 @@ fn main()
     use std::io;
    -let a = 1;
    +let a = 2;
    +let b = 3;
     fn main() {

     }
    diff --git a/docs/my notes.md b/docs/my notes.md
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/docs/my notes.md\t
    @@ -0,0 +1 @@
    +hello
    \\ No newline at end of file
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    index 4444444..0000000
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/a.txt b/b.txt
    similarity index 90%
    rename from a.txt
    rename to b.txt
    diff --git a/logo.png b/logo.png
    index 5555555..6666666 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git "a/tab\\there.txt" "b/tab\\there.txt"
    index 7777777..8888888 100644
    --- "a/tab\\there.txt"
    +++ "b/tab\\there.txt"
    @@ -1 +1 @@
    -x
    +y

    """

    @Test func parsesFilesAndLineNumbers() {
        let diff = UnifiedDiff(parsing: Self.patch)
        #expect(diff.files.map(\.path) == ["src/app.rs", "docs/my notes.md", "old.txt", "b.txt", "logo.png", "tab\there.txt"])
        #expect(diff.files.map(\.change) == [.modified, .added, .deleted, .renamed, .modified, .modified])

        let app = diff.files[0]
        #expect(app.additions == 2 && app.deletions == 1)
        #expect(app.hunks.count == 1)
        #expect(app.hunks[0].section == "fn main()")
        let lines = app.hunks[0].lines
        #expect(lines.count == 7)
        #expect(lines[1] == DiffLine(kind: .removed, text: "let a = 1;", oldLine: 2, newLine: nil))
        #expect(lines[3] == DiffLine(kind: .added, text: "let b = 3;", oldLine: nil, newLine: 3))
        // The blank context line lost its leading space and is still a line of the hunk.
        #expect(lines[5] == DiffLine(kind: .context, text: "", oldLine: 4, newLine: 5))
        #expect(lines[6] == DiffLine(kind: .context, text: "}", oldLine: 5, newLine: 6))

        #expect(diff.files[1].oldPath == nil)
        #expect(diff.files[1].hunks[0].lines.last?.kind == .noNewline)
        #expect(diff.files[2].newPath == nil)
        #expect(diff.files[3].oldPath == "a.txt")
        #expect(diff.files[4].isBinary)
    }

    @Test func hunkHeaderDefaultsCountToOne() {
        let hunk = UnifiedDiff.hunkHeader("@@ -7 +9,0 @@")
        #expect(hunk?.oldStart == 7 && hunk?.oldCount == 1 && hunk?.newStart == 9 && hunk?.newCount == 0)
        #expect(UnifiedDiff.hunkHeader("@@ nonsense @@") == nil)
    }

    @Test func unquotesOctalUTF8() {
        #expect(UnifiedDiff.unquote(#""a/caf\303\251.txt""#) == "a/café.txt")
        #expect(UnifiedDiff.unquote("plain") == "plain")
    }

    // MARK: Anchors

    private func comment(_ start: Int?, _ end: Int? = nil, path: String = "f.txt", side: DiffSide = .new) -> ReviewComment {
        ReviewComment(path: path, side: side, startLine: start, endLine: end, revision: "aaa", quote: [], body: "x")
    }

    /// `ai-todo-review diff --unified 0` between the comment's revision and now.
    private let between = UnifiedDiff(parsing: """
    diff --git a/f.txt b/f.txt
    --- a/f.txt
    +++ b/f.txt
    @@ -2,0 +3,2 @@
    +new 1
    +new 2
    @@ -10 +12 @@
    -ten
    +TEN
    @@ -20,2 +21,0 @@
    -twenty
    -twenty-one
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -x
    diff --git a/a.txt b/b.txt
    rename from a.txt
    rename to b.txt

    """)

    @Test func linesShiftPastInsertionsAndRemovals() {
        #expect(ReviewAnchor.resolve(comment(1), through: between) == .moved(path: "f.txt", startLine: 1, endLine: nil))
        // Inserted after line 2: line 2 stays, line 3 moves down two.
        #expect(ReviewAnchor.resolve(comment(2), through: between) == .moved(path: "f.txt", startLine: 2, endLine: nil))
        #expect(ReviewAnchor.resolve(comment(3, 9), through: between) == .moved(path: "f.txt", startLine: 5, endLine: 11))
        #expect(ReviewAnchor.resolve(comment(11), through: between) == .moved(path: "f.txt", startLine: 13, endLine: nil))
        // After two removed lines at 20-21.
        #expect(ReviewAnchor.resolve(comment(22), through: between) == .moved(path: "f.txt", startLine: 22, endLine: nil))
    }

    @Test func changedLinesAreStale() {
        #expect(ReviewAnchor.resolve(comment(10), through: between) == .stale)
        #expect(ReviewAnchor.resolve(comment(8, 12), through: between) == .stale)
        #expect(ReviewAnchor.resolve(comment(21), through: between) == .stale)
        // Lines added between 2 and 3 land inside a 2-3 selection.
        #expect(ReviewAnchor.resolve(comment(2, 3), through: between) == .stale)
        #expect(ReviewAnchor.resolve(comment(1, path: "gone.txt"), through: between) == .stale)
        #expect(ReviewAnchor.resolve(comment(1, side: .old), through: between) == .stale)
    }

    @Test func untouchedAndRenamedFiles() {
        #expect(ReviewAnchor.resolve(comment(4, path: "other.txt"), through: between) == .moved(path: "other.txt", startLine: 4, endLine: nil))
        #expect(ReviewAnchor.resolve(comment(4, 6, path: "a.txt"), through: between) == .moved(path: "b.txt", startLine: 4, endLine: 6))
        #expect(ReviewAnchor.resolve(comment(nil, path: "f.txt"), through: between) == .moved(path: "f.txt", startLine: nil, endLine: nil))
    }

    @Test func contextLinesInsideHunksMap() {
        let diff = UnifiedDiff(parsing: Self.patch)
        // Old line 3 ("fn main() {") is context in a -1,5 +1,6 hunk: it is new line 4.
        #expect(ReviewAnchor.resolve(comment(3, path: "src/app.rs"), through: diff) == .moved(path: "src/app.rs", startLine: 4, endLine: nil))
        #expect(ReviewAnchor.resolve(comment(2, path: "src/app.rs"), through: diff) == .stale)
        // "use std::io;" then "let a": added lines sit between old 2 and 3, not between 1 and 2.
        #expect(ReviewAnchor.resolve(comment(1, path: "src/app.rs"), through: diff) == .moved(path: "src/app.rs", startLine: 1, endLine: nil))
    }

    // MARK: Message

    @Test func messageNumbersItemsAndQuotesLines() {
        let long = (1...10).map { "line \($0)" }
        let comments = [
            ReviewComment(path: "src/a.rs", startLine: 12, endLine: 14, revision: "0123456789abcdef",
                          quote: ["let a = 1;", "let b = 2;"], body: "  Use a constant.\n"),
            ReviewComment(path: "README.md", startLine: nil, endLine: nil, revision: "0123456789abcdef",
                          quote: [], body: "Mention the new flag."),
            ReviewComment(path: "src/b.rs", side: .old, startLine: 3, endLine: nil, revision: "fedcba9876543210",
                          quote: long, body: "Why was this removed?"),
        ]
        let text = ReviewMessage.render(comments, branch: "feat/x", revision: "0123456789abcdef", includesUncommitted: true)
        #expect(text == """
        Review feedback on feat/x at 01234567, including uncommitted changes (3 comments). Address each numbered item; then reply with what you changed for each number, or why you didn't.

        1. src/a.rs:12-14
        > let a = 1;
        > let b = 2;
        Use a constant.

        2. README.md (whole file)
        Mention the new flag.

        3. src/b.rs:3 (removed lines, at fedcba98)
        > line 1
        > line 2
        > line 3
        > line 4
        > line 5
        > line 6
        > line 7
        > line 8
        > …
        Why was this removed?
        """)
    }

    @Test func messageWithoutBranch() {
        let one = [ReviewComment(path: "a", startLine: 1, endLine: 1, revision: "abc", quote: [], body: "b")]
        #expect(ReviewMessage.render(one, branch: nil, revision: "abc", includesUncommitted: false)
            .hasPrefix("Review feedback at abc (1 comment)."))
    }

    // MARK: Commands

    @Test func commandsQuoteTheirArguments() {
        #expect(TmuxCommandBuilder.reviewStatus(cwd: "~/proj x").hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-review" status "$HOME"/'proj x'"#))
        #expect(TmuxCommandBuilder.reviewDiff(cwd: "/w", scope: .since, from: "abc", unified: 0)
            .hasSuffix(#"diff '/w' --scope since --from 'abc' --unified 0"#))
        #expect(TmuxCommandBuilder.reviewKeep(cwd: "/w", revision: "abc").hasSuffix("keep '/w' 'abc'"))
        let send = TmuxCommandBuilder.reviewSend(tmuxName: "ai/claude/todo-1", message: "it's $(rm -rf /)\n")
        let encoded = Data("it's $(rm -rf /)\n".utf8).base64EncodedString()
        #expect(send.hasSuffix("printf '%s' '\(encoded)' | base64 -d | \"$HOME/.ai-remote/bin/ai-todo-review\" send 'ai/claude/todo-1'"))
    }

    @Test func statusDecodesScriptOutput() throws {
        let json = #"{"root": "/w", "branch": "feat", "head": "h", "upstream": null, "ahead": null, "behind": null, "base": {"ref": "origin/main", "sha": "b"}, "revision": "r", "clean": false}"#
        let status = try JSONDecoder().decode(ReviewStatus.self, from: Data(json.utf8))
        #expect(status == ReviewStatus(root: "/w", branch: "feat", head: "h", base: .init(ref: "origin/main", sha: "b"), revision: "r", clean: false))
    }
}
