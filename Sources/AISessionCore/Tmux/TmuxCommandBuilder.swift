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
            if [ $ls_exit -eq 0 ]; then mkdir -p ~/.ai-remote/status; for f in ~/.ai-remote/status/*.json; do [ -f "$f" ] && echo "---$(basename "$f")---" && cat "$f"; done; fi
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
            exec tmux new-session -d -s \(shellQuote(name.tmuxName)) -c \(shellQuote(cwd)) -- "$p"
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

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
