#if os(macOS)
import SwiftUI

// The shared views use a few iOS-only SwiftUI modifiers. On macOS they have no
// equivalent (there is no navigation bar, soft keyboard or autocapitalization),
// so these no-op stand-ins let the shared view files compile unchanged instead of
// wrapping every call site in `#if os(iOS)`.

enum NavigationBarItem {
    enum TitleDisplayMode {
        case automatic
        case inline
        case large
    }
}

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

enum KeyboardTypeShim {
    case `default`
    case numberPad
    case decimalPad
    case URL
    case asciiCapable
}

extension View {
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }

    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        self
    }

    func keyboardType(_ type: KeyboardTypeShim) -> some View {
        self
    }
}

extension ToolbarPlacement {
    /// The closest macOS equivalent of the iOS navigation bar.
    static var navigationBar: ToolbarPlacement { .windowToolbar }
}
#endif
