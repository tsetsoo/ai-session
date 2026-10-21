import XCTest
@testable import AISessionCore

final class ConversationIndexTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "Mac", hostname: "mac", username: "me")

    private func conv(_ id: String, _ status: ConversationStatus, updated: String?, created: String) -> Conversation {
        Conversation(
            id: id, todoId: "t", computer: mac, cwd: "~/x", tool: "claude", tmuxName: "t-\(id)",
            sessionId: id, status: status, statusUpdatedAt: updated, createdAt: created
        )
    }

    func testTitleUsesTheName() {
        XCTAssertEqual(RowText.conversationTitle(todoTitle: "PR 630 review", label: "duplicate"), "PR 630 review · duplicate")
        XCTAssertEqual(RowText.conversationTitle(todoTitle: "PR 630 review", label: nil), "PR 630 review")
    }

    func testProposalSkipsNamesAlreadyUsed() {
        XCTAssertEqual(DuplicateName.proposal(existingLabels: ["duplicate", "duplicate 2"]), "duplicate 3")
        XCTAssertEqual(DuplicateName.proposal(existingLabels: []), "duplicate")
    }

    func testMostUrgentPrefersNeedsYou() {
        let idle = conv("idle", .idle, updated: "2026-10-20T12:00:00Z", created: "2026-10-16T10:00:00Z")
        let waiting = conv("wait", .waiting, updated: "2026-10-20T08:00:00Z", created: "2026-10-16T09:00:00Z")
        XCTAssertEqual(ConversationIndex.mostUrgent([idle, waiting])?.id, "wait")

        let earlier = conv("a", .waiting, updated: "2026-10-20T08:00:00Z", created: "2026-10-16T09:00:00Z")
        let later = conv("b", .waiting, updated: "2026-10-20T09:00:00Z", created: "2026-10-16T08:00:00Z")
        XCTAssertEqual(ConversationIndex.mostUrgent([earlier, later])?.id, "b")
    }
}
