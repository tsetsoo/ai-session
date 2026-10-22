import AISessionCore
import Foundation
import os

/// Where the todo server lives and how to authenticate. The URL is not secret and lives in
/// `UserDefaults`; the API token is kept in the Keychain.
enum TodoHubSettings {
    private static let urlKey = "todoHub.baseURL"
    private static let tokenAccount = "api-token"
    private static let keychain = KeychainStringStore(service: "com.aisessionremote.todohub")

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: urlKey)
            NotificationCenter.default.post(name: .todoHubSettingsChanged, object: nil)
        }
    }

    /// Every hub request reads the token, and a Keychain read is a round trip to `securityd`
    /// on the caller's thread (often the main one), so it is read once. A failed or empty read
    /// is not kept: a Keychain still locked after a reboot is asked again next time.
    private static let cachedToken = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var token: String {
        if let token = cachedToken.withLock({ $0 }) { return token }
        guard let token = try? keychain.load(account: tokenAccount), !token.isEmpty else { return "" }
        cachedToken.withLock { $0 = token }
        return token
    }

    /// Stores the token (or removes it when empty). Throws if the Keychain refuses, so the
    /// settings screen can say so instead of every later request failing with "unauthorized".
    static func setToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account: tokenAccount)
        } else {
            try keychain.save(account: tokenAccount, value: trimmed)
        }
        cachedToken.withLock { $0 = trimmed.isEmpty ? nil : trimmed }
        NotificationCenter.default.post(name: .todoHubSettingsChanged, object: nil)
    }

    static var isConfigured: Bool {
        TodoHubClient.baseURL(from: baseURLString) != nil
    }

    /// `nil` until a valid URL is saved, and always in a `-uiDemo` launch: every hub call
    /// (store, live updates, presence, push registration) gets its client here, so a demo
    /// never reaches the real hub with the real token.
    static func makeClient() -> TodoHubClient? {
        #if DEBUG
        if DemoFixtures.isEnabled { return nil }
        #endif
        guard let url = TodoHubClient.baseURL(from: baseURLString) else { return nil }
        return TodoHubClient(baseURL: url, token: token)
    }
}
