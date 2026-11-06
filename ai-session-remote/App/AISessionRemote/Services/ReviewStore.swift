import AISessionCore
import Foundation
import Observation

/// Review comments and sent batches, per conversation (`Conversation.listKey`), on this device.
/// Not on the hub yet: the phone doesn't show them until the review view needs it there.
@Observable
@MainActor
final class ReviewStore {
    static let shared = ReviewStore()

    private(set) var records: [String: ReviewRecord] = [:]
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = ReviewStore.defaultURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([String: ReviewRecord].self, from: data) {
            records = saved
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // The unsandboxed Mac app shares Application Support with every other app.
        let folder = Bundle.main.bundleIdentifier ?? "AISessionRemote"
        return base.appendingPathComponent(folder).appendingPathComponent("review-comments.json")
    }

    func record(_ key: String) -> ReviewRecord {
        records[key] ?? ReviewRecord()
    }

    func update(_ key: String, _ change: (inout ReviewRecord) -> Void) {
        var record = record(key)
        change(&record)
        records[key] = record
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
