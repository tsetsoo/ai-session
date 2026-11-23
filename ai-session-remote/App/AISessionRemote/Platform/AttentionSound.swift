import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The Mac's arrival sounds. Played by the app with `NSSound`, so they follow the Mac's volume
/// and mute (silent in the office, audible at home). Playback no-ops on iOS; the names and
/// notification sounds (which follow the app skin) are used on both.
@MainActor
enum AttentionSound {
    /// UserDefaults keys; values are `defaultChoice`, `noneChoice` or a name in `systemNames`.
    static let needsYouKey = "attention.sound.needsYou"
    static let reviewKey = "attention.sound.review"
    static let defaultChoice = "default"
    static let noneChoice = "none"
    /// macOS alert sounds offered in Settings (`/System/Library/Sounds`).
    static let systemNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                              "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    /// Several refreshes in a burst make one sound.
    private static let minimumGap: TimeInterval = 1.5
    private static var lastPlayed: Date?
    private static var lastKind: AttentionKind?

    static func key(for kind: AttentionKind) -> String {
        kind == .needsYou ? needsYouKey : reviewKey
    }

    /// The bundled sound for `kind` (`Resources/Sounds`), in the current app skin.
    static func bundledName(for kind: AttentionKind) -> String {
        bundledName(for: kind, skin: SkinStore.shared.skin)
    }

    /// Each skin has its own pair: `attention-review-phosphor`. Standard keeps the originals.
    static func bundledName(for kind: AttentionKind, skin: AppSkin) -> String {
        let base = kind == .needsYou ? "attention-needs-you" : "attention-review"
        return skin.soundSuffix.map { "\(base)-\($0)" } ?? base
    }

    /// The file the hub names in `aps.sound` for this device; nil in Standard (system default).
    static func skinSoundFileName(for kind: AttentionKind, skin: AppSkin) -> String? {
        guard skin.soundSuffix != nil else { return nil }
        return bundledName(for: kind, skin: skin) + ".caf"
    }

    /// The skin's sound for a notification; nil in Standard, where callers keep `.default`.
    static func skinSound(for kind: AttentionKind, skin: AppSkin) -> UNNotificationSound? {
        guard skin.soundSuffix != nil else { return nil }
        return UNNotificationSound(named: UNNotificationSoundName(bundledName(for: kind, skin: skin) + ".caf"))
    }

    /// Plays the chosen sound for an arrival, at most once per `minimumGap`.
    static func play(_ kind: AttentionKind) {
        #if os(macOS)
        let now = Date()
        // Needs you is never swallowed by a review sound that just played.
        if let lastPlayed, now.timeIntervalSince(lastPlayed) < minimumGap,
           !(kind == .needsYou && lastKind == .review) { return }
        let choice = UserDefaults.standard.string(forKey: key(for: kind)) ?? defaultChoice
        guard let sound = sound(choice, kind: kind) else { return }
        lastPlayed = now
        lastKind = kind
        sound.play()
        #endif
    }

    /// What a Mac banner should do with the arrival sound.
    enum BannerSound {
        /// The bundled chime, played by the notification (Focus silences it).
        case sound(UNNotificationSound)
        /// The choice is None: nothing to play.
        case silent
        /// A macOS system sound: a banner can't play it, the app does.
        case appPlays
    }

    static func bannerSound(for kind: AttentionKind) -> BannerSound {
        switch UserDefaults.standard.string(forKey: key(for: kind)) ?? defaultChoice {
        case noneChoice: return .silent
        case defaultChoice: return .sound(UNNotificationSound(named: UNNotificationSoundName(bundledName(for: kind) + ".caf")))
        default: return .appPlays
        }
    }

    /// Settings' play button: the choice as it would sound, without the throttle.
    static func preview(_ choice: String, kind: AttentionKind) {
        #if os(macOS)
        sound(choice, kind: kind)?.play()
        #endif
    }

    #if os(macOS)
    private static func sound(_ choice: String, kind: AttentionKind) -> NSSound? {
        switch choice {
        case noneChoice:
            return nil
        case defaultChoice:
            guard let url = Bundle.main.url(forResource: bundledName(for: kind), withExtension: "caf") else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        default:
            // A fresh copy: a named NSSound that is still playing won't start again.
            return (NSSound(named: NSSound.Name(choice))?.copy() as? NSSound)
        }
    }
    #endif
}
