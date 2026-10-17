import XCTest
@testable import AISessionCore

final class PushTests: XCTestCase {
    /// The plist inside an `embedded.mobileprovision` sits as plain text between binary CMS bytes.
    private func profile(apsEnvironment: String?) -> Data {
        var data = Data([0x30, 0x82, 0x2c, 0x01, 0x06, 0x09])
        let entitlements = apsEnvironment.map { "<key>aps-environment</key>\n\t\t<string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>Entitlements</key><dict>
        \t\t\(entitlements)
        <key>application-identifier</key><string>233QTK6KCL.com.aisessionremote.app</string>
        </dict></dict></plist>
        """
        data.append(Data(plist.utf8))
        data.append(contentsOf: [0xff, 0x00, 0xa0])
        return data
    }

    func testApsEnvironmentDevelopmentIsSandbox() {
        XCTAssertEqual(ApsEnvironment.fromProvisioningProfile(profile(apsEnvironment: "development")), .sandbox)
    }

    func testApsEnvironmentProductionAndMissingProfile() {
        XCTAssertEqual(ApsEnvironment.fromProvisioningProfile(profile(apsEnvironment: "production")), .production)
        XCTAssertEqual(ApsEnvironment.fromProvisioningProfile(nil), .production, "App Store / TestFlight builds have no profile")
    }

    func testPayloadParsesTodoId() {
        let payload = PushPayload(userInfo: ["aps": ["alert": ["title": "x"]], "todo_id": "t1", "session_id": "s1", "kind": "waiting"])
        XCTAssertEqual(payload, PushPayload(todoId: "t1", sessionId: "s1", kind: "waiting"))
    }

    func testPayloadWithoutTodoIdIsNil() {
        XCTAssertNil(PushPayload(userInfo: ["aps": [:], "kind": "test"]))
        XCTAssertNil(PushPayload(userInfo: ["todo_id": ""]))
    }

    func testStaleAlertsAreOnlyAnsweredWaitingOnes() {
        let delivered = [
            PushPayload(todoId: "answered", kind: "waiting"),
            PushPayload(todoId: "still", kind: "waiting"),
            PushPayload(todoId: "finished", kind: "done"),
        ]
        XCTAssertEqual(
            NotificationPolicy.staleAlertIdentifiers(delivered: delivered, waitingTodoIds: ["still"]),
            ["todo-answered"],
            "done alerts are about idle conversations by definition: keep them"
        )
    }

    func testNotificationIdentifierMatchesServerCollapseId() {
        XCTAssertEqual(NotificationPolicy.notificationIdentifier(todoId: "t1"), "todo-t1")
    }

    private func shouldPost(
        _ state: PushState,
        visible: String? = nil,
        mac: Bool = false,
        iPhoneRegistered: Bool = false,
        macAlertsToo: Bool = false
    ) -> Bool {
        NotificationPolicy.shouldPostLocal(
            pushState: state,
            visibleTodoId: visible,
            todoId: "t1",
            isMac: mac,
            iPhoneRegisteredOnServer: iPhoneRegistered,
            macAlertsToo: macAlertsToo
        )
    }

    func testPolicyNoLocalWhenRegistered() {
        XCTAssertFalse(shouldPost(.registered), "the server push is the alert")
        XCTAssertTrue(shouldPost(.localOnly("Server has no push support")))
    }

    func testPolicyNoLocalWhenVisible() {
        XCTAssertFalse(shouldPost(.localOnly("x"), visible: "t1"))
        XCTAssertTrue(shouldPost(.localOnly("x"), visible: "t2"))
        XCTAssertFalse(shouldPost(.localOnly("x"), visible: "t1", mac: true))
    }

    func testPolicyMacDefersToRegisteredIPhone() {
        XCTAssertTrue(shouldPost(.off, mac: true, iPhoneRegistered: false))
        XCTAssertFalse(shouldPost(.off, mac: true, iPhoneRegistered: true))
    }

    func testPolicyMacAlertsTooOverrides() {
        XCTAssertTrue(shouldPost(.off, mac: true, iPhoneRegistered: true, macAlertsToo: true))
    }
}

final class PushHubClientTests: XCTestCase {
    private func client() -> TodoHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TodoHubClient(baseURL: URL(string: "http://pi.tailnet:8080")!, token: "s3cret", session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    private func lastBody() throws -> [String: Any] {
        let body = try XCTUnwrap(StubURLProtocol.requests.last?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testRegisterDeviceSendsBody() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: #"{"token_prefix":"a1b2c3d4","platform":"ios","environment":"sandbox","bundle_id":"com.aisessionremote.app","app_version":"1.0 (7)","device_name":"iPhone","created_at":"2026-10-17 10:00:00","updated_at":"2026-10-17 10:00:00","last_sent_at":null,"last_error":null}"#)
        }
        let device = try await client().registerPushDevice(PushDeviceRegistration(
            token: "a1b2", platform: .ios, environment: .sandbox,
            bundleId: "com.aisessionremote.app", appVersion: "1.0 (7)", deviceName: "iPhone"
        ))
        XCTAssertEqual(device.tokenPrefix, "a1b2c3d4")
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/push/devices")
        let body = try lastBody()
        XCTAssertEqual(body["token"] as? String, "a1b2")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(body["bundle_id"] as? String, "com.aisessionremote.app")
        XCTAssertEqual(body["app_version"] as? String, "1.0 (7)")
    }

    func testRegisterDevice404MapsToUnsupported() async {
        StubURLProtocol.handler = { _ in .init(status: 404, body: "") }
        do {
            _ = try await client().registerPushDevice(PushDeviceRegistration(
                token: "a1", platform: .ios, environment: .sandbox, bundleId: "b", appVersion: "1"
            ))
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? TodoHubError, .unsupported)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "no retry")
    }

    func testUnregisterSendsTokenInBodyAndIgnoresUnknownDevice() async throws {
        StubURLProtocol.handler = { _ in .init(status: 404, body: #"{"error":"Device not registered"}"#) }
        try await client().unregisterPushDevice(token: "a1b2")
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/push/devices/unregister", "never the token in the path")
        XCTAssertEqual(try lastBody()["token"] as? String, "a1b2")
    }

    func testPresenceSendsNullTodo() async throws {
        StubURLProtocol.handler = { _ in .init(status: 204, body: "") }
        try await client().reportPresence(clientId: "c1", todoId: "t1")
        XCTAssertEqual(try lastBody()["todo_id"] as? String, "t1")
        try await client().reportPresence(clientId: "c1", todoId: nil)
        let body = try lastBody()
        XCTAssertEqual(body["client_id"] as? String, "c1")
        XCTAssertTrue(body["todo_id"] is NSNull, "explicit null clears presence")
    }

    func testSettingsRoundTrip() async throws {
        let json = #"{"notify_waiting":true,"done_after_minutes":5,"grace_seconds":20,"quiet_hours":{"start":"22:30","end":"07:30","tz":"Europe/Sofia"},"muted_sections":["P"],"muted_todo_ids":["t1"]}"#
        StubURLProtocol.handler = { _ in .init(status: 200, body: json) }
        let settings = try await client().pushSettings()
        XCTAssertEqual(settings.quietHours, QuietHours(start: "22:30", end: "07:30", tz: "Europe/Sofia"))
        XCTAssertEqual(settings.mutedSections, [.p])
        XCTAssertEqual(settings.mutedTodoIds, ["t1"])
        let saved = try await client().savePushSettings(settings)
        XCTAssertEqual(saved, settings)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "PUT")
        let body = try lastBody()
        XCTAssertEqual(body["done_after_minutes"] as? Int, 5)
        XCTAssertEqual(body["muted_sections"] as? [String], ["P"])
    }

    func testMuteStatusAndTestPush() async throws {
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/api/push/status": .init(status: 200, body: #"{"configured":true,"last_error":null,"last_sent_at":"2026-10-17 10:00:00","devices":1}"#)
            case "/api/push/test": .init(status: 200, body: #"[{"token_prefix":"a1b2c3d4","ok":false,"reason":"BadDeviceToken"}]"#)
            default: .init(status: 204, body: "")
            }
        }
        try await client().setTodoPushMuted(todoId: "t 1", true)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "PUT")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/api/todos/t 1/push-mute")
        try await client().setTodoPushMuted(todoId: "t1", false)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
        let status = try await client().pushStatus()
        XCTAssertEqual(status, PushServerStatus(configured: true, lastError: nil, lastSentAt: "2026-10-17 10:00:00", devices: 1))
        let results = try await client().sendTestPush()
        XCTAssertEqual(results, [PushTestResult(tokenPrefix: "a1b2c3d4", ok: false, reason: "BadDeviceToken")])
    }
}

final class QuietHoursTimeTests: XCTestCase {
    func testHHMMRoundTripsThroughDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Sofia"))
        let date = try XCTUnwrap(QuietHours.date(fromHHMM: "07:05", calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: date), 7)
        XCTAssertEqual(calendar.component(.minute, from: date), 5)
        XCTAssertEqual(QuietHours.hhmm(from: date, calendar: calendar), "07:05")
        XCTAssertNil(QuietHours.date(fromHHMM: "7:5x", calendar: calendar))
        XCTAssertNil(QuietHours.date(fromHHMM: "24:00", calendar: calendar))
    }
}
