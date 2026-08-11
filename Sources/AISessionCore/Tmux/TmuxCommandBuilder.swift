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

    public static func newDetachedSession(
        name: SessionName,
        cwd: String,
        commandArgs: [String]
    ) -> String {
        var parts = [
            "tmux new-session -d",
            "-s \(shellQuote(name.tmuxName))",
            "-c \(shellQuote(cwd))",
            "--",
        ]
        parts.append(contentsOf: commandArgs.map(shellQuote))
        return wrap(parts.joined(separator: " "))
    }

    public static func writeMetadata(tmuxName: String, json: String) -> String {
        let filename = SessionMetadataStore.filename(for: tmuxName)
        return wrap(
            "mkdir -p ~/.ai-remote/sessions && printf '%s' \(shellQuote(json)) > ~/.ai-remote/sessions/\(shellQuote(filename))"
        )
    }

    public static func attach(tmuxName: String) -> String {
        wrap("tmux attach -t \(shellQuote(tmuxName))")
    }

    public static func killSession(tmuxName: String) -> String {
        wrap("tmux kill-session -t \(shellQuote(tmuxName))")
    }

    public static func renameSession(from: String, to: String) -> String {
        wrap("tmux rename-session -t \(shellQuote(from)) \(shellQuote(to))")
    }

    public static func probeBinaries() -> String {
        wrap(
            """
            printf 'tmux:%s\\n' "$(command -v tmux || echo MISSING)"; printf 'claude:%s\\n' "$(command -v claude || echo MISSING)"; printf 'codex:%s\\n' "$(command -v codex || echo MISSING)"; printf 'agent:%s\\n' "$(command -v agent || echo MISSING)"; printf 'bash:%s\\n' "$(command -v bash || echo MISSING)"
            """
        )
    }

    public static func readAgentStatuses() -> String {
        wrap(
            #"mkdir -p ~/.ai-remote/status; for f in ~/.ai-remote/status/*.json; do [ -f "$f" ] && echo "---$(basename "$f")---" && cat "$f"; done"#
        )
    }

    public static func which(binary: String) -> String {
        wrap("command -v \(shellQuote(binary))")
    }

    static func wrap(_ command: String) -> String {
        "\(pathExport); \(command)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
