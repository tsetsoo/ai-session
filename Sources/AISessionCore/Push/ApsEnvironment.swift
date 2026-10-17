import Foundation

/// Which APNs environment this build's device token belongs to. Decided by the provisioning
/// profile, not by Debug/Release: a Release build signed with a development profile (how the
/// app is installed on the phone today) gets sandbox tokens.
public enum ApsEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    /// Reads `aps-environment` from an `embedded.mobileprovision`. The profile is a CMS blob
    /// with the plist inside as plain text. No profile (App Store / TestFlight) is production.
    public static func fromProvisioningProfile(_ data: Data?) -> ApsEnvironment {
        guard let data, let text = String(data: data, encoding: .isoLatin1) else { return .production }
        guard let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else { return .production }
        return text[open.upperBound..<close.lowerBound] == "development" ? .sandbox : .production
    }

    /// The running app's environment (its bundled profile).
    public static var current: ApsEnvironment {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return fromProvisioningProfile(url.flatMap { try? Data(contentsOf: $0) })
    }
}
