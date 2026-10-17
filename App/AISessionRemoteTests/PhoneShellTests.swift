import AISessionCore
import UserNotifications
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

    // MARK: Local notifier

    private final class FakeCenter: LocalNotificationScheduling {
        var added: [UNNotificationRequest] = []
        var grant = true
        var authorizationRequests = 0
        var onAdd: (() -> Void)?

        func add(_ request: UNNotificationRequest) async throws {
            added.append(request)
            onAdd?()
        }

        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            authorizationRequests += 1
            return grant
        }
    }

    private func makeNotifier(_ center: FakeCenter) -> (LocalNeedsYouNotifier, UserDefaults) {
        let suite = "PhoneShellTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (LocalNeedsYouNotifier(defaults: defaults, center: { center }), defaults)
    }

    func testRequestUsesTheCoordinatorIdentifiers() {
        let request = LocalNeedsYouNotifier.request(todoId: "t1", title: "Fix the rate import", body: "Needs you")
        XCTAssertEqual(request.identifier, "todo-t1")
        XCTAssertEqual(request.content.threadIdentifier, "t1")
        XCTAssertEqual(request.content.userInfo as? [String: String], ["todo_id": "t1"])
        XCTAssertEqual(request.content.title, "Fix the rate import")
        XCTAssertEqual(request.content.body, "Needs you")
        XCTAssertNil(request.trigger)
    }

    func testPostsOnlyWhenEnabledAndNotOnScreen() {
        let (notifier, defaults) = makeNotifier(FakeCenter())
        XCTAssertFalse(notifier.shouldPost(todoId: "t1"), "off by default")
        defaults.set(true, forKey: NeedsYouSettings.enabledKey)
        XCTAssertTrue(notifier.shouldPost(todoId: "t1"))
        notifier.setVisibleConversation(todoId: "t1")
        XCTAssertFalse(notifier.shouldPost(todoId: "t1"))
        XCTAssertTrue(notifier.shouldPost(todoId: "t2"))
        notifier.setVisibleConversation(todoId: nil)
        XCTAssertTrue(notifier.shouldPost(todoId: "t1"))
    }

    func testPostWaitingAddsTheRequest() async {
        let center = FakeCenter()
        let (notifier, defaults) = makeNotifier(center)
        defaults.set(true, forKey: NeedsYouSettings.enabledKey)
        let added = expectation(description: "added")
        center.onAdd = { added.fulfill() }
        notifier.postWaiting(todoId: "t3", sessionId: "s3", title: "Draft the HTIF follow-up", body: "Needs you")
        await fulfillment(of: [added], timeout: 2)
        XCTAssertEqual(center.added.map(\.identifier), ["todo-t3"])
    }

    func testEnablingAsksForPermissionAndRecordsTheAnswer() async {
        let center = FakeCenter()
        let (notifier, defaults) = makeNotifier(center)
        center.grant = false
        let refused = await notifier.setNeedsYouEnabled(true)
        XCTAssertFalse(refused)
        XCTAssertFalse(defaults.bool(forKey: NeedsYouSettings.enabledKey))

        center.grant = true
        let granted = await notifier.setNeedsYouEnabled(true)
        XCTAssertTrue(granted)
        XCTAssertTrue(defaults.bool(forKey: NeedsYouSettings.enabledKey))

        let off = await notifier.setNeedsYouEnabled(false)
        XCTAssertTrue(off)
        XCTAssertFalse(defaults.bool(forKey: NeedsYouSettings.enabledKey))
        XCTAssertEqual(center.authorizationRequests, 2, "turning off never asks")
    }

    func testLocalNotifierCannotMute() {
        let (notifier, _) = makeNotifier(FakeCenter())
        XCTAssertFalse(notifier.supportsMuting)
        XCTAssertEqual(notifier.pushStatusText, "Alerts come from this device.")
    }
}
