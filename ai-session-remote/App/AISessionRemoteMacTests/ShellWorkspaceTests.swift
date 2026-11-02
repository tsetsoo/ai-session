import AISessionCore
import XCTest
@testable import AI_Session_Remote

@MainActor
final class ShellWorkspaceTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "shell-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testComputerPageSelectionTracksTheDetailWhenSwitchingToAShellAndBack() {
        let shellID = UUID()
        for page in [ComputerPage.otherSessions, .onThisComputer] {
            let pageDestination = ShellDestination.resolve(sidebar: .computer("mac"), page: page,
                                                           shellID: nil, todoID: "previous-todo")
            XCTAssertEqual(pageDestination, .computerPage(page))
            XCTAssertEqual(pageDestination.listTag, page.tag)

            let shellDestination = ShellDestination.resolve(sidebar: .computer("mac"), page: page,
                                                            shellID: shellID, todoID: "previous-todo")
            XCTAssertEqual(shellDestination, .shell(shellID))
            XCTAssertEqual(shellDestination.listTag, ComputerPage.shell.tag)
            XCTAssertNotEqual(shellDestination.listTag, pageDestination.listTag)
            XCTAssertFalse(shellDestination.showsConversation)

            // Back retains the page underneath; selecting that page after the shell now also
            // changes the list selection, so the binding delivers the navigation event.
            let returned = ShellDestination.resolve(sidebar: .computer("mac"), page: page,
                                                    shellID: nil, todoID: "previous-todo")
            XCTAssertEqual(returned, pageDestination)
        }
    }

    func testPopOutOnlyTargetsTheVisibleConversation() {
        var opened: [String] = []
        let open: (String) -> Void = { opened.append($0) }
        let conversation = ShellDestination.resolve(sidebar: .section(.p), page: nil,
                                                      shellID: nil, todoID: "visible-todo")
        let action = conversation.popOutAction(open)
        XCTAssertNotNil(action)
        action?()
        XCTAssertEqual(opened, ["visible-todo"])

        for destination in [
            ShellDestination.resolve(sidebar: .section(.p), page: nil,
                                     shellID: UUID(), todoID: "hidden-todo"),
            .resolve(sidebar: .computer("mac"), page: .otherSessions,
                     shellID: nil, todoID: "hidden-todo"),
            .resolve(sidebar: .projects, page: nil, shellID: nil, todoID: "hidden-todo"),
            .resolve(sidebar: .review, page: nil, shellID: nil, todoID: nil),
        ] {
            XCTAssertNil(destination.popOutAction(open))
        }
        XCTAssertEqual(opened, ["visible-todo"])
    }

    func testReturningToCompactShellScreenKeepsItsCurrentSelection() throws {
        let workspace = ShellWorkspace(defaults: try isolatedDefaults())
        let host = UUID()
        let first = workspace.create(hostID: host, computerName: "Mac")
        let second = workspace.create(hostID: host, computerName: "Mac")
        workspace.rememberSelection(first.id, for: host)
        XCTAssertEqual(workspace.selection(for: host, current: second.id), second.id)
    }

    func testReopeningCompactShellScreenRestoresEachHostsChoiceAndHandlesRemoval() throws {
        let defaults = try isolatedDefaults()
        let workspace = ShellWorkspace(defaults: defaults)
        let host = UUID(), otherHost = UUID()
        let first = workspace.create(hostID: host, computerName: "Mac")
        let second = workspace.create(hostID: host, computerName: "Mac")
        let other = workspace.create(hostID: otherHost, computerName: "Other Mac")
        workspace.rememberSelection(second.id, for: host)
        workspace.rememberSelection(other.id, for: host)
        let restored = ShellWorkspace(defaults: defaults)
        XCTAssertEqual(restored.selection(for: host), second.id)
        XCTAssertEqual(restored.selection(for: otherHost), other.id)
        XCTAssertEqual(restored.selection(for: host, current: other.id), second.id)
        restored.forget(second)
        XCTAssertEqual(restored.selection(for: host, current: second.id), first.id)
        XCTAssertEqual(ShellWorkspace(defaults: defaults).selection(for: host), first.id)
        restored.forget(first)
        XCTAssertNil(restored.selection(for: host))
        XCTAssertEqual(restored.selection(for: otherHost), other.id)
    }

    func testShellsKeepSeparateHostsAndRestoreTheSameTmuxTargets() throws {
        let suite = "shell-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = ShellWorkspace(defaults: defaults)
        let firstHost = UUID(), secondHost = UUID()
        let first = workspace.create(hostID: firstHost, computerName: "First Mac")
        let second = workspace.create(hostID: firstHost, computerName: "First Mac")
        let other = workspace.create(hostID: secondHost, computerName: "Second Mac")
        XCTAssertEqual([first.title, second.title, other.title], ["Shell 1", "Shell 2", "Shell 1"])
        XCTAssertEqual(Set(workspace.shells.map(\.tmuxName)).count, 3)
        workspace.selectedID = first.id
        workspace.selectedID = nil // Visiting a todo only detaches the client.
        let restored = ShellWorkspace(defaults: defaults)
        XCTAssertEqual(restored.shells, workspace.shells)
        XCTAssertNil(restored.selectedID)
        workspace.selectedID = second.id
        workspace.forget(first)
        XCTAssertEqual(workspace.selectedID, second.id)
        workspace.forget(second)
        XCTAssertNil(workspace.selectedID)
        XCTAssertEqual(ShellWorkspace(defaults: defaults).shells, [other])
    }
}
