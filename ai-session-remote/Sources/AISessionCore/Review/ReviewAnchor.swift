import Foundation

/// Moves a comment's lines from the revision it was written on to a newer one, through
/// `ai-todo-review diff --from <old> --to <new>` (any context size; `--unified 0` is smallest).
public enum ReviewAnchor: Equatable, Sendable {
    /// Same file, possibly other line numbers (nil lines: a whole-file comment).
    case moved(path: String, startLine: Int?, endLine: Int?)
    /// Something inside the commented lines changed, or the file was deleted.
    case stale

    /// Where `comment` (new side) is in the newer revision. Removed-line comments refer to
    /// lines that are already gone, so they only stay put when their file wasn't touched again.
    public static func resolve(_ comment: ReviewComment, through diff: UnifiedDiff) -> ReviewAnchor {
        guard let file = diff.file(fromOldPath: comment.path) else {
            // Untouched since. (An added file at the same path can't be: the comment's path existed.)
            return .moved(path: comment.path, startLine: comment.startLine, endLine: comment.endLine)
        }
        guard let newPath = file.newPath, file.change != .deleted else { return .stale }
        guard let start = comment.startLine else { return .moved(path: newPath, startLine: nil, endLine: nil) }
        if comment.side == .old { return .stale }
        let end = comment.endLine ?? start
        let map = LineMap(file)
        if map.touches(start...end) { return .stale }
        guard let newStart = map.newLine(for: start), let newEnd = map.newLine(for: end) else { return .stale }
        return .moved(path: newPath, startLine: newStart, endLine: comment.endLine == nil ? nil : newEnd)
    }
}

/// Old-revision line numbers → new-revision ones for one file of a diff.
struct LineMap {
    private let hunks: [DiffHunk]

    init(_ file: DiffFile) {
        hunks = file.hunks
    }

    /// True when a line in `range` was removed, or a line was added between two of its lines.
    func touches(_ range: ClosedRange<Int>) -> Bool {
        for hunk in hunks {
            // The next old line. A pure insertion's header names the line it goes after.
            var old = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if range.contains(line.oldLine ?? old) { return true }
                    old = (line.oldLine ?? old) + 1
                case .added:
                    // Inserted after old line `old - 1`. Inside when that line and the next are both in range.
                    if range.contains(old - 1), range.contains(old) { return true }
                case .context:
                    old = (line.oldLine ?? old) + 1
                case .noNewline:
                    break
                }
            }
        }
        return false
    }

    /// Nil when the line was removed.
    func newLine(for oldLine: Int) -> Int? {
        var delta = 0
        for hunk in hunks {
            // A pure insertion (`-12,0`) goes after old line 12; it never covers an old line.
            let firstOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            let lastOld = hunk.oldStart + hunk.oldCount - 1
            if oldLine < firstOld { break }
            if hunk.oldCount > 0, oldLine <= lastOld {
                if let line = hunk.lines.first(where: { $0.oldLine == oldLine }) {
                    return line.newLine
                }
                return nil
            }
            delta += hunk.newCount - hunk.oldCount
        }
        return oldLine + delta
    }
}
