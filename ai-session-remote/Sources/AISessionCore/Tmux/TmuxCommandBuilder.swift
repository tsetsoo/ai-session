import Foundation
public enum TmuxCommandBuilder {
    /// Non-interactive SSH sessions often omit Homebrew paths that login shells have
    /// (e.g. `/opt/homebrew/bin` on Apple Silicon). Prefix every remote command so
    /// `tmux` / `claude` / `codex` / `agent` resolve the same way as in a normal terminal.
    /// Linuxbrew only off macOS (no `/System`): there `/home` is an automount, and every
    /// command lookup that reached it cost a directory-service round trip.
    private static let pathExport =
        #"export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"; [ -d /System ] || export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH""#

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

    /// Attach to the same shell on every visit, creating it only on the first connection.
    /// Detaching SSH leaves its directory, jobs and shell variables alive in tmux.
    public static func persistentShell(tmuxName: String) -> String {
        wrap("exec tmux -u new-session -A -s \(shellQuote(tmuxName)) -c \"$HOME\"")
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
    ///
    /// `worktree` (the conversation's own worktree) adds `--worktree <folder> <branch>`: the script
    /// makes the worktree at `cwd` from `folder`'s repo when it is missing.
    ///
    /// `promptFile` (from `writePromptFile`) is the first message of a conversation this starts;
    /// `detached` starts it without attaching (prints `created` or `attach`).
    public static func openTodoConversation(
        tmuxName: String, cwd: String, sessionId: String, tool: String = "claude", mcpServers: [String]? = nil,
        worktree: (folder: String, branch: String)? = nil, promptFile: String? = nil, detached: Bool = false,
        model: String? = nil, worktreeBase: String? = nil
    ) -> String {
        var command = (detached ? "AI_TODO_OPEN_DETACH=1 " : "") + "exec \"$HOME/.ai-remote/bin/ai-todo-open\""
        if let mcpServers, tool != "cursor" { command += " --mcp \(shellQuote(mcpServers.joined(separator: ",")))" }
        command += worktreeArguments(worktree) + startArguments(worktreeBase: worktreeBase, model: model)
            + promptFileArgument(promptFile)
        command += " \(shellQuote(tmuxName)) \(shellQuote(cwd)) \(shellQuote(sessionId))"
        if tool != "claude" { command += " \(shellQuote(tool))" }
        return wrap(command)
    }

    /// Exit 0 when the Codex conversation has a rollout on the host, 1 when it has none: Codex
    /// 0.163+ writes it only after the first message, and `codex resume` refuses one without.
    public static func codexHasRollout(sessionId: String) -> String {
        let pattern = shellQuote("rollout-*-\(sessionId).jsonl")
        return wrap(#"[ -n "$(find "${CODEX_HOME:-$HOME/.codex}/sessions" -name "# + pattern + #" -print -quit 2>/dev/null)" ]"#)
    }

    /// Lists the MCP server files on the host as JSON (`ai-todo-mcp list --json`).
    public static func listMCPServers() -> String {
        wrap("exec \"$HOME/.ai-remote/bin/ai-todo-mcp\" list --json")
    }

    /// Prints one conversation's user and assistant text. Exit 94 when it has no transcript or no
    /// text, 127 when the helper isn't installed, 90 when `python3` isn't (stderr names it).
    /// `activity` adds tool steps and times; helpers older than that exit 64 (usage). `after`
    /// asks only for entries from later transcript lines.
    public static func conversationTranscript(tool: String, sessionId: String, json: Bool = false, activity: Bool = false, after: Int? = nil) -> String {
        let afterFlag = json && activity ? after.map { " --after \($0)" } ?? "" : ""
        return wrap(transcriptHelperCheck + "exec \"$helper\" \(shellQuote(tool)) \(shellQuote(sessionId))"
            + (json ? " --json" : "") + (json && activity ? " --activity" : "") + afterFlag)
    }

    /// The work a Claude or Codex conversation delegated, as JSON (`--subagents`). Helpers
    /// older than that exit 64; 94 when the conversation has no transcript on the computer.
    public static func delegatedWork(tool: String, sessionId: String) -> String {
        wrap(transcriptHelperCheck + "exec \"$helper\" \(shellQuote(tool)) \(shellQuote(sessionId)) --subagents")
    }

    /// One worker's own transcript with tool steps, as the chat reads its parent's. 94 when that
    /// worker isn't the parent's on this computer.
    public static func workerTranscript(tool: String, parentId: String, workerId: String, after: Int? = nil) -> String {
        conversationTranscript(tool: tool, sessionId: parentId + "/" + workerId, json: true, activity: true, after: after)
    }

    /// A new `claude -p` (Sonnet, medium effort: quicker) over that transcript. It is not the source session. The transcript is
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
                + "claude -p --model sonnet --effort medium --no-session-persistence --tools \"\" --strict-mcp-config --setting-sources \"\""
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
    /// claude arguments, ahead of `arguments`, and (as `ai-todo-open` does) runs claude through
    /// `/bin/sh` to read `~/.ai-remote/mcp/env` when that file exists: the tmux server's
    /// environment lacks the variables the server files reference.
    /// `worktree` makes the conversation's worktree at `cwd` first when it is missing (swept, or
    /// removed by hand), as `ai-todo-open --worktree` does; exit 96 when it can't be made.
    public static func forkDetached(
        tmuxName: String, cwd: String, arguments: [String], mcpServers: [String]? = nil,
        worktree: (folder: String, branch: String)? = nil
    ) -> String {
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
                if [ -e "$HOME/.ai-remote/mcp/env" ]; then
                  set -- /bin/sh -c 'set -a; [ -r "$HOME/.ai-remote/mcp/env" ] && . "$HOME/.ai-remote/mcp/env"; set +a; exec "$@"' sh "$@"
                fi

                """
            argv = "\"$@\""
        }
        let name = shellQuote(tmuxName)
        let exact = shellQuote("=" + tmuxName)
        let folder = shellQuotePath(cwd)
        let ensure = worktree.map {
            "\"$HOME/.ai-remote/bin/ai-todo-workspace\" ensure \(folder) \(shellQuotePath($0.folder)) \(shellQuote($0.branch)) || exit 96\n"
        } ?? ""
        return wrap(
            """
            \(ensure)\(mcpSetup)list_sessions() { find "$HOME/.claude/projects" -maxdepth 2 -name '*.jsonl' -print 2>/dev/null | LC_ALL=C sort; }
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
        tmuxName: String, cwd: String, tool: String, mcpServers: [String]? = nil,
        worktree: (folder: String, branch: String)? = nil, promptFile: String? = nil,
        model: String? = nil, worktreeBase: String? = nil
    ) -> String {
        var command = "AI_TODO_OPEN_DETACH=1 exec \"$HOME/.ai-remote/bin/ai-todo-open\""
        if let mcpServers, tool != "cursor" { command += " --mcp \(shellQuote(mcpServers.joined(separator: ",")))" }
        command += worktreeArguments(worktree) + startArguments(worktreeBase: worktreeBase, model: model)
            + promptFileArgument(promptFile) + " "
        command += "\(shellQuote(tmuxName)) \(shellQuote(cwd)) - \(shellQuote(tool))"
        return wrap(command)
    }

    /// ` --worktree-base <sha>` (a new worktree's starting commit) and ` --model <id>` (a new
    /// conversation's model), each only when given.
    private static func startArguments(worktreeBase: String?, model: String?) -> String {
        var out = ""
        if let worktreeBase, !worktreeBase.isEmpty { out += " --worktree-base \(shellQuote(worktreeBase))" }
        if let model, !model.isEmpty { out += " --model \(shellQuote(model))" }
        return out
    }

    /// ` --prompt-file <path>`, or nothing.
    private static func promptFileArgument(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return " --prompt-file \(shellQuote(path))"
    }

    /// Whether `ai-todo-open` gives this tool a first message (`--prompt-file`). Cursor's start
    /// has none, so its hand-off is still typed into the terminal.
    public static func takesFirstPrompt(tool: String) -> Bool {
        tool == "claude" || tool == "codex"
    }

    /// Writes `text` to a new private file under `~/.ai-remote/prompts` and prints its path, for
    /// `--prompt-file` (which deletes it). The text travels base64-encoded, so no quoting of it
    /// can break the command.
    public static func writePromptFile(text: String) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        let script = "umask 077 && mkdir -p \"$HOME/.ai-remote/prompts\" && "
            + "f=$(mktemp \"$HOME/.ai-remote/prompts/handoff.XXXXXX\") && "
            + "printf '%s' \(shellQuote(encoded)) | base64 --decode >\"$f\" && printf '%s\\n' \"$f\""
        return wrap(script)
    }

    /// The most UTF-8 bytes of hand-off text in one command (about 64 KB once base64-encoded),
    /// well under every computer's limit for one argument (128 KB on Linux).
    public static let promptPieceBytes = 48_000

    /// `text` in pieces of at most `promptPieceBytes` bytes, split between characters:
    /// the first goes up with `writePromptFile`, the rest with `appendPromptFile`.
    public static func promptPieces(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > promptPieceBytes, !current.isEmpty {
                pieces.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        if !current.isEmpty || pieces.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Adds `text` to a prompt file `writePromptFile` made.
    public static func appendPromptFile(path: String, text: String) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        return wrap("printf '%s' \(shellQuote(encoded)) | base64 --decode >>\(shellQuote(path))")
    }

    /// ` --worktree <folder> <branch>`, or nothing. A `~` folder is quoted; the script expands it.
    private static func worktreeArguments(_ worktree: (folder: String, branch: String)?) -> String {
        guard let worktree else { return "" }
        return " --worktree \(shellQuote(worktree.folder)) \(shellQuote(worktree.branch))"
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
    /// The computer's doctor report as JSON (`HostHealth`): tool versions and logins, the
    /// version each running conversation uses, the status service and pending deliveries.
    /// Read-only; it takes a few seconds.
    public static let doctor = wrap("\"$HOME/.ai-remote/bin/ai-todo-status\" doctor")

    /// Exit status of `ai-todo-status restart` when the conversation is working, waiting for
    /// the user, has background tasks or an unreadable state. stdout still has the JSON.
    public static let restartRefusedExitCode: Int32 = 75

    /// Restarts one conversation (`RestartResult` JSON): refuses while it works or waits
    /// unless `force`, ends its CLI cleanly, and with `reopenCwd` starts it again detached
    /// (with `mcpServers` as `--mcp`, and `worktree` so a deleted worktree is made again).
    /// Without it, attaching resumes it. `search` (Codex only): turn live web search on or
    /// off for this and later starts; nil leaves it.
    public static func restartConversation(
        tmuxName: String, sessionId: String, tool: String, force: Bool = false,
        chrome: ChromeChoice = .keep, reopenCwd: String? = nil, mcpServers: [String]? = nil,
        worktree: (folder: String, branch: String)? = nil, search: Bool? = nil
    ) -> String {
        var command = "\"$HOME/.ai-remote/bin/ai-todo-status\" restart \(shellQuote(tmuxName)) \(shellQuote(sessionId)) \(shellQuote(tool))"
        if force { command += " --force" }
        if chrome != .keep, tool == "claude" { command += " --chrome \(chrome.rawValue)" }
        if let search, tool == "codex" { command += " --search \(search ? "on" : "off")" }
        if let reopenCwd {
            command += " --reopen \(shellQuote(reopenCwd))"
            if let mcpServers, tool != "cursor" { command += " --mcp \(shellQuote(mcpServers.joined(separator: ",")))" }
            command += worktreeArguments(worktree)
        }
        return wrap(command)
    }

    /// Installs the latest version of one agent CLI (claude, codex or cursor) the way it was
    /// installed (`UpgradeResult` JSON). Only on the user's request; it can take minutes.
    public static func upgradeTool(_ tool: String) -> String {
        wrap("\"$HOME/.ai-remote/bin/ai-todo-status\" upgrade \(shellQuote(tool))")
    }

    /// The conversation's saved launch settings as JSON (`LaunchSettings`).
    public static func launchSettings(tool: String, sessionId: String) -> String {
        wrap("\"$HOME/.ai-remote/bin/ai-todo-status\" launch show \(shellQuote(tool)) \(shellQuote(sessionId))")
    }

    public static func usageLimits(tool: String, sessionId: String?) -> String {
        var command = "\"$HOME/.ai-remote/bin/ai-todo-limits\" --tool \(shellQuote(tool))"
        if let sessionId, !sessionId.isEmpty {
            command += " --session \(shellQuote(sessionId))"
        }
        return wrap(command)
    }

    /// The one-tap Resume of a conversation paused by a usage limit: the computer checks it
    /// (no question on screen, nothing typed, the limit has reset), takes the hub's lease and
    /// types the resume message. Exit 0 when typed, 75 when not now, with JSON on stdout.
    public static func resumeAfterLimit(tool: String, sessionId: String) -> String {
        wrap("\"$HOME/.ai-remote/bin/ai-todo-status\" resume \(shellQuote(tool)) \(shellQuote(sessionId))")
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
        let arguments = name.tool.defaultArguments.map(shellQuote).joined(separator: " ")
        return wrap(
            """
            p=$(command -v \(shellQuote(binary))) || exit 90
            mkdir -p ~/.ai-remote/sessions || exit 91
            printf \(shellQuote(metadataTemplate)) "$p" > ~/.ai-remote/sessions/\(shellQuote(file)) || exit 92
            exec tmux new-session -d -s \(shellQuote(name.tmuxName)) -c \(shellQuotePath(cwd)) -- "$p"\(arguments.isEmpty ? "" : " " + arguments)
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
