import XCTest
@testable import AISessionCore

final class TmuxCommandBuilderTests: XCTestCase {
    func testEnsureTmuxInstalledCheck() {
        let cmd = TmuxCommandBuilder.ensureTmuxInstalledCheck()
        XCTAssertTrue(cmd.contains("command -v tmux"))
        XCTAssertTrue(cmd.contains("/opt/homebrew/bin"))
        XCTAssertTrue(cmd.contains("$HOME/.local/bin"))
    }

    func testListSessions() {
        let cmd = TmuxCommandBuilder.listSessions()
        // A real tab. The two-character `\t` escape is not a separator tmux or the parser honors.
        XCTAssertTrue(cmd.contains("tmux ls -F '#{session_name}\t#{session_activity}\t#{session_attached}'"))
        XCTAssertFalse(cmd.contains("\\t"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testAttach() {
        let cmd = TmuxCommandBuilder.attach(tmuxName: "ai/claude/app")
        // `-u` is before the subcommand: `tmux attach -u` is not the client flag.
        XCTAssertTrue(cmd.contains("tmux -u attach -t 'ai/claude/app'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    /// tmux replaces Cyrillic and other non-ASCII with `_` unless the client
    /// locale contains UTF-8 (or `-u` is set). Non-login SSH execs have neither
    /// until this prefix runs. An existing UTF-8 locale is left alone.
    func testWrapForcesUtf8LocaleWhenMissing() {
        let cmd = TmuxCommandBuilder.listSessions()
        XCTAssertTrue(cmd.contains("en_US.UTF-8"))
        XCTAssertTrue(cmd.contains("LC_ALL"))
        XCTAssertTrue(cmd.contains("*[Uu][Tt][Ff]-8*"))
    }

    /// `LC_ALL` overrides `LANG`. A UTF-8 `LANG` must not hide `LC_ALL=C`, or
    /// tmux still draws Cyrillic as underscores.
    func testWrapReplacesLcAllCWhenLangIsAlreadyUtf8() throws {
        #if os(macOS)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let locale = try localeAfterWrap(shell: shell, lcAll: "C", lang: "en_US.UTF-8")
            XCTAssertEqual(locale.lcAll, "en_US.UTF-8", shell)
            XCTAssertEqual(locale.lcCtype, "en_US.UTF-8", shell)
            XCTAssertEqual(locale.lang, "en_US.UTF-8", shell)
        }
        #endif
    }

    /// A UTF-8 `LC_ALL` already wins, including one that is not `en_US`.
    func testWrapLeavesUtf8LcAllUntouched() throws {
        #if os(macOS)
        let locale = try localeAfterWrap(shell: "/bin/sh", lcAll: "bg_BG.UTF-8", lang: "C")
        XCTAssertEqual(locale.lcAll, "bg_BG.UTF-8")
        XCTAssertEqual(locale.lang, "C")
        #endif
    }

    /// With `LC_ALL` unset, a UTF-8 `LANG` is the locale tmux will use.
    func testWrapLeavesUtf8LangWhenLcAllIsUnset() throws {
        #if os(macOS)
        let locale = try localeAfterWrap(shell: "/bin/sh", lang: "bg_BG.UTF-8")
        XCTAssertEqual(locale.lcAll, "")
        XCTAssertEqual(locale.lcCtype, "")
        XCTAssertEqual(locale.lang, "bg_BG.UTF-8")
        #endif
    }

    func testWrapForcesUtf8WhenNoLocaleIsSet() throws {
        #if os(macOS)
        let locale = try localeAfterWrap(shell: "/bin/sh")
        XCTAssertEqual(locale.lcAll, "en_US.UTF-8")
        XCTAssertEqual(locale.lcCtype, "en_US.UTF-8")
        XCTAssertEqual(locale.lang, "en_US.UTF-8")
        #endif
    }

    /// Runs the locale prefix `wrap` puts in front of every remote command.
    private func localeAfterWrap(
        shell: String,
        lcAll: String? = nil,
        lcCtype: String? = nil,
        lang: String? = nil
    ) throws -> (lcAll: String, lcCtype: String, lang: String) {
        let command = TmuxCommandBuilder.listSessions()
        guard let tmux = command.range(of: "; tmux ") else {
            XCTFail("wrapped command has no tmux payload")
            return ("", "", "")
        }
        let script = String(command[..<tmux.lowerBound])
            + #"; printf '%s\n%s\n%s' "${LC_ALL-}" "${LC_CTYPE-}" "${LANG-}""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        var environment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]
        if let lcAll { environment["LC_ALL"] = lcAll }
        if let lcCtype { environment["LC_CTYPE"] = lcCtype }
        if let lang { environment["LANG"] = lang }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, shell)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(lines.count, 3, "\(shell): \(String(decoding: data, as: UTF8.self))")
        return (lines[0], lines[1], lines[2])
    }

    func testKillSession() {
        let cmd = TmuxCommandBuilder.killSession(tmuxName: "random")
        XCTAssertTrue(cmd.contains("tmux kill-session -t 'random'"))
        XCTAssertTrue(cmd.hasPrefix("export PATH="))
    }

    func testProbeBinaries() {
        let cmd = TmuxCommandBuilder.probeBinaries()
        XCTAssertTrue(cmd.contains("command -v tmux"))
        XCTAssertTrue(cmd.contains("command -v bash"))
        XCTAssertTrue(cmd.contains("claude:%s"))
    }

    func testShellQuoteEscapesApostrophe() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuote("it's"), "'it'\"'\"'s'")
    }

    func testListSessionsWithStatusesEmitsMarkerAndPreservesLsExitCode() {
        let command = TmuxCommandBuilder.listSessionsWithStatuses()
        XCTAssertTrue(command.contains("tmux ls -F '#{session_name}\t#{session_activity}\t#{session_attached}'"))
        XCTAssertFalse(command.contains("\\t"))
        XCTAssertTrue(command.contains("echo '\(RemoteScriptOutput.statusMarker)'"))
        // The script must exit with tmux ls's status so isNoServerError still fires.
        XCTAssertTrue(command.contains("exit $ls_exit"))
    }

    /// zsh (unlike bash) errors on unmatched globs by default — `for f in …/*.json` with an
    /// empty status directory becomes `zsh: no matches found` and aborts the whole list script
    /// before `exit $ls_exit`, which SessionService surfaces as "Could not load sessions".
    /// The dump must opt into null-glob behaviour (and keep the `[ -f` guard for shells that
    /// leave the literal pattern when nullglob is unavailable).
    func testListSessionsWithStatusesSurvivesEmptyStatusDirectoryOnZsh() {
        let command = TmuxCommandBuilder.listSessionsWithStatuses()
        XCTAssertTrue(
            command.contains("setopt NULL_GLOB") || command.contains("nullglob"),
            "status dump must disable zsh nomatch / enable nullglob before expanding *.json"
        )
        XCTAssertTrue(command.contains("[ -f \"$f\" ]"), "keep the exists-guard for bash/sh literal globs")
    }

    func testCreateSessionScriptUsesExitNinetyForMissingBinary() throws {
        // SessionName.init(tool:slug:) is failable, not throwing.
        let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "/tmp/demo", binary: "claude", metadataTemplate: "{\"cli\":[\"%s\"]}"
        )
        XCTAssertTrue(command.contains("command -v 'claude'"))
        XCTAssertTrue(command.contains("|| exit 90"))
        // exec so tmux's own exit code and stderr reach the client for duplicate detection.
        XCTAssertTrue(command.contains("exec tmux new-session -d -s 'ai/claude/demo'"))
        XCTAssertTrue(command.contains("-- \"$p\""))
    }

    func testCreateSessionScriptQuotesTemplateContainingSingleQuote() throws {
        let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "/tmp", binary: "claude", metadataTemplate: "{\"title\":\"it's\"}"
        )
        // shellQuote's '"'"' escape must appear so the quote cannot terminate the literal early.
        XCTAssertTrue(command.contains("'\"'\"'"))
    }

