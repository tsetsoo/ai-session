import XCTest
@testable import AISessionCore

/// An added agent's hand-off (summary, transcript or first message) reaches it as its first
/// prompt: written to a private file on the computer, passed with `ai-todo-open --prompt-file`.
final class HandoffPromptTests: XCTestCase {
    func testWritePromptFileDecodesTheTextIntoAPrivateFile() {
        let text = "Line 1\nIt's \"quoted\""
        let command = TmuxCommandBuilder.writePromptFile(text: text)
        let encoded = Data(text.utf8).base64EncodedString()
        XCTAssertTrue(command.contains("umask 077"), command)
        XCTAssertTrue(command.contains("mktemp \"$HOME/.ai-remote/prompts/handoff.XXXXXX\""), command)
        XCTAssertTrue(command.contains("'\(encoded)'"), command)
        XCTAssertTrue(command.contains("base64 --decode"), command)
        XCTAssertFalse(command.contains("Line 1"), "the text itself must not be in the command")
    }

    func testOpenPassesThePromptFileBeforeTheTmuxName() {
        let command = TmuxCommandBuilder.openTodoConversation(
            tmuxName: "ai/claude/todo-1", cwd: "~/x", sessionId: "s", promptFile: "/h/p", detached: true
        )
        XCTAssertTrue(
            command.contains("AI_TODO_OPEN_DETACH=1 exec \"$HOME/.ai-remote/bin/ai-todo-open\" --prompt-file '/h/p' 'ai/claude/todo-1'"),
            command
        )
        XCTAssertEqual(
            TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s"),
            TmuxCommandBuilder.openTodoConversation(tmuxName: "n", cwd: "~/x", sessionId: "s", promptFile: nil, detached: false)
        )
    }

    func testFreshStartPassesThePromptFile() {
        let command = TmuxCommandBuilder.freshTodoConversation(
            tmuxName: "ai/codex/todo-1", cwd: "~/x", tool: "codex", worktree: ("~/w", "ai/b"), promptFile: "/h/p"
        )
        XCTAssertTrue(command.contains("--worktree '~/w' 'ai/b' --prompt-file '/h/p' 'ai/codex/todo-1'"), command)
    }

    /// Cursor's `ai-todo-open` path has no first prompt: its hand-off is still pasted.
    func testOnlyClaudeAndCodexTakeAFirstPrompt() {
        XCTAssertTrue(TmuxCommandBuilder.takesFirstPrompt(tool: "claude"))
        XCTAssertTrue(TmuxCommandBuilder.takesFirstPrompt(tool: "codex"))
        XCTAssertFalse(TmuxCommandBuilder.takesFirstPrompt(tool: "cursor"))
    }

    func testStartPlansGoInAsTheFirstPromptForClaudeAndCodex() {
        let start = DuplicateHandoff.Plan.start(text: "Summary", label: "copy")
        XCTAssertEqual(DuplicateHandoff.firstPrompt(start, tool: "claude"), "Summary")
        XCTAssertEqual(DuplicateHandoff.firstPrompt(start, tool: "codex"), "Summary")
        XCTAssertNil(DuplicateHandoff.firstPrompt(start, tool: "cursor"), "cursor's hand-off is still pasted")
        XCTAssertNil(DuplicateHandoff.firstPrompt(.fork(sourceSessionId: "s", label: "copy"), tool: "claude"))
        XCTAssertNil(DuplicateHandoff.firstPrompt(.start(text: "  \n", label: "copy"), tool: "claude"))
        XCTAssertNil(DuplicateHandoff.firstPrompt(.cancelled, tool: "claude"))
    }

    #if os(macOS)
    /// Run for real: the file holds the text exactly, private to the user.
    func testWritePromptFileWritesTheTextExactly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let text = "Summary: fix the login.\n- it's \"quoted\"\n- $HOME and `ticks`\nкирилица"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", TmuxCommandBuilder.writePromptFile(text: text)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasPrefix(home.path + "/.ai-remote/prompts/handoff."), path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    #endif
}
