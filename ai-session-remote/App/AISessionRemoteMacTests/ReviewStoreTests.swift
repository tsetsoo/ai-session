import AISessionCore
import Foundation
import XCTest
@testable import AI_Session_Remote

/// ReviewStore as a cache of the hub's reviews, against a fake hub in memory.
@MainActor
final class ReviewStoreTests: XCTestCase {
    private let key = "conv-1"

    override func setUp() {
        super.setUp()
        FakeReviewHub.reset()
    }

    private func makeStore(file: URL? = nil) -> (ReviewStore, URL) {
        let url = file ?? FileManager.default.temporaryDirectory.appendingPathComponent("review-store-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeReviewHub.self]
        let client = TodoHubClient(baseURL: URL(string: "http://hub.invalid")!, token: "t", session: URLSession(configuration: config))
        return (ReviewStore(fileURL: url, makeClient: { client }), url)
    }

    private func comment(_ body: String, state: ReviewComment.State = .draft, author: String = "user") -> ReviewComment {
        ReviewComment(author: author, path: "a.swift", startLine: 2, endLine: 4, revision: "rev1", quote: ["x"], body: body, state: state)
    }

    /// Pushes run in tasks of their own: wait for the one under way, then push what's left.
    private func settle(_ store: ReviewStore) async {
        for _ in 0..<300 {
            if !store.isPushing(key) {
                await store.pushAll()
                if !store.isSyncing(key) || store.isOffline { return }
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testChangesGoToTheHubAndComeBackWithTheirBatch() async throws {
        let (store, _) = makeStore()
        await store.refresh(key)
        let mine = comment("mine")
        let finding = comment("finding", state: .new, author: "reviewer:claude")
        store.update(key) { $0.comments += [mine, finding] }
        await settle(store)
        XCTAssertEqual(FakeReviewHub.record(key).items.map(\.body).sorted(), ["finding", "mine"])

        let batch = ReviewBatch(commentIDs: [mine.id], revision: "rev2", statusRevision: 9)
        store.update(key) { record in
            record.comments[0].state = .sent
            record.comments[0].sentAt = batch.sentAt
            record.comments[0].batchID = batch.id
            record.batches.append(batch)
        }
        await settle(store)
        let sent = try XCTUnwrap(FakeReviewHub.record(key).items.first { $0.body == "mine" })
        XCTAssertEqual(sent.state, "sent")
        XCTAssertEqual(sent.sentInTurn, 9)
        XCTAssertEqual(sent.sentRevision, "rev2")

        // Another device reads it back with the batch rebuilt.
        let (other, _) = makeStore()
        await other.refresh(key)
        let record = other.record(key)
        XCTAssertEqual(record.comments.count, 2)
        XCTAssertEqual(record.lastBatch?.id, batch.id)
        XCTAssertEqual(record.lastBatch?.revision, "rev2")
        XCTAssertEqual(record.lastBatch?.statusRevision, 9)
        XCTAssertEqual(record.lastBatch?.commentIDs, [mine.id])
        XCTAssertEqual(record.comments.first { $0.id == finding.id }?.state, .new)
    }

    func testAnotherDevicesChangeArrivesOnRefresh() async throws {
        let (store, _) = makeStore()
        await store.refresh(key)
        let finding = comment("finding", state: .new, author: "reviewer:codex")
        store.update(key) { $0.comments.append(finding) }
        await settle(store)
        // The phone dismissed it.
        FakeReviewHub.change(key) { $0.items[0].state = "dismissed" }
        await store.refresh(key)
        XCTAssertEqual(store.record(key).comments.first?.state, .dismissed)
    }

    func testOfflineChangesStayPendingAndGoOnceTheHubIsBack() async throws {
        let (store, url) = makeStore()
        await store.refresh(key)
        FakeReviewHub.setUnreachable(true)
        let mine = comment("written offline")
        store.update(key) { $0.comments.append(mine) }
        await settle(store)
        XCTAssertTrue(store.isOffline)
        XCTAssertTrue(FakeReviewHub.record(key).items.isEmpty)
        // A refresh while the hub is away keeps it.
        await store.refresh(key)
        XCTAssertEqual(store.record(key).comments.map(\.id), [mine.id])
        // So does a restart: pending rows are in the file.
        let (restarted, _) = makeStore(file: url)
        FakeReviewHub.setUnreachable(false)
        await restarted.refresh(key)
        XCTAssertFalse(restarted.isOffline)
        XCTAssertEqual(FakeReviewHub.record(key).items.map(\.body), ["written offline"])
        XCTAssertEqual(restarted.record(key).comments.map(\.id), [mine.id])
    }

    func testTheLocalOnlyFileIsUploadedOnceAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("review-comments.json")
        let old = comment("from before the hub")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([key: ReviewRecord(comments: [old])]).write(to: url)

        // The hub can't take it yet (an older hub): nothing is lost.
        FakeReviewHub.setMissing(true)
        let (store, _) = makeStore(file: url)
        await store.refresh(key)
        XCTAssertEqual(store.record(key).comments.map(\.id), [old.id])
        FakeReviewHub.setMissing(false)
        await store.refresh(key)
        XCTAssertEqual(FakeReviewHub.record(key).items.map(\.body), ["from before the hub"])
        XCTAssertEqual(store.record(key).comments.map(\.id), [old.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("review-comments.before-hub.json").path))
        // Once only: deleted on the hub, it doesn't come back.
        FakeReviewHub.change(key) { $0.items.removeAll() }
        let (again, _) = makeStore(file: url)
        await again.refresh(key)
        XCTAssertTrue(again.record(key).comments.isEmpty)
        XCTAssertTrue(FakeReviewHub.record(key).items.isEmpty)
    }

    private let host = HostConnectionConfig(host: "h", port: 22, username: "u", privateKeyPEM: Data())

    private func phoneConversation(status: ConversationStatus = .idle) -> Conversation {
        var conversation = DemoFixtures.conversations[0]
        conversation.id = key
        conversation.status = status
        conversation.statusRevision = 12
        return conversation
    }

    func testThePhoneSendsOneItemInABatchOfItsOwn() async throws {
        let (store, _) = makeStore()
        await store.refresh(key)
        let finding = ReviewComment(author: "reviewer:claude", path: "a.swift", startLine: 2, endLine: nil, revision: "rev1",
                                    quote: ["x"], body: "Fix it.", state: .new, title: "Bug", fingerprint: "fp")
        store.update(key) { $0.comments.append(finding) }
        await settle(store)
        var commands: [String] = []
        try await ReviewItemSender.send(finding.id, conversation: phoneConversation(), store: store, hubOffline: false,
                                        config: host) { _, command in
            commands.append(command)
            return SSHExecResult(exitCode: 0, stdout: "{}", stderr: "")
        }
        XCTAssertTrue(commands[0].contains(" keep ") && commands[0].contains("'rev1'"), commands[0])
        XCTAssertTrue(commands[1].contains(" send --base64 "), commands[1])
        let record = store.record(key)
        XCTAssertEqual(record.comments[0].state, .sent)
        XCTAssertEqual(record.lastBatch?.commentIDs, [finding.id])
        XCTAssertEqual(record.lastBatch?.statusRevision, 12)
        let row = try XCTUnwrap(FakeReviewHub.record(key).items.first)
        XCTAssertEqual(row.state, "sent")
        XCTAssertEqual(row.sentInTurn, 12)

        // Busy: nothing runs.
        do {
            try await ReviewItemSender.send(finding.id, conversation: phoneConversation(status: .busy), store: store,
                                            hubOffline: false, config: host) { _, _ in
                XCTFail("nothing runs while the agent works")
                return SSHExecResult(exitCode: 0, stdout: "", stderr: "")
            }
            XCTFail("sent while busy")
        } catch {}
    }

    func testThePhoneDoesntSendWhatAnotherDeviceAlreadyActedOn() async throws {
        let (store, _) = makeStore()
        await store.refresh(key)
        let finding = ReviewComment(author: "reviewer:claude", path: "a.swift", startLine: 2, endLine: nil, revision: "rev1",
                                    quote: [], body: "Fix it.", state: .new, fingerprint: "fp")
        store.update(key) { $0.comments.append(finding) }
        await settle(store)
        // The Mac sent it meanwhile; the phone still shows it as new.
        FakeReviewHub.change(key) { $0.items[0].state = "sent"; $0.items[0].batchId = "mac-batch" }
        do {
            try await ReviewItemSender.send(finding.id, conversation: phoneConversation(), store: store, hubOffline: false,
                                            config: host) { _, _ in
                XCTFail("typed twice")
                return SSHExecResult(exitCode: 0, stdout: "", stderr: "")
            }
            XCTFail("no conflict")
        } catch {}
        XCTAssertEqual(FakeReviewHub.record(key).items[0].batchId, "mac-batch")
        XCTAssertEqual(store.record(key).comments[0].state, .sent, "the list shows it as it is now")

        // A send that fails puts it back.
        FakeReviewHub.change(key) { $0.items[0].state = "new"; $0.items[0].batchId = nil }
        await store.refresh(key)
        do {
            try await ReviewItemSender.send(finding.id, conversation: phoneConversation(), store: store, hubOffline: false,
                                            config: host) { _, command in
                SSHExecResult(exitCode: command.contains(" send ") ? 66 : 0, stdout: "", stderr: "")
            }
            XCTFail("sent to a missing session")
        } catch {}
        XCTAssertEqual(FakeReviewHub.record(key).items[0].state, "new")
        XCTAssertNil(FakeReviewHub.record(key).items[0].batchId)
    }

    func testAMixedBatchLetsTheGoodRowsThrough() async throws {
        let (store, _) = makeStore()
        await store.refresh(key)
        let good = comment("good")
        var bad = comment("bad")
        bad.path = "refuse-me"
        store.update(key) { $0.comments += [good, bad] }
        await settle(store)
        XCTAssertEqual(FakeReviewHub.record(key).items.map(\.body), ["good"])
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.isSyncing(key), "a refused row isn't retried forever")
        // Later changes still go.
        store.update(key) { $0.comments.append(self.comment("later")) }
        await settle(store)
        XCTAssertEqual(FakeReviewHub.record(key).items.map(\.body).sorted(), ["good", "later"])
    }
}

/// `/api/reviews` in memory: GET returns a conversation's rows, POST /batch applies a batch.
private final class FakeReviewHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [String: HubReviewRecord] = [:]
    nonisolated(unsafe) private static var unreachable = false
    /// Answers 404, like a hub from before reviews.
    nonisolated(unsafe) private static var missing = false

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        records = [:]
        unreachable = false
        missing = false
    }

