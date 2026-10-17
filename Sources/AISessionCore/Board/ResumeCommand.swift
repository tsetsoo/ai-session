/// Shell commands shown to the user to copy into a terminal.
public enum ResumeCommand {
    public static func string(for c: Conversation) -> String {
        let resume = c.tool == "codex" ? "codex resume \(c.sessionId)" : "\(c.tool) --resume \(c.sessionId)"
        return "cd \(quotedPath(c.cwd)) && \(resume)"
    }

    public static func install(hubURL: String) -> String {
        "scripts/todo/install.sh --hub-url \(quote(hubURL)) --token \"$TODO_API_TOKEN\""
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Keeps a leading `~` outside the quotes so the shell still expands it.
    private static func quotedPath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }
}
