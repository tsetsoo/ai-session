import XCTest
@testable import AISessionCore

final class PushRegistrationStateTests: XCTestCase {
    private let hub = "http://pi:8080"

    func testSuccessRemembersTheHub() {
        var state = PushRegistrationState()
        XCTAssertEqual(state.launchState(enabled: true, hub: hub), .localOnly("Registering for push…"))
        let upload = state.beginUpload(hub: hub)
        XCTAssertNil(upload.previousHub)
        XCTAssertEqual(state.finishUpload(upload.id, hub: hub, error: nil, enabled: true), .apply(.registered))
        XCTAssertEqual(state.registeredHub, hub)
        XCTAssertEqual(state.launchState(enabled: true, hub: hub), .registered, "a known registration covers the next launch")
        XCTAssertEqual(state.launchState(enabled: true, hub: "http://other:8080"), .localOnly("Registering for push…"))
        XCTAssertEqual(state.launchState(enabled: false, hub: hub), .off)
    }

    func testSwitchingHubsNamesTheOldOneToUnregister() {
        var state = PushRegistrationState(registeredHub: hub)
        let upload = state.beginUpload(hub: "http://other:8080")
        XCTAssertEqual(upload.previousHub, hub)
        XCTAssertEqual(state.finishUpload(upload.id, hub: "http://other:8080", error: nil, enabled: true), .apply(.registered))
        XCTAssertNil(state.beginUpload(hub: "http://other:8080").previousHub)
    }

    func testTemporaryFailureKeepsAKnownRegistration() {
        var state = PushRegistrationState(registeredHub: hub)
        let upload = state.beginUpload(hub: hub).id
        XCTAssertEqual(
            state.finishUpload(upload, hub: hub, error: .unreachable("offline"), enabled: true),
            .apply(.registered),
            "the server still has the token: its push covers the alert"
        )
        XCTAssertTrue(state.needsRetry)
        let retry = state.beginUpload(hub: hub).id
        XCTAssertEqual(state.finishUpload(retry, hub: hub, error: nil, enabled: true), .apply(.registered))
        XCTAssertFalse(state.needsRetry)
    }

    func testTemporaryFailureWithoutRegistrationIsLocalOnly() {
        var state = PushRegistrationState()
        let upload = state.beginUpload(hub: hub).id
        guard case .apply(.localOnly) = state.finishUpload(upload, hub: hub, error: .server(status: 502, message: "x"), enabled: true) else {
            return XCTFail("expected local-only")
        }
        XCTAssertTrue(state.needsRetry)
    }

    func testDefiniteAnswersForgetTheRegistration() {
        for error in [TodoHubError.unsupported, .unauthorized, .badRequest("bad token")] {
            var state = PushRegistrationState(registeredHub: hub)
            let upload = state.beginUpload(hub: hub).id
            guard case .apply(.localOnly) = state.finishUpload(upload, hub: hub, error: error, enabled: true) else {
                return XCTFail("\(error) should be local-only")
            }
            XCTAssertNil(state.registeredHub, "\(error)")
            XCTAssertFalse(state.needsRetry, "\(error)")
        }
    }

    func testUploadFinishingAfterToggleOffIsUndone() {
        var state = PushRegistrationState()
        let upload = state.beginUpload(hub: hub).id
        state.disable()
        XCTAssertNil(state.registeredHub)
        XCTAssertEqual(state.finishUpload(upload, hub: hub, error: nil, enabled: false), .unregisterAgain)
        XCTAssertNil(state.registeredHub)
        // A stale upload while still enabled (a newer one started) is just ignored.
        var other = PushRegistrationState()
        let first = other.beginUpload(hub: hub).id
        _ = other.beginUpload(hub: hub).id
        XCTAssertEqual(other.finishUpload(first, hub: hub, error: nil, enabled: true), .ignore)
    }
}

final class PresenceTrackerTests: XCTestCase {
    func testReportsChangesAndRestoresAfterBackground() {
        var presence = PresenceTracker()
        XCTAssertEqual(presence.request("t1"), .report("t1"))
        XCTAssertEqual(presence.visibleTodoId, "t1")
        XCTAssertEqual(presence.request("t1"), .none, "unchanged")
        XCTAssertEqual(presence.enterBackground(), .report(nil))
        XCTAssertNil(presence.visibleTodoId, "nothing is on screen in the background")
        XCTAssertEqual(presence.enterBackground(), .none)
        XCTAssertEqual(presence.becomeActive(), .report("t1"), "still on screen after returning")
        XCTAssertEqual(presence.visibleTodoId, "t1")
        XCTAssertEqual(presence.request(nil), .report(nil))
        XCTAssertEqual(presence.becomeActive(), .none)
    }

    func testRequestWhileInBackgroundWaitsForActive() {
        var presence = PresenceTracker()
        _ = presence.enterBackground()
        XCTAssertEqual(presence.request("t2"), .none)
        XCTAssertNil(presence.visibleTodoId)
        XCTAssertEqual(presence.becomeActive(), .report("t2"))
    }
}
