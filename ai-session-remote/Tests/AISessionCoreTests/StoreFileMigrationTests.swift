import Foundation
import XCTest
@testable import AISessionCore

final class StoreFileMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testCopiesDatabaseAndCompanionsAndKeepsTheOriginals() throws {
        try write("db", "Application Support/default.store")
        try write("wal", "Application Support/default.store-wal")
        try write("shm", "Application Support/default.store-shm")
        let legacy = root.appendingPathComponent("Application Support/default.store")
        let destination = root.appendingPathComponent("Application Support/com.example.mac/hosts.store")

        let outcome = try StoreFileMigration.migrateIfNeeded(from: legacy, to: destination)

        XCTAssertEqual(outcome, .copied(files: 3))
        XCTAssertEqual(read("Application Support/com.example.mac/hosts.store"), "db")
        XCTAssertEqual(read("Application Support/com.example.mac/hosts.store-wal"), "wal")
        XCTAssertEqual(read("Application Support/com.example.mac/hosts.store-shm"), "shm")
        // The old store stays as a backup.
        XCTAssertEqual(read("Application Support/default.store"), "db")
        XCTAssertEqual(read("Application Support/default.store-wal"), "wal")
    }

    func testCopiesWithoutCompanions() throws {
        try write("db", "old/default.store")
        let outcome = try StoreFileMigration.migrateIfNeeded(
            from: root.appendingPathComponent("old/default.store"),
            to: root.appendingPathComponent("new/hosts.store")
        )
        XCTAssertEqual(outcome, .copied(files: 1))
        XCTAssertEqual(read("new/hosts.store"), "db")
        XCTAssertNil(read("new/hosts.store-wal"))
    }

    func testSkipsWhenThereIsNoOldStore() throws {
        let outcome = try StoreFileMigration.migrateIfNeeded(
            from: root.appendingPathComponent("old/default.store"),
            to: root.appendingPathComponent("new/hosts.store")
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
    }

    func testNeverOverwritesAnExistingNewStore() throws {
        try write("old", "old/default.store")
        try write("new", "new/hosts.store")
        let outcome = try StoreFileMigration.migrateIfNeeded(
            from: root.appendingPathComponent("old/default.store"),
            to: root.appendingPathComponent("new/hosts.store")
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(read("new/hosts.store"), "new")
    }
}
