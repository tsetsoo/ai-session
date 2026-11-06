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

    @Test func crlfFilesSplitIntoLines() {
        let patch = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n-a\r\n+b\r\n c\r\n"
            + "diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n@@ -1 +1 @@\n-x\n+y\n"
        let diff = UnifiedDiff(parsing: patch)
        #expect(diff.files.map(\.path) == ["w.txt", "n.txt"])
        #expect(diff.files[0].hunks[0].lines.map(\.text) == ["a", "b", "c"])
        #expect(diff.files[0].hunks[0].lines.map(\.kind) == [.removed, .added, .context])
        #expect(diff.files[1].additions == 1)
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

    @Test func messageNamesTheRevisionOfAStaleComment() {
        let stale = [ReviewComment(path: "f.swift", startLine: 40, endLine: nil, revision: "aaaaaaaa1111",
                                   quote: ["old"], body: "b")]
        #expect(ReviewMessage.render(stale, branch: nil, revision: "bbbbbbbb2222", includesUncommitted: false)
            .contains("1. f.swift:40 (at aaaaaaaa; these lines have changed since)"))
        #expect(ReviewMessage.render(stale, branch: nil, revision: "bbbbbbbb2222", includesUncommitted: false,
                                     unchecked: [stale[0].id])
            .contains("1. f.swift:40 (at aaaaaaaa; not checked against the current code)"))
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
        #expect(send.hasSuffix("printf '%s' '\(encoded)' | \"$HOME/.ai-remote/bin/ai-todo-review\" send --base64 'ai/claude/todo-1'"))
    }

    @Test func scopesFromACommitAskTheScriptForSince() {
        #expect(TmuxCommandBuilder.reviewDiff(cwd: "/w", scope: .conversation, from: "abc").contains("--scope since --from 'abc'"))
        #expect(TmuxCommandBuilder.reviewDiff(cwd: "/w", scope: .commit, from: "abc").contains("--scope since --from 'abc'"))
        #expect(TmuxCommandBuilder.reviewDiff(cwd: "/w", scope: .branch).contains("--scope branch"))
        #expect(TmuxCommandBuilder.reviewLog(cwd: "/w", before: "2026-11-06T10:00:00Z")
            .hasSuffix("log '/w' --limit 30 --before '2026-11-06T10:00:00Z'"))
        #expect(!ReviewScope.segments.contains(.commit))
    }

    @Test func refIsPassedToEveryRead() {
        #expect(TmuxCommandBuilder.reviewStatus(cwd: "/p", ref: "ai/x-1").hasSuffix("status '/p' --ref 'ai/x-1'"))
        #expect(TmuxCommandBuilder.reviewDiff(cwd: "/p", scope: .branch, ref: "ai/x-1").hasSuffix("--scope branch --ref 'ai/x-1'"))
        #expect(TmuxCommandBuilder.reviewLog(cwd: "/p", ref: "ai/x-1").hasSuffix("--limit 30 --ref 'ai/x-1'"))
        #expect(!TmuxCommandBuilder.reviewStatus(cwd: "/p").contains("--ref"))
    }

    @Test func statusDecodesWorktreeBase() throws {
        let json = #"{"root": "/w", "branch": "b", "head": "h", "revision": "h", "clean": true, "worktree_base": "w0", "ref": null}"#
        let status = try JSONDecoder().decode(ReviewStatus.self, from: Data(json.utf8))
        #expect(status.worktreeBase == "w0" && status.ref == nil)
    }

    @Test func logDecodesScriptOutput() throws {
        let json = #"{"commits": [{"sha": "a", "subject": "s", "date": "2026-11-06T19:19:30+02:00", "pushed": null}], "before": null}"#
        let log = try JSONDecoder().decode(ReviewLog.self, from: Data(json.utf8))
        #expect(log == ReviewLog(commits: [.init(sha: "a", subject: "s", date: "2026-11-06T19:19:30+02:00", pushed: nil)], before: nil))
    }

    @Test func statusDecodesScriptOutput() throws {
        let json = #"{"root": "/w", "branch": "feat", "head": "h", "upstream": null, "ahead": null, "behind": null, "base": {"ref": "origin/main", "sha": "b"}, "revision": "r", "clean": false}"#
        let status = try JSONDecoder().decode(ReviewStatus.self, from: Data(json.utf8))
        #expect(status == ReviewStatus(root: "/w", branch: "feat", head: "h", base: .init(ref: "origin/main", sha: "b"), revision: "r", clean: false))
    }

    // MARK: Reviewer findings

    static let runJSON = #"""
    {"id": "r1", "state": "done", "error": null, "result": {"tool": "claude", "model": "claude-big", "from": "f0", "to": "t1",
     "summary": "Fine.", "usage": {"input_tokens": 10, "output_tokens": 2500, "cache_read_tokens": 1000, "cache_write_tokens": null, "cost_usd": 0.42},
     "findings": [
      {"path": "src/a.rs", "side": "new", "line_start": 3, "line_end": 3, "severity": "high", "category": "correctness",
       "title": "Off by one", "body": "Use <=.", "quote": ["x < n"], "fingerprint": "fp1"},
      {"path": "src/a.rs", "side": "old", "line_start": 7, "line_end": 9, "severity": "low", "category": "tests",
       "title": "Test removed", "body": "Keep it.", "quote": ["a", "b", "c"], "fingerprint": "fp2"},
      {"path": "README.md", "side": "new", "line_start": null, "line_end": null, "severity": "medium", "category": "docs",
       "title": "Docs", "body": "Mention it.", "quote": [], "fingerprint": "fp3"}]}}
    """#

    @Test func runResultDecodesAndBecomesComments() throws {
        let state = try JSONDecoder().decode(ReviewRunResult.self, from: Data(Self.runJSON.utf8))
        let output = try #require(state.result)
        #expect(state.state == .done && output.usage?.summary == "1.0k in · 2.5k out · $0.42")
        let run = UUID()
        // fp2 was dismissed before: a later review doesn't bring it back.
        let dismissed = ReviewComment(author: "reviewer:codex", path: "src/a.rs", startLine: 1, endLine: nil, revision: "t0",
                                      quote: [], body: "x", state: .dismissed, fingerprint: "fp2")
        let added = ReviewFindings.comments(from: output, runID: run, existing: [dismissed])
        #expect(added.map(\.fingerprint) == ["fp1", "fp3"])
        let first = added[0]
        #expect(first.author == "reviewer:claude" && first.reviewer == "claude" && first.state == .new)
        #expect(first.revision == "t1" && first.startLine == 3 && first.endLine == nil && first.runID == run)
        #expect(first.title == "Off by one" && first.severity == "high" && first.quote == ["x < n"])
        #expect(added[1].startLine == nil && added[1].endLine == nil)
        // Removed lines are in the older revision.
        let old = ReviewFindings.comments(from: output, runID: run, existing: [])[1]
        #expect(old.side == .old && old.revision == "f0" && old.endLine == 9)
        #expect(ReviewComment(path: "a", startLine: 1, endLine: nil, revision: "r", quote: [], body: "b").reviewer == nil)
    }

    @Test func recordsWithoutRunsStillDecode() throws {
        let json = #"{"comments": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "author": "user", "path": "a", "side": "new", "startLine": 1, "revision": "r", "quote": [], "body": "b", "state": "draft", "createdAt": 0}], "batches": []}"#
        let record = try JSONDecoder().decode(ReviewRecord.self, from: Data(json.utf8))
        #expect(record.runs.isEmpty && record.comments.count == 1 && record.comments[0].fingerprint == nil)
        let again = try JSONDecoder().decode(ReviewRecord.self, from: try JSONEncoder().encode(record))
        #expect(again == record)
    }

    @Test func aPassedOnFindingCarriesItsTitle() {
        let finding = ReviewComment(author: "reviewer:claude", path: "a.rs", startLine: 2, endLine: nil, revision: "r1",
                                    quote: ["x"], body: "Use <=.", severity: "high", title: "Off by one")
        let message = ReviewMessage.render([finding], branch: nil, revision: "r1", includesUncommitted: false)
        #expect(message.hasSuffix("1. a.rs:2\n> x\n[high] Off by one\nUse <=."), "\(message)")
    }

    @Test func reviewRunCommands() {
        let plain = TmuxCommandBuilder.reviewRun(cwd: "~/w", from: "a", to: "b", tool: "claude", id: "r-1")
        #expect(plain.hasSuffix(#"exec "$HOME/.ai-remote/bin/ai-todo-review" run "$HOME"/'w' --from 'a' --to 'b' --tool 'claude' --id 'r-1' </dev/null"#), "\(plain)")
        let full = TmuxCommandBuilder.reviewRun(cwd: "/p", from: "a", to: "b", tool: "codex", id: "r-2", ref: "ai/x",
                                                model: "m", context: ["docs/x.md"], brief: "Fix 'it'")
        let encoded = Data("Fix 'it'".utf8).base64EncodedString()
        #expect(full.contains("printf '%s' '\(encoded)' | "), "\(full)")
        #expect(full.hasSuffix("--tool 'codex' --id 'r-2' --ref 'ai/x' --model 'm' --context 'docs/x.md' --brief-base64"), "\(full)")
        #expect(TmuxCommandBuilder.reviewResult(id: "r-1").hasSuffix("result 'r-1'"))
        #expect(TmuxCommandBuilder.reviewCancel(id: "r-1").hasSuffix("cancel 'r-1'"))
    }
}
