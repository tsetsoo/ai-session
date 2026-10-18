import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Clipboard, URL opening and haptics behind one API for iOS and macOS.
enum PlatformSupport {
    /// Posted when the app moves to the background. iOS suspends sockets there, so the app
    /// closes pooled SSH connections; macOS keeps them alive, so on the Mac this never fires.
    static var didEnterBackgroundNotification: Notification.Name {
        #if os(iOS)
        UIApplication.didEnterBackgroundNotification
        #else
        Notification.Name("AISessionRemote.neverPostedOnMac")
        #endif
    }

    static var pasteboardString: String? {
        get {
            #if os(iOS)
            UIPasteboard.general.string
            #else
            NSPasteboard.general.string(forType: .string)
            #endif
        }
        set {
            #if os(iOS)
            UIPasteboard.general.string = newValue
            #else
            NSPasteboard.general.clearContents()
            if let newValue {
                NSPasteboard.general.setString(newValue, forType: .string)
            }
            #endif
        }
    }

    static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Light tap on connect. No-op on macOS.
    static func connectedFeedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Warning buzz on disconnect. No-op on macOS.
    static func disconnectedFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// Light tick on a key bar key. No-op on macOS.
    static func keyTapFeedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Rigid tap on Approve. No-op on macOS.
    static func approveFeedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }

    /// Warning buzz when a conversation starts needing you while the app is open. No-op on macOS.
    static func needsYouFeedback() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// Private keys in `~/.ssh` that look importable (`id_*` without `.pub`), sorted by name.
    /// Only meaningful on macOS, where the app is not sandboxed and can read the user's home.
    static func sshKeyCandidates() -> [URL] {
        #if os(macOS)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("id_") && $0.pathExtension != "pub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #else
        return []
        #endif
    }
}

#if os(iOS)
typealias PlatformNativeColor = UIColor
#else
typealias PlatformNativeColor = NSColor
#endif

enum PlatformColor {
    /// A SwiftUI color that resolves to `light` or `dark` with the current appearance.
    static func dynamic(light: PlatformNativeColor, dark: PlatformNativeColor) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #endif
    }
}

extension PlatformNativeColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
