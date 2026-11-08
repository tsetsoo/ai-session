import XCTest
@testable import AISessionCore

/// Research Now asks which agents to use: defaults, limits, model names and what is sent.
final class ResearchAgentsTests: XCTestCase {
    private func rows(_ tools: [String]) -> [ResearchAgentRow] {
        tools.map { ResearchAgentRow(tool: $0) }
    }

    func testDefaultsAreClaudeAndCodex() {
        XCTAssertEqual(ResearchAgents.defaults(offered: ["claude", "codex", "cursor"]).map(\.tool), ["claude", "codex"])
        XCTAssertEqual(ResearchAgents.defaults(offered: ["claude", "codex", "cursor"]).map(\.model), ["", ""])
        XCTAssertEqual(ResearchAgents.defaults(offered: ["claude"]).map(\.tool), ["claude"])
        XCTAssertEqual(ResearchAgents.defaults(offered: ["cursor"]).map(\.tool), ["cursor"], "never an empty sheet")
    }

    func testOfferedTools() {
        XCTAssertEqual(ResearchAgents.offeredTools(installed: nil, cursorSupported: true), ["claude", "codex", "cursor"])
        XCTAssertEqual(ResearchAgents.offeredTools(installed: nil, cursorSupported: false), ["claude", "codex"])
        XCTAssertEqual(ResearchAgents.offeredTools(installed: ["codex"], cursorSupported: true), ["codex"])
        XCTAssertEqual(ResearchAgents.offeredTools(installed: ["cursor", "claude"], cursorSupported: true), ["claude", "cursor"])
    }

    func testRowLimits() {
        XCTAssertTrue(ResearchAgents.canAdd(rows(Array(repeating: "claude", count: 9))))
        XCTAssertFalse(ResearchAgents.canAdd(rows(Array(repeating: "claude", count: 10))))
        XCTAssertFalse(ResearchAgents.canRemove(rows(["claude"])))
        XCTAssertTrue(ResearchAgents.canRemove(rows(["claude", "codex"])))
    }

    func testModelValidation() {
        XCTAssertTrue(ResearchAgents.isValidModel("opus[1m]"))
        XCTAssertTrue(ResearchAgents.isValidModel(""))
        XCTAssertTrue(ResearchAgents.isValidModel(" gpt-6.1 "))
        XCTAssertFalse(ResearchAgents.isValidModel("a b"))
        XCTAssertFalse(ResearchAgents.isValidModel("x;y"))
        XCTAssertFalse(ResearchAgents.isValidModel(String(repeating: "m", count: 81)))
    }

    func testCountText() {
        XCTAssertEqual(ResearchAgents.countText(1), "Starts 1 conversation.")
        XCTAssertEqual(ResearchAgents.countText(3), "Starts 3 conversations.")
    }

    func testRequestOmitsEmptyModel() {
        let request = ResearchAgents.request(
            rows: [ResearchAgentRow(tool: "claude", model: "  "), ResearchAgentRow(tool: "codex", model: " gpt-6.1 ")], computerId: "mac")
        XCTAssertEqual(request, ResearchRequest(computerId: "mac", attempts: [AttemptSpec(tool: "claude"), AttemptSpec(tool: "codex", model: "gpt-6.1")]))
    }

    func testLegacyResearchAnswerIsReported() {
        let run = JobRun(id: "r", jobId: "j", dueAt: "x", state: "due", createdAt: "x", updatedAt: "x")
        XCTAssertNil(ResearchAgents.legacyWarning(.legacy(run), rows: rows(["claude"])))
        XCTAssertEqual(
            ResearchAgents.legacyWarning(.legacy(run), rows: rows(["claude", "codex"])),
            "This hub started Claude only. Update the hub to research with several agents.")
        XCTAssertEqual(
            ResearchAgents.legacyWarning(.legacy(run), rows: [ResearchAgentRow(tool: "claude", model: "opus")]),
            "This hub started Claude only. Update the hub to research with several agents.", "the model was dropped too")
        XCTAssertNil(ResearchAgents.legacyWarning(.group(ResearchStart(groupId: "g", todoId: "t", runs: [run])), rows: rows(["claude", "codex"])))
    }

    func testAttemptLabels() {
        XCTAssertEqual(ResearchAgents.label(IdeaAttempt(runId: "r", tool: "codex", model: "gpt-6.1", state: "done")), "Codex · gpt-6.1")
        XCTAssertEqual(ResearchAgents.label(IdeaAttempt(runId: "r", tool: "claude", state: "done")), "Claude · default")
        XCTAssertEqual(ResearchAgents.stateText(IdeaAttempt(runId: "r", tool: "claude", state: "due")), "Waiting to start")
        XCTAssertEqual(ResearchAgents.stateText(IdeaAttempt(runId: "r", tool: "claude", state: "running")), "Starting…")
        XCTAssertEqual(ResearchAgents.stateText(IdeaAttempt(runId: "r", tool: "claude", state: "done")), "Working…")
        XCTAssertEqual(ResearchAgents.stateText(IdeaAttempt(runId: "r", tool: "claude", state: "failed", result: "no folder")), "Failed: no folder")
        XCTAssertNil(ResearchAgents.stateText(IdeaAttempt(runId: "r", tool: "claude", state: "done", findings: "x")))
    }

    func testMissedAttemptCanBeRetried() {
        let missed = IdeaAttempt(runId: "r", tool: "codex", state: "missed")
        XCTAssertEqual(ResearchAgents.stateText(missed), "Didn't start: its computer didn't pick it up in time")
        XCTAssertTrue(ResearchAgents.canRetry(missed))
        XCTAssertTrue(ResearchAgents.canRetry(IdeaAttempt(runId: "r", tool: "codex", state: "failed")))
        XCTAssertFalse(ResearchAgents.canRetry(IdeaAttempt(runId: "r", tool: "codex", state: "done")))
    }

    func testFindingsSavedOnTheIdeaOnlyAreShown() {
        let attempts = [IdeaAttempt(runId: "r1", tool: "claude", state: "done", findings: "A"), IdeaAttempt(runId: "r2", tool: "codex", state: "done")]
        XCTAssertNil(ResearchAgents.unattributedFindings("A", attempts: attempts), "already shown under its attempt")
        XCTAssertEqual(ResearchAgents.unattributedFindings("From an older helper", attempts: attempts), "From an older helper")
        XCTAssertNil(ResearchAgents.unattributedFindings("  ", attempts: attempts))
        XCTAssertNil(ResearchAgents.unattributedFindings(String?.none, attempts: attempts))
    }
}
