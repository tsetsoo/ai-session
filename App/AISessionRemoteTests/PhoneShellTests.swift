import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class PhoneShellTests: XCTestCase {
    // MARK: Conversations filter

    func testConversationsDefaultToNeedsYouOnlyWhenSomethingNeedsYou() {
        XCTAssertEqual(ConversationListView.Filter.initial(needsYouCount: 2), .needsYou)
        XCTAssertEqual(ConversationListView.Filter.initial(needsYouCount: 0), .running)
    }

    // MARK: Quick-add

    func testQuickAddSectionDefaultsToI() {
        XCTAssertEqual(QuickAdd.section(from: "Sp"), .sp)
        XCTAssertEqual(QuickAdd.section(from: "P"), .p)
        XCTAssertEqual(QuickAdd.section(from: ""), .i)
        XCTAssertEqual(QuickAdd.section(from: "sp"), .i)
    }

    func testDictationGoesAfterTypedText() {
        XCTAssertEqual(QuickAdd.text(typed: "", dictated: "call Santé"), "call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo:", dictated: "call Santé"), "Todo: call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo: ", dictated: "call Santé"), "Todo: call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo:", dictated: ""), "Todo:")
    }
}
