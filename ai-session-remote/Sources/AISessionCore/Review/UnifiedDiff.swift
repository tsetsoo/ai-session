import Foundation

/// A `git diff` patch, as `ai-todo-review diff` prints it (a/ b/ prefixes, no colour).
public struct UnifiedDiff: Equatable, Sendable {
    public var files: [DiffFile]

    public init(files: [DiffFile]) {
        self.files = files
    }

    /// The file whose old path is `path`: what happened to a file between the two revisions.
    public func file(fromOldPath path: String) -> DiffFile? {
        files.first { $0.oldPath == path }
    }

    public func file(atNewPath path: String) -> DiffFile? {
        files.first { $0.newPath == path }
    }

    public init(parsing patch: String) {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let done = hunk { file?.hunks.append(done) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let done = file { files.append(done) }
            file = nil
        }

        // Split on the byte, not the Character: Swift reads "\r\n" as one Character, so a CRLF
        // file's lines would never split. The CR stays out of the line's text.
        for raw in patch.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let bytes = raw.last == UInt8(ascii: "\r") ? raw.dropLast() : raw[...]
            let line = String(decoding: bytes, as: UTF8.self)
            if line.hasPrefix("diff --git ") {
                closeFile()
                let paths = Self.headerPaths(String(line.dropFirst("diff --git ".count)))
                file = DiffFile(oldPath: paths?.old, newPath: paths?.new)
                continue
            }
            guard file != nil else { continue }

            if var current = hunk {
                if let first = line.first, first == " " || first == "+" || first == "-" || first == "\\" {
                    let text = String(line.dropFirst())
                    switch first {
                    case "+":
                        current.lines.append(DiffLine(kind: .added, text: text, oldLine: nil, newLine: newLine))
                        newLine += 1
                    case "-":
                        current.lines.append(DiffLine(kind: .removed, text: text, oldLine: oldLine, newLine: nil))
                        oldLine += 1
                    case "\\":
                        current.lines.append(DiffLine(kind: .noNewline, text: text, oldLine: nil, newLine: nil))
                    default:
                        current.lines.append(DiffLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                        oldLine += 1
                        newLine += 1
                    }
                    hunk = current
                    continue
                }
                if line.isEmpty, current.remaining(oldLine: oldLine, newLine: newLine) {
                    // A blank context line whose leading space was stripped.
                    current.lines.append(DiffLine(kind: .context, text: "", oldLine: oldLine, newLine: newLine))
                    oldLine += 1
                    newLine += 1
                    hunk = current
                    continue
                }
                closeHunk()
            }

            if line.hasPrefix("@@ "), let header = Self.hunkHeader(line) {
                hunk = header
                oldLine = header.oldStart
                newLine = header.newStart
            } else if line.hasPrefix("--- ") {
                let path = Self.path(String(line.dropFirst(4)), prefix: "a/")
                file?.oldPath = path
                if path == nil { file?.change = .added }
            } else if line.hasPrefix("+++ ") {
                let path = Self.path(String(line.dropFirst(4)), prefix: "b/")
                file?.newPath = path
                if path == nil { file?.change = .deleted }
            } else if line.hasPrefix("new file mode") {
                let name = file?.newPath ?? file?.oldPath
                file?.change = .added
                file?.newPath = name
                file?.oldPath = nil
            } else if line.hasPrefix("deleted file mode") {
                let name = file?.oldPath ?? file?.newPath
                file?.change = .deleted
                file?.oldPath = name
                file?.newPath = nil
            } else if line.hasPrefix("rename from ") {
                file?.oldPath = Self.unquote(String(line.dropFirst("rename from ".count)))
                file?.change = .renamed
            } else if line.hasPrefix("rename to ") {
                file?.newPath = Self.unquote(String(line.dropFirst("rename to ".count)))
                file?.change = .renamed
            } else if line.hasPrefix("copy from ") {
                file?.oldPath = Self.unquote(String(line.dropFirst("copy from ".count)))
                file?.change = .copied
            } else if line.hasPrefix("copy to ") {
                file?.newPath = Self.unquote(String(line.dropFirst("copy to ".count)))
                file?.change = .copied
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file?.isBinary = true
            }
        }
        closeFile()
        self.files = files
    }

    /// `@@ -12,3 +12,4 @@ func name()`. A missing count is 1.
    static func hunkHeader(_ line: String) -> DiffHunk? {
        let body = line.dropFirst(3)
        guard let end = body.range(of: " @@") else { return nil }
        let ranges = body[..<end.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+"),
              let old = range(ranges[0].dropFirst()), let new = range(ranges[1].dropFirst()) else { return nil }
        let section = body[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return DiffHunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count,
                        section: section, lines: [])
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard parts.count == 2, let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    /// `--- a/path` (git adds a tab after a path with a space); nil for /dev/null.
    private static func path(_ text: String, prefix: String) -> String? {
        var value = text
        if let tab = value.firstIndex(of: "\t") { value = String(value[..<tab]) }
        value = unquote(value)
        if value == "/dev/null" { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `a/x b/x` (unquoted): the two halves when they name the same file. Renames and quoted
    /// names are filled in by the lines that follow.
    private static func headerPaths(_ text: String) -> (old: String, new: String)? {
        guard text.hasPrefix("a/"), !text.hasPrefix("\"") else { return nil }
        let count = text.count
        guard count % 2 == 1 else { return nil }
        let half = (count - 1) / 2
        let left = String(text.prefix(half))
        let right = String(text.suffix(half))
        guard right.hasPrefix("b/"), left.dropFirst(2) == right.dropFirst(2) else { return nil }
        let name = String(left.dropFirst(2))
        return (name, name)
    }

    /// Git's C-style quoting of unusual names: `"a/tab\there"`, with octal bytes.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var bytes: [UInt8] = []
        var chars = Array(text.utf8.dropFirst().dropLast())[...]
        while let byte = chars.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = chars.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = chars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    chars.removeFirst()
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct DiffFile: Equatable, Sendable, Identifiable {
    public enum Change: String, Equatable, Sendable {
        case modified, added, deleted, renamed, copied
    }

    /// Nil for an added file.
    public var oldPath: String?
    /// Nil for a deleted file.
    public var newPath: String?
    public var change: Change
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public init(oldPath: String?, newPath: String?, change: Change = .modified, isBinary: Bool = false, hunks: [DiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.change = change
        self.isBinary = isBinary
        self.hunks = hunks
    }

    /// The name to show and to anchor comments on: the new path, or the old one when deleted.
    public var path: String { newPath ?? oldPath ?? "" }
    public var id: String { path }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

public struct DiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The function or section name git prints after the second `@@`.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    /// Lines still owed by the header, so a bare empty line is a context line, not the end.
    func remaining(oldLine: Int, newLine: Int) -> Bool {
        oldLine < oldStart + oldCount && newLine < newStart + newCount
    }
}

public struct DiffLine: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case context, added, removed
        /// `\ No newline at end of file`
        case noNewline
    }

    public var kind: Kind
    public var text: String
    /// Line number in the old revision (context and removed lines).
    public var oldLine: Int?
    /// Line number in the new revision (context and added lines).
    public var newLine: Int?

    public init(kind: Kind, text: String, oldLine: Int?, newLine: Int?) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}
