public enum TmuxCommandBuilder {
    /// Non-interactive SSH sessions often omit Homebrew paths that login shells have
    /// (e.g. `/opt/homebrew/bin` on Apple Silicon). Prefix every remote command so
    /// `tmux` / `claude` / `codex` / `agent` resolve the same way as in a normal terminal.
    private static let pathExport =
        #"export PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH""#

    /// A non-login SSH exec often has no UTF-8 locale. tmux then attaches with
    /// UTF-8 off and replaces Cyrillic, emoji, and other non-ASCII with `_`
    /// (`tty_check_codeset`). `LC_ALL` overrides `LANG` and `LC_CTYPE`, so it is
    /// judged on its own: a value that is set and is not UTF-8 is replaced even
    /// when `LANG` already contains UTF-8. When `LC_ALL` is unset, an existing
    /// UTF-8 `LANG` or `LC_CTYPE` is left alone; otherwise a UTF-8 locale is forced.
    private static let utf8Locale =
        #"case "${LC_ALL+x}" in x) case "$LC_ALL" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) export LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 LC_ALL=en_US.UTF-8 ;; esac ;; *) case "${LC_CTYPE:-}${LANG:-}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) export LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 LC_ALL=en_US.UTF-8 ;; esac ;; esac"#

    public static func ensureTmuxInstalledCheck() -> String {
        wrap("command -v tmux")
    }

    /// `tmux ls -F` fields. The separators are tab characters, which `TmuxListParser` splits on.
    ///
    /// A `\t` written inside these single quotes is the two characters `\` and `t`. tmux
    /// prints that literally, so the parser keeps `name\t<activity>\t<attached>` as the
    /// session name and every conversation looks closed.
    private static let listSessionsFormat =
        "'#{session_name}\t#{session_activity}\t#{session_attached}'"

    public static func listSessions() -> String {
        wrap("tmux ls -F \(listSessionsFormat)")
    }

