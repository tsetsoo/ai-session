@testable import AISessionCore
import XCTest

final class AutomationModelTests: XCTestCase {
    private let decoder = TodoHubClient.makeDecoder()

    private func idea(_ id: String, project: String, status: String = "new", pending: Bool = false) throws -> Idea {
        let json = """
        {"id":"\(id)","project_id":"\(project)","title":"\(id)","notes":"","status":"\(status)","starred":false,
         "pending":\(pending),"findings":null,"todo_id":null,"run_id":null,"source":"manual","created_at":"x","updated_at":"x"}
        """
        return try decoder.decode(Idea.self, from: Data(json.utf8))
    }

    private func project(_ id: String, name: String) throws -> Project {
        let json = ProjectsClientTests.projectJSON
            .replacingOccurrences(of: #""id":"p1""#, with: #""id":"\#(id)""#)
            .replacingOccurrences(of: #""name":"sigma-revenue""#, with: #""name":"\#(name)""#)
        return try decoder.decode(Project.self, from: Data(json.utf8))
    }

    func testIdeaFilterAndGrouping() throws {
        let ideas = [
            try idea("a", project: "p2"), try idea("b", project: "p1", status: "researched"),
            try idea("c", project: "p1", pending: true), try idea("d", project: "p1", status: "dropped"),
            try idea("e", project: "gone"),
        ]
        XCTAssertEqual(ideas.filter(IdeaFilter.all.matches).map(\.id), ["a", "b", "e"], "All hides dropped and waiting")
        XCTAssertEqual(ideas.filter(IdeaFilter.waiting.matches).map(\.id), ["c"])
        XCTAssertEqual(ideas.filter(IdeaFilter.dropped.matches).map(\.id), ["d"])
        XCTAssertEqual(ideas.filter(IdeaFilter.researched.matches).map(\.id), ["b"])
        let groups = IdeaGrouping.byProject(ideas.filter(IdeaFilter.all.matches),
                                            projects: [try project("p1", name: "zeta"), try project("p2", name: "alpha")])
        XCTAssertEqual(groups.map { $0.project?.name }, ["alpha", "zeta", nil], "by name, unknown last")
        XCTAssertEqual(groups.map { $0.ideas.map(\.id) }, [["a"], ["b"], ["e"]])
        XCTAssertEqual(IdeaFilter.waiting.label, "Waiting for OK")
    }

    func testJobDecodesWithoutScheduleText() throws {
        let job = try decoder.decode(SchedulerJob.self, from: Data(JobsClientTests.conversationJobJSON.utf8))
        XCTAssertNil(job.scheduleText)
        XCTAssertEqual(ScheduleLabel.text(for: job), "Cron 0 8 * * *")
        var named = job
        named.scheduleText = "Every day at 08:00"
        XCTAssertEqual(ScheduleLabel.text(for: named), "Every day at 08:00")
    }

    func testRecentRunsDecode() throws {
        let json = #"[{"id":"r1","job_id":"j","due_at":"x","state":"done","computer_id":null,"todo_id":null,"waiting_reason":null,"result":"ok","started_at":null,"created_at":"x","updated_at":"x","note":null,"job_name":"Research"}]"#
        let runs = try decoder.decode([RecentRun].self, from: Data(json.utf8))
        XCTAssertEqual(runs[0].jobName, "Research")
        XCTAssertEqual(runs[0].run.state, "done")
        XCTAssertEqual(runs[0].id, "r1")
    }

    func testJobDraftIsDirty() throws {
        let job = try decoder.decode(SchedulerJob.self, from: Data(JobsClientTests.conversationJobJSON.utf8))
        let original = JobDraft(job: job)
        var draft = original
        XCTAssertFalse(draft.isDirty(comparedTo: original))
        draft.prompt += " more"
        XCTAssertTrue(draft.isDirty(comparedTo: original))
        XCTAssertFalse(JobDraft().isDirty(comparedTo: JobDraft()))
    }

    func testJobDraftRoundTripsResearchJob() throws {
        var draft = JobDraft()
        draft.name = "Research"
        draft.kind = .research
        draft.projectId = "p"
        draft.prompt = ""
        draft.usesCron = false
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.trigger, .manual)
        guard case let .research(parts) = draft.action else { return XCTFail("\(draft.action)") }
        XCTAssertEqual(parts.projectId, "p")
        draft.kind = .conversation
        XCTAssertFalse(draft.canSave, "a conversation needs a prompt")
    }
}
