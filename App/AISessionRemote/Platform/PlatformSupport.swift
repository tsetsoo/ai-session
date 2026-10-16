import Foundation

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