    public static func attach(tmuxName: String) -> String {
        // `-u` is a tmux client flag (before the command). It sets CLIENT_UTF8 even
        // when the locale check above did not, so the pane is not rewritten as `_`.
        wrap("tmux -u attach -t \(shellQuote(tmuxName))")
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
    /// the tmux session, or creates/resumes the conversation (`claude`, `codex`, or `cursor`) if tmux is
    /// gone. `cwd` may start with `~`; the script expands it.
    ///
    /// The tool is passed as a 4th argument only when it isn't `claude`: scripts installed
    /// before Codex support reject a 4th argument, and `claude` is their default anyway.
    ///
    /// `mcpServers` adds `--mcp <comma-joined names>` as the first argument (`--mcp ''` = managed,
    /// none), except for cursor, which has no MCP management. `nil` leaves the arguments as before.
    public static func openTodoConversation(
        tmuxName: String, cwd: String, sessionId: String, tool: String = "claude", mcpServers: [String]? = nil
    ) -> String {
        var command = "exec \"$HOME/.ai-remote/bin/ai-todo-open\""
        if let mcpServers, tool != "cursor" { command += " --mcp \(shellQuote(mcpServers.joined(separator: ",")))" }
        command += " \(shellQuote(tmuxName)) \(shellQuote(cwd)) \(shellQuote(sessionId))"
        if tool != "claude" { command += " \(shellQuote(tool))" }
        return wrap(command)
    }

    /// Lists the MCP server files on the host as JSON (`ai-todo-mcp list --json`).
    public static func listMCPServers() -> String {
        wrap("exec \"$HOME/.ai-remote/bin/ai-todo-mcp\" list --json")
    }

    /// Prints one conversation's user and assistant text. Exit 94 when it has no transcript or no
    /// text, 127 when the helper isn't installed, 90 when `python3` isn't (stderr names it).
    public static func conversationTranscript(tool: String, sessionId: String) -> String {
        wrap(transcriptHelperCheck + "exec \"$helper\" \(shellQuote(tool)) \(shellQuote(sessionId))")
    }

    /// A new `claude -p` over that transcript. It is not the source session. The transcript is
    /// read first, so a missing or empty one stops here with its own exit code instead of
    /// `claude` summarizing only the instruction. Exit 90 when `claude` isn't installed.
    public static func summarizeConversation(tool: String, sessionId: String) -> String {
        let instruction = shellQuote(
            "Summarize this conversation so another tool can continue it. Keep decisions, file paths, and the current task."
        )
        return wrap(
            transcriptHelperCheck
                + "command -v claude >/dev/null 2>&1 || { echo 'claude not found' >&2; exit 90; }\n"
                + "transcript=$(\"$helper\" \(shellQuote(tool)) \(shellQuote(sessionId))) || exit $?\n"
                + "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT\n"
                + "printf '%s\\n\\n%s\\n' \(instruction) \"$transcript\" | "
                + "claude -p --no-session-persistence --tools \"\" --strict-mcp-config --setting-sources \"\""
        )
    }

    /// Sets `helper` to `ai-todo-transcript`, or exits 127 when it isn't installed and 90 when the
    /// `python3` it runs on isn't, so neither reads as the other.
    private static let transcriptHelperCheck = """
        helper="$HOME/.ai-remote/bin/ai-todo-transcript"
        [ -x "$helper" ] || { echo 'ai-todo-transcript not installed' >&2; exit 127; }
        command -v python3 >/dev/null 2>&1 || { echo 'python3 not found' >&2; exit 90; }

        """

    /// Starts the fork in tmux and prints `created <id>` for the new transcript, without attaching.
    /// The id is the new file under `~/.claude/projects`, not the source and not a minted placeholder.
    ///
    /// With `mcpServers`, the host evaluates `ai-todo-mcp launch-args claude <names>` into the
    /// claude arguments, ahead of `arguments`.
    public static func forkDetached(tmuxName: String, cwd: String, arguments: [String], mcpServers: [String]? = nil) -> String {
        var argv = arguments.map(shellQuote).joined(separator: " ")
        var mcpSetup = ""
        if let mcpServers {
            // The first word is the command; `launch-args` output (shell-quoted words) goes right after it.
            let names = shellQuote(mcpServers.joined(separator: ","))
            let rest = arguments.dropFirst().map(shellQuote).joined(separator: " ")
            mcpSetup = """
                mcp_args=$("$HOME/.ai-remote/bin/ai-todo-mcp" launch-args claude \(names)) || exit $?
                set -- \(arguments.first.map(shellQuote) ?? "claude")
                eval "set -- \\"\\$@\\" $mcp_args"
                set -- "$@" \(rest)

                """
            argv = "\"$@\""
        }
        let name = shellQuote(tmuxName)
        let exact = shellQuote("=" + tmuxName)
        let folder = shellQuotePath(cwd)
        return wrap(
            """
            \(mcpSetup)list_sessions() { find "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl' -print 2>/dev/null | LC_ALL=C sort; }
            before=$(list_sessions)
            tmux new-session -d -s \(name) -c \(folder) -- env PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}" \(argv) || exit $?
            deadline=$(( $(date +%s) + 30 ))
            while [ "$(date +%s)" -le "$deadline" ]; do
              now=$(list_sessions)
              path=$(printf '%s\\n%s\\n' "$before" "$now" | LC_ALL=C sort | LC_ALL=C uniq -u | while IFS= read -r candidate; do
                [ -n "$candidate" ] || continue
                printf '%s\\n' "$now" | grep -F -x -q "$candidate" && printf '%s\\n' "$candidate"
              done | head -n 1)
              if [ -n "$path" ]; then
                echo "created $(basename "$path" .jsonl)"
                exit 0
              fi
              sleep 0.2
            done
            tmux kill-session -t \(exact) 2>/dev/null || true
            echo "no forked conversation appeared" >&2
            exit 94
            """
        )
    }

    /// Starts a new Codex or Cursor conversation and prints `created <id>`. `-` tells the
    /// script the id does not exist yet. Detach returns as soon as the id appears.
    ///
    /// `mcpServers` adds `--mcp <comma-joined names>` as the first argument, as in
    /// `openTodoConversation` (none for cursor). This is the call that starts the tool, so it is
    /// where the selection takes effect. `nil` leaves the command as before.
    public static func freshTodoConversation(
        tmuxName: String, cwd: String, tool: String, mcpServers: [String]? = nil
    ) -> String {
        var command = "AI_TODO_OPEN_DETACH=1 exec \"$HOME/.ai-remote/bin/ai-todo-open\" "
        if let mcpServers, tool != "cursor" { command += "--mcp \(shellQuote(mcpServers.joined(separator: ","))) " }
        command += "\(shellQuote(tmuxName)) \(shellQuote(cwd)) - \(shellQuote(tool))"
        return wrap(command)
    }

    /// Exit status when the host-side scripts aren't installed (`command not found`).
    public static let scriptMissingExitCode: Int32 = 127

    /// Exit status when a program a script needs isn't installed. stderr is `<name> not found`.
    public static let binaryMissingExitCode: Int32 = 90

    /// Exit status when a conversation has no transcript (or no text) on the computer.
    public static let noTranscriptExitCode: Int32 = 94

    /// Lists the computer's Claude / Codex conversations as JSON (`[RemoteConversation]`).
    public static func listRemoteConversations(limit: Int = 200) -> String {
        wrap("\"$HOME/.ai-remote/bin/ai-todo-sessions\" list --json --limit \(max(1, limit))")
    }

    /// 5-hour, weekly and monthly limits for this tool's login on the computer.
    /// `--session` is sent only when the chat has an id, so Codex can read that
    /// conversation's own snapshot. The script prints JSON and does not print tokens.
    public static func usageLimits(tool: String, sessionId: String?) -> String {
        var command = "\"$HOME/.ai-remote/bin/ai-todo-limits\" --tool \(shellQuote(tool))"
        if let sessionId, !sessionId.isEmpty {
            command += " --session \(shellQuote(sessionId))"
        }
        return wrap(command)
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

    /// Gives a Claude or Codex conversation on the computer a new name (Claude: a custom-title
    /// line in its transcript; Codex: `thread/name/set`). 66 = no such conversation there;
    /// 64 also comes from scripts too old to know `rename`.
    public static func renameRemoteConversation(tool: String, sessionId: String, name: String) -> String {
        wrap(
            "\"$HOME/.ai-remote/bin/ai-todo-sessions\" rename \(shellQuote(tool)) \(shellQuote(sessionId)) \(shellQuote(name))"
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
            tmux ls -F \(listSessionsFormat); ls_exit=$?
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
        "\(pathExport); \(utf8Locale); \(command)"
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