    static func setUnreachable(_ value: Bool) { lock.lock(); unreachable = value; lock.unlock() }
    static func setMissing(_ value: Bool) { lock.lock(); missing = value; lock.unlock() }

    static func record(_ key: String) -> HubReviewRecord {
        lock.lock(); defer { lock.unlock() }
        return records[key] ?? HubReviewRecord()
    }

    static func change(_ key: String, _ body: (inout HubReviewRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var record = records[key] ?? HubReviewRecord()
        body(&record)
        records[key] = record
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let (unreachable, missing) = (Self.unreachable, Self.missing)
        Self.lock.unlock()
        if unreachable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let url = request.url!
        var code = 200
        var body = Data("{}".utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if missing {
            code = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
        } else if request.httpMethod == "GET", url.path == "/api/reviews" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "conversation_id" }?.value ?? ""
            body = try! encoder.encode(Self.record(id))
        } else if request.httpMethod == "PATCH", url.path.hasPrefix("/api/review-items/"), let data = bodyData(),
                  let patch = try? decoder.decode(UpdateReviewItemRequest.self, from: data) {
            let id = url.lastPathComponent
            Self.lock.lock()
            var found: HubReviewItem?
            for key in Self.records.keys {
                guard let index = Self.records[key]?.items.firstIndex(where: { $0.id == id }) else { continue }
                var item = Self.records[key]!.items[index]
                if let expected = patch.expectedState, expected != item.state {
                    code = 409
                    break
                }
                if let state = patch.state { item.state = state }
                if patch.clearSent == true { item.sentAt = nil; item.sentInTurn = nil; item.batchId = nil; item.sentRevision = nil }
                if let value = patch.sentAt { item.sentAt = value }
                if let value = patch.sentInTurn { item.sentInTurn = value }
                if let value = patch.batchId { item.batchId = value }
                if let value = patch.sentRevision { item.sentRevision = value }
                Self.records[key]!.items[index] = item
                found = item
            }
            Self.lock.unlock()
            if code == 200 {
                if let found { body = try! encoder.encode(found) } else { code = 404 }
            } else {
                body = Data(#"{"error":"changed"}"#.utf8)
            }
        } else if request.httpMethod == "POST", url.path == "/api/reviews/batch", let data = bodyData(),
                  let batch = try? decoder.decode(ReviewBatchRequest.self, from: data),
                  batch.items.contains(where: { $0.path == "refuse-me" }) {
            code = 400
            body = Data(#"{"error":"path refused"}"#.utf8)
        } else if request.httpMethod == "POST", url.path == "/api/reviews/batch", let data = bodyData(),
                  let batch = try? decoder.decode(ReviewBatchRequest.self, from: data) {
            Self.lock.lock()
            for item in batch.items {
                var record = Self.records[item.conversationId] ?? HubReviewRecord()
                record.items.removeAll { $0.id == item.id }
                record.items.append(item)
                Self.records[item.conversationId] = record
            }
            for review in batch.reviews {
                var record = Self.records[review.conversationId] ?? HubReviewRecord()
                record.reviews.removeAll { $0.id == review.id }
                record.reviews.append(review)
                Self.records[review.conversationId] = record
            }
            for key in Self.records.keys {
                Self.records[key]?.items.removeAll { batch.deleteItems.contains($0.id) }
            }
            Self.lock.unlock()
        } else {
            code = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func bodyData() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
