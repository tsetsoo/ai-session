import XCTest
@testable import AISessionCore

final class TodoAddFormTests: XCTestCase {
    func testInsideAProjectAsksOnlyForATitle() {
        XCTAssertEqual(TodoAddForm.fields(inProject: true, inSection: true, hasComputer: true), .titleOnly)
    }

    func testInsideASectionAsksForAProjectThenATitle() {
        XCTAssertEqual(TodoAddForm.fields(inProject: false, inSection: true, hasComputer: true), .projectAndTitle)
    }

    func testWithNoSectionAsksForASection() {
        XCTAssertEqual(TodoAddForm.fields(inProject: false, inSection: false, hasComputer: false), .sectionProjectAndTitle)
    }

    func testASectionWithNoComputerCannotSubmit() {
        XCTAssertFalse(TodoAddForm.canSubmit(title: "A", newProject: nil, hasComputer: false))
    }

    func testAnEmptyTitleOrNewProjectCannotSubmit() {
        XCTAssertFalse(TodoAddForm.canSubmit(title: "  ", newProject: nil, hasComputer: true))
        XCTAssertFalse(TodoAddForm.canSubmit(
            title: "A", newProject: TodoAddNewProject(name: "", folder: "~/code"), hasComputer: true
        ))
        XCTAssertFalse(TodoAddForm.canSubmit(
            title: "A", newProject: TodoAddNewProject(name: "App", folder: " "), hasComputer: true
        ))
        XCTAssertTrue(TodoAddForm.canSubmit(title: "A", newProject: nil, hasComputer: true))
        XCTAssertTrue(TodoAddForm.canSubmit(
            title: "A", newProject: TodoAddNewProject(name: "App", folder: "~/code"), hasComputer: true
        ))
    }
}
