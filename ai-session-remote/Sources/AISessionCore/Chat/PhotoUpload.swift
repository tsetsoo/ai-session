import Foundation

/// Copies a pasted photo straight to the conversation's computer over the SSH connection the
/// app already holds, so the agent there can read it by path. Nothing goes through the hub,
/// iCloud or AirDrop.
///
/// The bytes travel as base64 inside ordinary exec commands, a chunk per command: sshd hands
/// the whole command to the login shell as one argument, and Linux refuses a single argument
/// over 128 KiB. The file is private to the user (umask 077) and deleted after `keepSeconds`.
/// Each upload also sweeps any older leftovers, in case a timed delete never ran (a reboot).
public enum PhotoUpload {
    /// Base64 characters per command, well under Linux's 128 KiB argument limit.
    public static let chunkSize = 64 * 1024
    /// How long an upload stays on the computer: long enough for the agent to read it.
    public static let keepSeconds = 3600
    /// Where uploads go, as a shell expression the remote shell expands.
    public static let defaultDirectory = "\"$HOME\"/.ai-remote/uploads"

    public enum Failure: Error, Equatable {
        case failed(String)
    }

    /// The commands that write `data` to `<directory>/<name>` and print its absolute path.
    /// `name` must be a plain file name (letters, digits, `-`, `.`); callers make it from a UUID.
    public static func commands(
        data: Data, name: String, directory: String = defaultDirectory, keepSeconds: Int = keepSeconds
    ) -> [String] {
        precondition(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }, "unsafe file name")
        let base64 = data.base64EncodedString()
        let dir = "d=\(directory);"
        let part = "\"$d/\(name).b64\""
        let file = "\"$d/\(name)\""
        let minutes = max(1, keepSeconds / 60)

        var commands = [
            "umask 077; \(dir) mkdir -p \"$d\" && chmod 700 \"$d\" && " +
                "{ find \"$d\" -type f -mmin +\(minutes) -exec rm -f {} + 2>/dev/null; : > \(part); }",
        ]
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            // Base64 is only [A-Za-z0-9+/=], so single quotes need no escaping.
            commands.append("\(dir) printf %s '\(base64[start..<end])' >> \(part)")
            start = end
        }
        // macOS's base64 decodes with -D on older releases and -d on newer ones; Linux has -d.
        commands.append(
            "umask 077; \(dir) { base64 -d < \(part) > \(file) 2>/dev/null || base64 -D < \(part) > \(file); } && rm -f \(part) && " +
                "{ nohup sh -c 'sleep \(keepSeconds); rm -f \"$1\"' sh \(file) </dev/null >/dev/null 2>&1 & } && " +
                "cd \"$d\" && printf '%s/%s\\n' \"$(pwd -P)\" '\(name)'"
        )
        return commands
    }

    /// Uploads `data` and returns the absolute path it landed at on the computer.
    public static func upload(
        _ data: Data, name: String, config: HostConnectionConfig, ssh: SSHExecuting,
        directory: String = defaultDirectory, keepSeconds: Int = keepSeconds
    ) async throws -> String {
        var output = ""
        for command in commands(data: data, name: name, directory: directory, keepSeconds: keepSeconds) {
            try Task.checkCancellation()
            let result = try await ssh.exec(config, command: command)
            guard result.exitCode == 0 else {
                throw Failure.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            output = result.stdout
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw Failure.failed("no path came back") }
        return path
    }
}
