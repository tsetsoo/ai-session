import Foundation

/// Moves a SQLite-backed store (SwiftData / Core Data) to a new location by copying the
/// database and its `-wal` / `-shm` companions.
///
/// Used once by the Mac app: its host store used to live at the default
/// `~/Library/Application Support/default.store`, a folder the unsandboxed app shares with
/// every other app. The old files are kept as a backup rather than deleted.
public enum StoreFileMigration {
    public enum Outcome: Equatable {
        /// Nothing to do: no old store, or the new store already exists.
        case skipped
        /// The old store (and its companions) were copied to the new location.
        case copied(files: Int)
    }

    static let companionSuffixes = ["", "-wal", "-shm"]

    /// Copies `legacy` (+ `-wal`, `-shm`) to `destination` (same suffixes) when the legacy
    /// database exists and the destination database does not. Creates the destination
    /// folder. On failure, removes whatever was partially copied so the next launch retries.
    @discardableResult
    public static func migrateIfNeeded(
        from legacy: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: destination.path)
        else { return .skipped }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var copied: [URL] = []
        do {
            // Companions first, the main database last: a crash midway then leaves no
            // destination database, so the next launch starts the copy over.
            for suffix in companionSuffixes.reversed() {
                let source = URL(fileURLWithPath: legacy.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = URL(fileURLWithPath: destination.path + suffix)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: source, to: target)
                copied.append(target)
            }
        } catch {
            for url in copied { try? fileManager.removeItem(at: url) }
            throw error
        }
        return .copied(files: copied.count)
    }
}
