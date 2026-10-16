import AISessionCore
import Foundation

/// Where the todo server lives and how to authenticate. The URL is not secret and lives in
/// `UserDefaults`; the API token is kept in the Keychain.
enum TodoHubSettings {
    private static let urlKey = "todoHub.baseURL"
    private static let tokenAccount = "api-token"
    private static let keychain = KeychainStringStore(service: "com.aisessionremote.todohub")

    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    static var token: String {
        get { (try? keychain.load(account: tokenAccount)) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try? keychain.delete(account: tokenAccount)
            } else {
                try? keychain.save(account: tokenAccount, value: trimmed)
            }
        }
    }

    static var isConfigured: Bool {
        TodoHubClient.baseURL(from: baseURLString) != nil
    }

    /// `nil` until a valid URL is saved.
    static func makeClient() -> TodoHubClient? {
        guard let url = TodoHubClient.baseURL(from: baseURLString) else { return nil }
        return TodoHubClient(baseURL: url, token: token)
    }
}
