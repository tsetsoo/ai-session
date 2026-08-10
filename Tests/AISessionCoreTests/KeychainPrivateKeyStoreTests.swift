import XCTest
@testable import AISessionCore

final class KeychainPrivateKeyStoreTests: XCTestCase {
    func testSaveLoadDelete() throws {
        #if !canImport(Security)
        throw XCTSkip("Keychain unavailable on this platform")
        #else
        let store = KeychainPrivateKeyStore()
        let account = UUID().uuidString
        let pem = Data(
            "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----\n".utf8
        )
        defer { try? store.delete(account: account) }

        try store.save(account: account, pem: pem)
        XCTAssertEqual(try store.load(account: account), pem)
        try store.delete(account: account)
        XCTAssertThrowsError(try store.load(account: account)) { error in
            XCTAssertEqual(error as? KeychainPrivateKeyStoreError, .itemNotFound)
        }
        #endif
    }

    func testSaveOverwritesExisting() throws {
        #if !canImport(Security)
        throw XCTSkip("Keychain unavailable on this platform")
        #else
        let store = KeychainPrivateKeyStore()
        let account = UUID().uuidString
        defer { try? store.delete(account: account) }

        try store.save(account: account, pem: Data("first".utf8))
        try store.save(account: account, pem: Data("second".utf8))
        XCTAssertEqual(try store.load(account: account), Data("second".utf8))
        #endif
    }

    func testServiceConstant() {
        XCTAssertEqual(KeychainPrivateKeyStore.service, "com.aisessionremote.keys")
    }
}
