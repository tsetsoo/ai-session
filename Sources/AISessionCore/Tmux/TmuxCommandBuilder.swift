public enum TmuxCommandBuilder {
    /// Non-interactive SSH sessions often omit Homebrew paths that login shells have
    /// (e.g. `/opt/homebrew/bin` on Apple Silicon). Prefix every remote command so
    /// `tmux` / `claude` / `codex` / `agent` resolve the same way as in a normal terminal.
    private static let pathExport =
        #"export PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH""#

    public static func ensureTmuxInstalledCheck() -> String {
        wrap("command -v tmux")
    }

    public static func listSessions() -> String {
        wrap("tmux ls -F '#{session_name}\\t#{session_activity}\\t#{session_attached}'")
    }

    public static func attach(tmuxName: String) -> String {
        wrap("tmux attach -t \(shellQuote(tmuxName))")
    }

    public static func killSession(tmuxName: String) -> String {
        wrap("tmux kill-session -t \(shellQuote(tmuxName))")
    }

    /// Kills exactly `tmuxName` (the `=` target prefix disables tmux's prefix matching, so
    /// `todo-0f3a9c21` can't hit `todo-0f3a9c21-…`). Exit status 1 when it is already gone.
    public static func killSessionExact(tmuxName: String) -> String {
        wrap("tmux kill-session -t \(shellQuote("=" + tmuxName))")
    }

    /// PTY command for a todo's conversation: the host-side `ai-todo-open` script attaches to
    /// the tmux session, or creates/resumes the conversation (`claude` or `codex`) if tmux is
    /// gone. `cwd` may start with `~`; the script expands it.
    ///
    /// The tool is passed as a 4th argument only when it isn't `claude`: scripts installed
    /// before Codex support reject a 4th argument, and `claude` is their default anyway.
    public static func openTodoConversation(tmuxName: String, cwd: String, sessionId: String, tool: String = "claude") -> String {
        var command = "exec \"$HOME/.ai-remote/bin/ai-todo-open\" \(shellQuote(tmuxName)) \(shellQuote(cwd)) \(shellQuote(sessionId))"
        if tool != "claude" { command += " \(shellQuote(tool))" }
        return wrap(command)
    }

    /// Exit status when the host-side scripts aren't installed (`command not found`).
    public static let scriptMissingExitCode: Int32 = 127

    /// Lists the computer's Claude / Codex conversations as JSON (`[RemoteConversation]`).
    public static func listRemoteConversations(limit: Int = 200) -> String {
        wrap("\"$HOME/.ai-remote/bin/ai-todo-sessions\" list --json --limit \(max(1, limit))")
    }

    /// Deletes a conversation on the computer (Claude: its files; Codex: `codex archive`) in
    /// one exec: the script ends the todo's tmux session, waits up to `waitSeconds` for the
    /// conversation to stop, then deletes it. A conversation that doesn't exist counts as
    /// already gone (exit 0). It refuses (65) while something else still runs it. If the
    /// script is missing (127) nothing is killed.
    public static func deleteRemoteConversation(
        tool: String,
        sessionId: String,
        tmuxName: String,
        waitSeconds: Int = 10
    ) -> String {
        wrap(
            "\"$HOME/.ai-remote/bin/ai-todo-sessions\" delete \(shellQuote(tool)) \(shellQuote(sessionId))"
                + " --kill-tmux \(shellQuote(tmuxName)) --wait \(max(0, waitSeconds)) --missing-ok"
        )
    }

    public static func probeBinaries() -> String {
        wrap(
            """
            printf 'tmux:%s\\n' "$(command -v tmux || echo MISSING)"; printf 'claude:%s\\n' "$(command -v claude || echo MISSING)"; printf 'codex:%s\\n' "$(command -v codex || echo MISSING)"; printf 'agent:%s\\n' "$(command -v agent || echo MISSING)"; printf 'bash:%s\\n' "$(command -v bash || echo MISSING)"
            """
        )
    }

    /// `tmux ls` and the agent-status dump in one round trip.
    ///
    /// The script exits with `tmux ls`'s own status and leaves its stderr untouched — SSH
    /// carries stderr separately — so `SessionService`'s no-server detection is unchanged.
    /// The status dump only runs when `ls` succeeded, and its own failure is ignored because
    /// agent statuses are supplemental.
    public static func listSessionsWithStatuses() -> String {
        wrap(
            """
            tmux ls -F '#{session_name}\\t#{session_activity}\\t#{session_attached}'; ls_exit=$?
            echo '\(RemoteScriptOutput.statusMarker)'
            if [ $ls_exit -eq 0 ]; then mkdir -p ~/.ai-remote/status; setopt NULL_GLOB 2>/dev/null || true; shopt -s nullglob 2>/dev/null || true; for f in ~/.ai-remote/status/*.json; do [ -f "$f" ] && echo "---$(basename "$f")---" && cat "$f"; done; fi
            exit $ls_exit
            """
        )
    }

    /// Resolve the CLI, write metadata, and start the detached session in one round trip.
    ///
    /// `metadataTemplate` is a `printf` format string with a single `%s` slot for the resolved
    /// binary path (see `SessionMetadata.printfTemplate`), because that path is only known here
    /// on the host. The script ends in `exec` so the result's exit code and stderr are tmux's
    /// own, keeping duplicate-name detection working.
    ///
    /// `cwd` may start with `~`, as typed in the app; see
    /// `shellQuotePath` for how it reaches tmux.
    ///
    /// Exit codes: 90 CLI missing, 91 metadata directory failed, 92 metadata write failed.
    public static func createSession(
        name: SessionName,
        cwd: String,
        binary: String,
        metadataTemplate: String
    ) -> String {
        let file = SessionMetadataStore.filename(for: name.tmuxName)
        return wrap(
            """
            p=$(command -v \(shellQuote(binary))) || exit 90
            mkdir -p ~/.ai-remote/sessions || exit 91
            printf \(shellQuote(metadataTemplate)) "$p" > ~/.ai-remote/sessions/\(shellQuote(file)) || exit 92
            exec tmux new-session -d -s \(shellQuote(name.tmuxName)) -c \(shellQuotePath(cwd)) -- "$p"
            """
        )
    }

    /// Rename a session and write its metadata in one round trip. The metadata JSON is passed
    /// as a `printf '%s'` argument rather than a format string, so no escaping is needed.
    public static func promoteSession(
        fromTmuxName: String,
        toTmuxName: String,
        json: String
    ) -> String {
        let file = SessionMetadataStore.filename(for: toTmuxName)
        return wrap(
            """
            tmux rename-session -t \(shellQuote(fromTmuxName)) \(shellQuote(toTmuxName)) || exit $?
            mkdir -p ~/.ai-remote/sessions || exit 91
            printf '%s' \(shellQuote(json)) > ~/.ai-remote/sessions/\(shellQuote(file)) || exit 92
            """
        )
    }

    static func wrap(_ command: String) -> String {
        "\(pathExport); \(command)"
    }

    /// Like `shellQuote`, but a leading `~` or `~/` becomes `"$HOME"` so it expands on the host
    /// (never on the phone or Mac). The rest of the path stays single-quoted, so spaces and
    /// quotes are as safe as in any other argument. Matches `ai-todo-open`: `~user` forms are
    /// not expanded and are passed through quoted, i.e. as a literal directory name.
    static func shellQuotePath(_ value: String) -> String {
        if value == "~" { return "\"$HOME\"" }
        guard value.hasPrefix("~/") else { return shellQuote(value) }
        let rest = String(value.dropFirst(2))
        return rest.isEmpty ? "\"$HOME\"/" : "\"$HOME\"/" + shellQuote(rest)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
