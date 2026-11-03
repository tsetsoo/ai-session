import Foundation

/// Copies a pasted photo straight to the conversation's computer over the SSH connection the
/// app already holds, so the agent there can read it by path. Nothing goes through the hub,
/// iCloud or AirDrop.
///
/// The bytes travel as base64 inside ordinary exec commands, a chunk per command: sshd hands
/// the whole command to the login shell as one argument, and Linux refuses a single argument
/// over 128 KiB. Every script runs under `sh -c`, whatever the login shell is.
///
/// The file is private to the user (umask 077). It is deleted `keepSeconds` after the message
/// that names it is sent (`deleteCommand`), so a draft can wait. One never sent is swept by a
/// later upload once it is `staleMinutes` old.
public enum PhotoUpload {
    /// Base64 characters per command, well under Linux's 128 KiB argument limit.
    public static let chunkSize = 64 * 1024
    /// How long an upload stays after its message is sent: long enough for the agent to read it.
    public static let keepSeconds = 3600
    /// Uploads whose message was never sent are removed after a day.
    public static let staleMinutes = 24 * 60
    /// Where uploads go, as a shell expression the remote shell expands.
    public static let defaultDirectory = "\"$HOME\"/.ai-remote/uploads"

    public enum Failure: Error, Equatable {
        case failed(String)
    }

    /// The commands that write `data` to `<directory>/<name>` and print its absolute path.
    /// `name` must be a plain file name (letters, digits, `-`, `.`); callers make it from a UUID.
    public static func commands(data: Data, name: String, directory: String = defaultDirectory) -> [String] {
        precondition(isSafe(name), "unsafe file name")
        let base64 = data.base64EncodedString()
        let dir = "d=\(directory);"
        let part = "\"$d/\(name).b64\""
        let file = "\"$d/\(name)\""

        var scripts = [
            "umask 077; \(dir) mkdir -p \"$d\" && chmod 700 \"$d\" && " +
                "{ find \"$d\" -type f -mmin +\(staleMinutes) -exec rm -f {} + 2>/dev/null; : > \(part); }",
        ]
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            // Base64 is only [A-Za-z0-9+/=], so single quotes need no escaping.
            scripts.append("\(dir) printf %s '\(base64[start..<end])' >> \(part)")
            start = end
        }
        // macOS's base64 decodes with -D on older releases and -d on newer ones; Linux has -d.
        // The path goes last, on its own line, after anything the shell's startup printed.
        scripts.append(
            "umask 077; \(dir) { base64 -d < \(part) > \(file) 2>/dev/null || base64 -D < \(part) > \(file); } && rm -f \(part) && " +
                "cd \"$d\" && printf '\\n%s/%s\\n' \"$(pwd -P)\" '\(name)'"
        )
        return scripts.map(sh)
    }

    /// Removes a half-written upload after a failure or cancel.
    public static func cleanupCommand(name: String, directory: String = defaultDirectory) -> String {
        precondition(isSafe(name), "unsafe file name")
        return sh("d=\(directory); rm -f \"$d/\(name).b64\" \"$d/\(name)\"")
    }

    /// Deletes `paths` (uploads this app made) `keepSeconds` from now, after the connection closes too.
    public static func deleteCommand(paths: [String], keepSeconds: Int = keepSeconds) -> String {
        let quoted = paths.map(quote).joined(separator: " ")
        return sh("nohup sh -c 'sleep \(keepSeconds); rm -f \"$@\"' sh \(quoted) </dev/null >/dev/null 2>&1 &")
    }

    /// Uploads `data` and returns the absolute path it landed at on the computer. On failure or
    /// cancel the partial file is removed and the error rethrown (`CancellationError` if cancelled).
    public static func upload(
        _ data: Data, name: String, config: HostConnectionConfig, ssh: SSHExecuting,
        directory: String = defaultDirectory
    ) async throws -> String {
        do {
            var output = ""
            for command in commands(data: data, name: name, directory: directory) {
                try Task.checkCancellation()
                let result = try await ssh.exec(config, command: command)
                guard result.exitCode == 0 else {
                    throw Failure.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                output = result.stdout
            }
            try Task.checkCancellation()
            let path = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            guard path.hasPrefix("/") else { throw Failure.failed("no path came back") }
            return path
        } catch {
            // Not part of the cancelled task: the cleanup should run even though it was cancelled.
            let cleanup = cleanupCommand(name: name, directory: directory)
            Task.detached { _ = try? await ssh.exec(config, command: cleanup) }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The uploaded paths that `text` mentions.
    public static func paths(in text: String, from uploaded: [String]) -> [String] {
        uploaded.filter { text.contains($0) }
    }

    private static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func sh(_ script: String) -> String { "sh -c \(quote(script))" }
}
