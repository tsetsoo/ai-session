@testable import AISessionCore
import XCTest

final class TodayTests: XCTestCase {
    private let decoder = TodoHubClient.makeDecoder()

    static let reminderJSON = """
    {"id":"r1","title":"Call the accountant","notes":"VAT","at":"2026-11-06 10:00","next_at":"2026-11-06T08:00:00Z",
     "repeat":"weekly","state":"due","source":"agent","created_at":"x","updated_at":"x"}
    """
    static let personJSON = """
    {"id":"p1","name":"Maria","kind":"birthday","month":3,"day":14,"year":1991,"notes":"","source":"manual",
     "next_date":"2027-03-14","turns":36,"created_at":"x","updated_at":"x"}
    """

    private func client() -> TodoHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TodoHubClient(baseURL: URL(string: "http://pi.tailnet:8080")!, token: "s3cret", session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    func testReminderAndPersonDecode() throws {
        let r = try decoder.decode(Reminder.self, from: Data(Self.reminderJSON.utf8))
        XCTAssertEqual(r.repeat, .weekly)
        XCTAssertTrue(r.isDue)
        XCTAssertEqual(r.time, "10:00")
        let p = try decoder.decode(Person.self, from: Data(Self.personJSON.utf8))
        XCTAssertEqual(p.kind, .birthday)
        XCTAssertEqual(p.turns, 36)
        XCTAssertEqual(p.dateText, "14 Mar 1991")
        XCTAssertEqual(ReminderRepeat.weekdays.label, "Weekdays")
    }

    func testSnoozeTimesInSofia() {
        // 2026-11-03 14:20 in Sofia (UTC+2).
        let now = ISO8601DateFormatter().date(from: "2026-11-03T12:20:00Z")!
        XCTAssertEqual(SnoozeOption.hour.until(now: now), "2026-11-03 15:20")
        XCTAssertEqual(SnoozeOption.evening.until(now: now), "2026-11-03 18:00")
        XCTAssertEqual(SnoozeOption.tomorrow.until(now: now), "2026-11-04 09:00")
        let late = ISO8601DateFormatter().date(from: "2026-11-03T17:30:00Z")!  // 19:30 Sofia
        XCTAssertFalse(SnoozeOption.available(now: late).contains(.evening), "no 'this evening' after 18:00")
    }

    func testDraftsValidate() {
        var r = ReminderDraft()
        XCTAssertFalse(r.canSave)
        r.title = "Dentist"
        XCTAssertTrue(r.canSave)
        XCTAssertEqual(r.request.repeat, "none")
        var p = PersonDraft()
        p.name = "Maria"
        p.month = 2
        p.day = 30
        XCTAssertFalse(p.canSave, "30 Feb is not a date")
        p.day = 29
        XCTAssertTrue(p.canSave)
        p.hasYear = true
        p.year = 2023
        XCTAssertFalse(p.canSave, "2023 has no 29 Feb")
    }

    func testBriefingDecodesAndIsEmpty() throws {
        let json = """
        {"reminders":[\(Self.reminderJSON)],"dates":["Tomorrow: Maria turns 36"],"people":[\(Self.personJSON)],
         "ready_for_review":[{"todo_id":"t1","title":"Nightly"}],"needs_you":2,
         "watch":{"waiting":1,"working":0,"needs_you":0,"cant_fix":0,"fixed":3,"resolving":0}}
        """
        let b = try decoder.decode(Briefing.self, from: Data(json.utf8))
        XCTAssertFalse(b.isEmpty)
        XCTAssertEqual(b.readyForReview.first?.todoId, "t1")
        XCTAssertEqual(b.watch.fixed, 3)
        let empty = try decoder.decode(Briefing.self, from: Data(#"{"reminders":[],"dates":[],"people":[],"ready_for_review":[],"needs_you":0,"watch":{"waiting":0,"working":0,"needs_you":0,"cant_fix":0,"fixed":0,"resolving":0}}"#.utf8))
        XCTAssertTrue(empty.isEmpty)
    }

    func testConversationActionModelAndAutoTool() throws {
        let json = #"{"kind":"conversation","project_id":"p","computer_id":null,"tool":"auto","folder":null,"prompt":"x","priority":"urgent","limit":{"mode":"always"},"model":"haiku"}"#
        guard case let .conversation(a) = try decoder.decode(JobAction.self, from: Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(a.tool, "auto")
        XCTAssertEqual(a.model, "haiku")
    }

    func testClientRoutes() async throws {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/reminders": .init(status: 200, body: "[\(Self.reminderJSON)]")
            case "/api/people": .init(status: 200, body: "[\(Self.personJSON)]")
            case "/api/today/settings": .init(status: 200, body: #"{"briefing_enabled":true,"briefing_time":"08:00","assistant_model":"auto","claude_model":"haiku","codex_model":"gpt-6.1-terra"}"#)
            case "/api/today/assistant": .init(status: 200, body: #"{"id":"run1","job_id":"j","due_at":"x","state":"due","created_at":"x","updated_at":"x"}"#)
            default: .init(status: 200, body: Self.reminderJSON)
            }
        }
        let c = client()
        let reminders = try await c.listReminders()
        let people = try await c.listPeople()
        let settings = try await c.todaySettings()
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(people.first?.name, "Maria")
        XCTAssertEqual(settings.assistantModel, "auto")
        _ = try await c.snoozeReminder(id: "r1", until: "2026-11-03 18:00")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/reminders/r1/snooze")
        _ = try await c.doneReminder(id: "r1")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/reminders/r1/done")
        _ = try await c.startAssistant(text: "dentist Tue", kind: "reminder")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requests.last?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "dentist Tue")
        XCTAssertEqual(body["kind"] as? String, "reminder")
    }
}

final class JobTemplateTests: XCTestCase {
    static let json = """
    [{"name":"memory-gardener","title":"Memory gardener","description":"Tends memories.","cron":"0 3 * * 0","tool":"claude",
      "model":null,"priority":"background","limit":"wait","project":"ai-session","prompt":"Tend them.","computer_id":"mac"},
     {"name":"weekly-upkeep","title":"Weekly upkeep","description":"Deps.","cron":"0 10 * * 0","tool":"claude",
      "model":"sonnet","priority":"urgent","limit":"always","project":"choose","prompt":"Check deps.","computer_id":"mac"}]
    """

    func testTemplateBecomesDraft() throws {
        let templates = try TodoHubClient.makeDecoder().decode([JobTemplate].self, from: Data(Self.json.utf8))
        let projects: [(id: String, name: String)] = [("p1", "programming"), ("p2", "ai-session")]
        let gardener = JobDraft(template: templates[0], projects: projects)
        XCTAssertEqual(gardener.name, "Memory gardener")
        XCTAssertEqual(gardener.kind, .conversation)
        XCTAssertEqual(gardener.cron, "0 3 * * 0")
        XCTAssertEqual(gardener.projectId, "p2", "the manifest's default project")
        XCTAssertEqual(gardener.computerId, "mac")
        XCTAssertEqual(gardener.prompt, "Tend them.")
        XCTAssertTrue(gardener.waits)
        XCTAssertEqual(gardener.priority, .background)
        XCTAssertTrue(gardener.canSave)
        let upkeep = JobDraft(template: templates[1], projects: projects)
        XCTAssertEqual(upkeep.projectId, "", "choose: the user picks")
        XCTAssertFalse(upkeep.canSave)
        XCTAssertFalse(upkeep.waits)
        XCTAssertEqual(upkeep.priority, .urgent)
        guard case let .conversation(action) = { var d = upkeep; d.projectId = "p1"; return d }().action else { return XCTFail() }
        XCTAssertEqual(action.model, "sonnet")
    }
}
