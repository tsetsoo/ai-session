import Foundation
#if os(macOS)
import AppKit
#endif

/// The Mac's arrival sounds. Played by the app with `NSSound`, so they follow the Mac's volume
/// and mute (silent in the office, audible at home). No-ops on iOS.
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

    static func key(for kind: AttentionKind) -> String {
        kind == .needsYou ? needsYouKey : reviewKey
    }

    /// The bundled sound for `kind` (`Resources/Sounds`).
    static func bundledName(for kind: AttentionKind) -> String {
        kind == .needsYou ? "attention-needs-you" : "attention-review"
    }

    /// Plays the chosen sound for an arrival, at most once per `minimumGap`.
    static func play(_ kind: AttentionKind) {
        #if os(macOS)
        let now = Date()
        if let lastPlayed, now.timeIntervalSince(lastPlayed) < minimumGap { return }
        let choice = UserDefaults.standard.string(forKey: key(for: kind)) ?? defaultChoice
        guard let sound = sound(choice, kind: kind) else { return }
        lastPlayed = now
        sound.play()
        #endif
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
