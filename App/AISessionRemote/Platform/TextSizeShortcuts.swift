import Foundation
#if os(macOS)
import AppKit
#endif

/// Terminal text-size stepping shared by the Conversation menu and the ⌘= key alias.
enum TextSizeShortcuts {
    static let fontSizeKey = "terminal.fontSize"

    /// Steps the stored terminal font size. Goes through `UserDefaults`, so `@AppStorage`
    /// observers (the terminal, the menu) update.
    static func step(by delta: Int, defaults: UserDefaults = .standard) {
        let current = defaults.object(forKey: fontSizeKey) as? Double ?? TerminalAppearance.defaultFontSize
        defaults.set(TerminalAppearance.stepped(current, by: delta), forKey: fontSizeKey)
    }

    /// Plain ⌘= (what people press for "bigger" on a US layout, where ⌘+ needs Shift).
    static func isBiggerTextAlias(characters: String?, command: Bool, otherModifiers: Bool) -> Bool {
        characters == "=" && command && !otherModifiers
    }

    #if os(macOS)
    private static var monitor: Any?

    /// Installs (once) a local key monitor that turns ⌘= into "Bigger Text". A hidden menu
    /// item can't do this: AppKit skips hidden items when matching key equivalents.
    static func installBiggerTextAliasMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard isBiggerTextAlias(
                characters: event.charactersIgnoringModifiers,
                command: flags.contains(.command),
                otherModifiers: !flags.subtracting(.command).isEmpty
            ) else { return event }
            step(by: 1)
            return nil
        }
    }
    #endif
}
