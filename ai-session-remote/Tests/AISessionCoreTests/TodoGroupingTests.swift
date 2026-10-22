import XCTest
@testable import AISessionCore

final class TodoGroupingTests: XCTestCase {
    private let mac = Computer(id: "m1", name: "Mac", hostname: "mac", username: "me")

    private func todo(_ id: String, project: String? = nil, done: Bool = false, created: String) -> Todo {
        Todo(id: id, section: .i, title: id, completed: done, createdAt: created, projectId: project)
    }

    private func project(_ id: String, _ name: String) -> Project {
        Project(id: id, name: name, computer: mac, folder: "~/\(id)")
    }

    func testByProjectOrdersProjectsByNameThenNoProject() {
        let projects = [project("p2", "website"), project("p1", "API"), project("p3", "Empty")]
        let todos = [
            todo("loose", created: "2026-10-20"),
            todo("gone-project", project: "deleted", created: "2026-10-21"),
            todo("web-old", project: "p2", created: "2026-10-01"),
            todo("web-new", project: "p2", created: "2026-10-10"),
            todo("api", project: "p1", created: "2026-10-05"),
            todo("api-done", project: "p1", done: true, created: "2026-10-22"),
        ]
        let groups = TodoGrouping.byProject(todos, projects: projects)
        XCTAssertEqual(groups.map(\.title), ["API", "website", "No project"], "empty projects are left out")
        XCTAssertEqual(groups.map { $0.todos.map(\.id) }, [["api"], ["web-new", "web-old"], ["gone-project", "loose"]])
    }

    func testByProjectWithoutLooseTodosHasNoNoProjectGroup() {
        let groups = TodoGrouping.byProject([todo("a", project: "p1", created: "1")], projects: [project("p1", "A")])
        XCTAssertEqual(groups.map(\.id), ["p1"])
        XCTAssertTrue(TodoGrouping.byProject([], projects: [project("p1", "A")]).isEmpty)
    }

    func testByStatusFollowsConversationTabOrderAndClosedCountsAsNone() {
        let statuses: [String: ConversationDisplayStatus] = [
            "working": .working, "asks": .needsYou, "idle": .idle, "closed": .closed, "done": .needsYou,
        ]
        let todos = [
            todo("none", created: "2026-10-01"),
            todo("closed", created: "2026-10-02"),
            todo("working", created: "2026-10-03"),
            todo("idle", created: "2026-10-04"),
            todo("asks", created: "2026-10-05"),
            todo("done", done: true, created: "2026-10-06"),
        ]
        let groups = TodoGrouping.byStatus(todos) { statuses[$0] }
        XCTAssertEqual(groups.map(\.status), [.needsYou, .review, .working, .noConversation])
        XCTAssertEqual(groups.map { $0.todos.map(\.id) }, [["asks"], ["idle"], ["working"], ["closed", "none"]])
        XCTAssertEqual(groups.map(\.status.label), ["Needs you", "Ready for review", "Working", "No conversation"])
    }

    func testByStatusLeavesOutEmptyGroups() {
        let groups = TodoGrouping.byStatus([todo("a", created: "1")]) { _ in nil }
        XCTAssertEqual(groups.map(\.status), [.noConversation])
    }
}
