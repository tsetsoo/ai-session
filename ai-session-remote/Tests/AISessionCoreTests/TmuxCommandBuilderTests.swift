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
