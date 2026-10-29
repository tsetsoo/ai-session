/// Shell commands shown to the user to copy into a terminal.
public enum ResumeCommand {
    public static func string(for c: Conversation) -> String {
        let resume: String
        switch c.tool {
        case "codex": resume = "codex resume \(c.sessionId)"
        case "cursor": resume = "agent --resume \(c.sessionId)"
        default: resume = "\(c.tool) --resume \(c.sessionId)"
        }
        if let names = c.mcpServers, c.tool == "claude" || c.tool == "codex" {
            // The host's helper prints the MCP flags as shell-quoted words, which `eval` splits.
            let verb = c.tool == "codex" ? "resume" : "--resume"
            let helper = "~/.ai-remote/bin/ai-todo-mcp launch-args \(c.tool) \(quote(names.joined(separator: ",")))"
            return "cd \(quotedPath(c.cwd)) && eval \"\(c.tool) $(\(helper)) \(verb) \(c.sessionId)\""
        }
        return "cd \(quotedPath(c.cwd)) && \(resume)"
    }

    /// Names whatever else holds a Codex conversation, as `ai-todo-open` does when it exits 95.
    public static func writerCheck(for c: Conversation) -> String {
        "~/.ai-remote/bin/ai-todo-status writer \(quote(c.tmuxName)) \(quote(c.sessionId))"
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
