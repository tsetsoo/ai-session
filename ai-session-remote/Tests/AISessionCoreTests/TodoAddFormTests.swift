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

    func testAProjectRowShowsTheSectionCode() {
        XCTAssertEqual(TodoProjectMenuTitle.row(section: .sp, name: "sigma"), "Sp · sigma")
        XCTAssertEqual(TodoProjectMenuTitle.row(section: .i, name: "notes"), "I · notes")
    }

    func testTheDefaultProjectIsTheFirstOrNewWhenThereAreNone() {
        var choice = TodoAddProjectChoice()
        choice.pickDefault(among: ["a", "b"])
        XCTAssertEqual(choice.projectID, "a")
        XCTAssertFalse(choice.makingNew)

        var empty = TodoAddProjectChoice()
        empty.pickDefault(among: [])
        XCTAssertNil(empty.projectID)
        XCTAssertTrue(empty.makingNew)
    }

    func testAChoiceThatIsStillListedIsKept() {
        var choice = TodoAddProjectChoice()
        choice.choose("b")
        choice.pickDefault(among: ["a", "b"])
        XCTAssertEqual(choice.projectID, "b")

        choice.chooseNew()
        choice.pickDefault(among: ["a", "b"])
        XCTAssertTrue(choice.makingNew)
    }

    func testAChoiceThatIsNoLongerListedFallsBackToTheFirst() {
        var choice = TodoAddProjectChoice()
        choice.choose("gone")
        choice.pickDefault(among: ["a"])
        XCTAssertEqual(choice.projectID, "a")
    }

    func testClearingLeavesNothingChosenUntilTheNextDefault() {
        var choice = TodoAddProjectChoice()
        choice.chooseNew()
        choice.clear()
        XCTAssertFalse(choice.isChosen)
        choice.pickDefault(among: ["a"])
        XCTAssertEqual(choice.projectID, "a")
    }
}