    func testCodexSessionsUseAutomaticReviewWithTheWorkspaceSandbox() throws {
        let name = try XCTUnwrap(SessionName(tool: .codex, slug: "demo"))
        let template = try SessionMetadata.printfTemplate(
            tool: .codex, cwd: "/tmp", title: "Demo", startedAt: Date(timeIntervalSince1970: 0)
        )
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "/tmp", binary: "/custom/codex", metadataTemplate: template
        )
        XCTAssertTrue(command.contains("command -v '/custom/codex'"))
        XCTAssertTrue(command.hasSuffix("-- \"$p\" '--approve-for-me'"))
        XCTAssertTrue(template.contains("\"cli\":[\"%s\",\"--approve-for-me\"]"))
        XCTAssertFalse(command.contains("danger-full-access"))
        XCTAssertFalse(command.contains("dangerously-bypass"))
    }

    func testShellQuotePathExpandsBareTilde() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~"), "\"$HOME\"")
    }

    func testShellQuotePathExpandsTildeSlashAndQuotesTheRest() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~/"), "\"$HOME\"/")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~/programming"), "\"$HOME\"/'programming'")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~/a b"), "\"$HOME\"/'a b'")
    }

    func testShellQuotePathHandlesAbsolutePathsAndApostrophes() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("/tmp/demo"), "'/tmp/demo'")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("/tmp/it's"), "'/tmp/it'\"'\"'s'")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~/it's"), "\"$HOME\"/'it'\"'\"'s'")
    }

    /// `~user` is left unexpanded, like `ai-todo-open` does: it is quoted whole and reaches tmux
    /// as a literal directory name. So is a `~` anywhere but the start.
    func testShellQuotePathLeavesTildeUserAndInnerTildeLiteral() {
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~root"), "'~root'")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("~root/x"), "'~root/x'")
        XCTAssertEqual(TmuxCommandBuilder.shellQuotePath("/tmp/~/x"), "'/tmp/~/x'")
    }

    /// End-to-end guard: what each shell an SSH login might use makes of the quoted path,
    /// with a fake `$HOME` (never the real one).
    func testShellQuotePathEvaluatesToExpectedPathInShells() throws {
        #if os(macOS)
        let home = "/fake home/user"
        let cases: [(String, String)] = [
            ("~", home),
            ("~/x", home + "/x"),
            ("~/a b", home + "/a b"),
            ("/abs/path", "/abs/path"),
            ("~/it's $HOME `x`", home + "/it's $HOME `x`"),
            ("/tmp/it's", "/tmp/it's"),
            ("~root/x", "~root/x"),
        ]
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            for (input, expected) in cases {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", "printf '%s' \(TmuxCommandBuilder.shellQuotePath(input))"]
                process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(String(decoding: data, as: UTF8.self), expected, "\(shell): \(input)")
            }
        }
        #endif
    }

    func testCreateSessionExpandsTildeCwdOnTheHost() throws {
        let name = try XCTUnwrap(SessionName(tool: .claude, slug: "demo"))
        let command = TmuxCommandBuilder.createSession(
            name: name, cwd: "~/programming", binary: "claude", metadataTemplate: "{}"
        )
        XCTAssertTrue(command.contains("-c \"$HOME\"/'programming' --"), command)
    }

    func testPromoteSessionScriptMergesRenameAndMetadata() {
        let command = TmuxCommandBuilder.promoteSession(
            fromTmuxName: "old", toTmuxName: "ai/claude/demo", json: "{}"
        )
        XCTAssertTrue(command.contains("tmux rename-session -t 'old' 'ai/claude/demo'"))
        XCTAssertTrue(command.contains("printf '%s'"))
        XCTAssertTrue(command.contains("ai__claude__demo.json"))
    }
}

