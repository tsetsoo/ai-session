/// Helpers for reading stdout produced by a single remote script that ran several commands.
///
/// Only stdout needs a delimiter: SSH carries stderr on a separate stream and `SSHExecResult`
/// keeps it distinct, so a merged script can let its dominant command's stderr and exit code
/// flow through untouched and existing error mapping keeps working unchanged.
public enum RemoteScriptOutput {
    /// Emitted on its own line between the session list and the agent-status dump.
    /// Deliberately implausible as a tmux session name.
    public static let statusMarker = "<<<AI-REMOTE-STATUS>>>"

    /// Splits `stdout` at the first line exactly equal to `marker`.
    ///
    /// Returns `tail == nil` when the marker never appears — meaning the second command never
    /// ran or its output was lost — so callers can treat that as "unavailable" rather than
    /// silently folding the second command's output into the first's.
    /// Both components have trailing newlines trimmed.
    public static func split(_ stdout: String, at marker: String) -> (head: String, tail: String?) {
        var head: [Substring] = []
        var tail: [Substring]?

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if tail == nil, line == marker {
                tail = []
            } else if tail == nil {
                head.append(line)
            } else {
                tail?.append(line)
            }
        }

        func join(_ lines: [Substring]) -> String {
            var text = lines.joined(separator: "\n")
            while text.hasSuffix("\n") { text.removeLast() }
            return text
        }

        return (head: join(head), tail: tail.map(join))
    }
}
