public enum TmuxCommandBuilder {
    public static func ensureTmuxInstalledCheck() -> String {
        "command -v tmux"
    }

    public static func listSessions() -> String {
        "tmux ls -F '#{session_name}'"
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
        return parts.joined(separator: " ")
    }

    public static func writeMetadata(tmuxName: String, json: String) -> String {
        let filename = SessionMetadataStore.filename(for: tmuxName)
        return "mkdir -p ~/.ai-remote/sessions && printf '%s' \(shellQuote(json)) > ~/.ai-remote/sessions/\(shellQuote(filename))"
    }

    public static func attach(tmuxName: String) -> String {
        "tmux attach -t \(shellQuote(tmuxName))"
    }

    public static func killSession(tmuxName: String) -> String {
        "tmux kill-session -t \(shellQuote(tmuxName))"
    }

    public static func which(binary: String) -> String {
        "command -v \(shellQuote(binary))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
