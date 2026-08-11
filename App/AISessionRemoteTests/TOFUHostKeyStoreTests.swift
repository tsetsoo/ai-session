import Crypto
import NIOSSH
import XCTest

@testable import AISessionRemote

final class TOFUHostKeyStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TOFUHostKeyStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func randomPublicKey() -> NIOSSHPublicKey {
        NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    }

    func testFirstUseIsTrusted() {
        let store = TOFUHostKeyStore(defaults: defaults)
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: randomPublicKey()))
    }

    func testSameKeyOnRepeatConnectionIsTrusted() {
        let store = TOFUHostKeyStore(defaults: defaults)
        let key = randomPublicKey()
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: key))
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: key))
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: key))
    }

    func testMismatchedKeyIsRejected() {
        let store = TOFUHostKeyStore(defaults: defaults)
        let first = randomPublicKey()
        let second = randomPublicKey()
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: first))
        XCTAssertFalse(store.evaluate(hostID: "host:22", publicKey: second))
        // The stored fingerprint should not have been clobbered by the rejected attempt.
        XCTAssertTrue(store.evaluate(hostID: "host:22", publicKey: first))
    }

    func testDifferentHostIDsAreIndependent() {
        let store = TOFUHostKeyStore(defaults: defaults)
        let a = randomPublicKey()
        let b = randomPublicKey()
        XCTAssertTrue(store.evaluate(hostID: "a.example:22", publicKey: a))
        XCTAssertTrue(store.evaluate(hostID: "b.example:22", publicKey: b))
        XCTAssertFalse(store.evaluate(hostID: "a.example:22", publicKey: b))
    }
}
