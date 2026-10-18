import AISessionCore
import Foundation
import SwiftData

/// The one place the app's SwiftData host store is opened, shared by the window scene and
/// launch-argument provisioning so both always use the same file.
///
/// - macOS: `~/Library/Application Support/<bundle id>/hosts.store`. The unsandboxed Mac app
///   used to use SwiftData's default `~/Library/Application Support/default.store`, a folder
///   it shares with every other app; on first launch that store is copied over (the old
///   file is left in place as a backup).
/// - iOS: SwiftData's default location, inside the app's private container (unchanged, so
///   existing hosts keep working).
enum HostStore {
    @MainActor static let shared: ModelContainer = {
        do {
            return try makeContainer()
        } catch {
            fatalError("Could not open the host store: \(error)")
        }
    }()

    static func makeContainer() throws -> ModelContainer {
        #if os(macOS)
        let destination = macStoreURL()
        let legacy = applicationSupport().appendingPathComponent("default.store")
        do {
            try StoreFileMigration.migrateIfNeeded(from: legacy, to: destination)
        } catch {
            // Fall back to a fresh store at the new location rather than refusing to start;
            // the old file is untouched, so nothing is lost.
            FileHandle.standardError.write(Data("host store migration failed: \(error)\n".utf8))
        }
        return try ModelContainer(
            for: HostEntity.self,
            configurations: ModelConfiguration(url: destination)
        )
        #else
        return try ModelContainer(for: HostEntity.self)
        #endif
    }

    private static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    #if os(macOS)
    static func macStoreURL() -> URL {
        let folder = Bundle.main.bundleIdentifier ?? "AISessionRemote"
        return applicationSupport()
            .appendingPathComponent(folder)
            .appendingPathComponent("hosts.store")
    }
    #endif
}
