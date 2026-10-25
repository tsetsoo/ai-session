import SwiftUI

// A grouped Form on macOS lays a text field out as its title on the left and the text
// right-aligned, with no placeholder. These fields keep the iOS look on the Mac: the title is
// the placeholder and the text starts at the leading edge. iOS gets a plain field.

struct FormTextField: View {
    private let title: String
    @Binding private var text: String
    private let axis: Axis

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title
        _text = text
        self.axis = axis
    }

    var body: some View {
        #if os(macOS)
        TextField(title, text: $text, prompt: Text(title), axis: axis)
            .labelsHidden()
            .multilineTextAlignment(.leading)
        #else
        TextField(title, text: $text, axis: axis)
        #endif
    }
}

struct FormSecureField: View {
    private let title: String
    @Binding private var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        #if os(macOS)
        SecureField(title, text: $text, prompt: Text(title))
            .labelsHidden()
            .multilineTextAlignment(.leading)
        #else
        SecureField(title, text: $text)
        #endif
    }
}
