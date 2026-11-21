import AISessionCore
import XCTest
@testable import AISessionRemote

@MainActor
final class PhoneShellTests: XCTestCase {
    // MARK: Conversations filter

    func testConversationsDefaultToNeedsYouOnlyWhenSomethingNeedsYou() {
        XCTAssertEqual(ConversationListView.Filter.initial(needsYouCount: 2), .needsYou)
        XCTAssertEqual(ConversationListView.Filter.initial(needsYouCount: 0), .review)
    }

    // MARK: Quick-add

    func testDictationGoesAfterTypedText() {
        XCTAssertEqual(QuickAdd.text(typed: "", dictated: "call Santé"), "call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo:", dictated: "call Santé"), "Todo: call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo: ", dictated: "call Santé"), "Todo: call Santé")
        XCTAssertEqual(QuickAdd.text(typed: "Todo:", dictated: ""), "Todo:")
    }
}