#if os(macOS)
final class WrapPathTests: XCTestCase {
    /// On macOS `/home` is an automount: a PATH entry there made every command lookup that
    /// reached it a directory-service round trip.
    func testWrappedPathHasHomebrewAndNothingUnderHome() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", TmuxCommandBuilder.wrap(#"printf '%s' "$PATH""#)]
        process.environment = ["HOME": "/tmp", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let dirs = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.first, "/opt/homebrew/bin")
        XCTAssertTrue(dirs.contains("/usr/bin"))
        XCTAssertFalse(dirs.contains { $0.hasPrefix("/home/") }, "\(dirs)")
    }
}
#endif

#if os(macOS)
/// Runs the duplicate's transcript and summary commands in `/bin/sh` against stand-ins for
/// the helper, `python3` and `claude` under a temporary HOME, so each failure has its own code.
final class TranscriptCommandTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        // The wrap PATH puts these first; a real python3 or claude there would shadow the stand-ins.
        for dir in ["/opt/homebrew/bin", "/home/linuxbrew/.linuxbrew/bin", "/usr/local/bin"] {
            for binary in ["python3", "claude"] where FileManager.default.fileExists(atPath: "\(dir)/\(binary)") {
                throw XCTSkip("\(dir)/\(binary) would shadow the test's stand-in")
            }
        }
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private var bin: URL { home.appendingPathComponent(".local/bin") }
    private var helperDir: URL { home.appendingPathComponent(".ai-remote/bin") }

    private func write(_ body: String, to url: URL) throws {
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func helper(_ body: String) throws { try write(body, to: helperDir.appendingPathComponent("ai-todo-transcript")) }
    private func python3() throws { try write("exit 0", to: bin.appendingPathComponent("python3")) }
    private func claude() throws { try write("/bin/cat > \"$HOME/claude.in\"; echo summary", to: bin.appendingPathComponent("claude")) }

    private func run(_ command: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // No /usr/bin: the system python3 stub would always be found.
        process.environment = ["HOME": home.path, "PATH": bin.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }

    private let transcript = TmuxCommandBuilder.conversationTranscript(tool: "cursor", sessionId: "abc")
    private let summary = TmuxCommandBuilder.summarizeConversation(tool: "cursor", sessionId: "abc")

    func testMissingHelperIsScriptMissing() throws {
        try python3()
        try claude()
        XCTAssertEqual(try run(transcript).status, TmuxCommandBuilder.scriptMissingExitCode)
        XCTAssertEqual(try run(summary).status, TmuxCommandBuilder.scriptMissingExitCode)
    }

    func testMissingPython3IsNamed() throws {
        try helper("echo text")
        try claude()
        for command in [transcript, summary] {
            let result = try run(command)
            XCTAssertEqual(result.status, TmuxCommandBuilder.binaryMissingExitCode)
            XCTAssertTrue(result.stderr.contains("python3 not found"), result.stderr)
        }
    }

    func testMissingClaudeIsNamedForTheSummary() throws {
        try helper("echo text")
        try python3()
        let result = try run(summary)
        XCTAssertEqual(result.status, TmuxCommandBuilder.binaryMissingExitCode)
        XCTAssertTrue(result.stderr.contains("claude not found"), result.stderr)
    }

    func testNoTranscriptStopsTheSummaryBeforeClaude() throws {
        try helper("echo 'no text' >&2; exit 94")
        try python3()
        try claude()
        XCTAssertEqual(try run(summary).status, TmuxCommandBuilder.noTranscriptExitCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("claude.in").path))
    }

    func testSummaryHandsTheTranscriptToClaude() throws {
        try helper("printf 'it'\"'\"'s $HOME\\n'; echo \"$1 $2\"")
        try python3()
        try claude()
        let result = try run(summary)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "summary\n")
        let input = try String(contentsOf: home.appendingPathComponent("claude.in"), encoding: .utf8)
        XCTAssertTrue(input.hasPrefix("Summarize this conversation"), input)
        XCTAssertTrue(input.contains("it's $HOME\ncursor abc\n"), input)
    }

    func testTranscriptPrintsTheHelperOutput() throws {
        try helper("echo \"$1 $2\"")
        try python3()
        let result = try run(transcript)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "cursor abc\n")
    }

    func testChatRequestsStructuredTranscript() throws {
        try helper("printf '%s\\n' \"$@\"")
        try python3()
        let result = try run(TmuxCommandBuilder.conversationTranscript(tool: "codex", sessionId: "abc", json: true))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "codex\nabc\n--json\n")
    }
}
#endif
