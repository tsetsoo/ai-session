import SwiftUI

/// A `List` that highlights the selected todo when given a selection (the Mac list column),
/// and a plain tap-driven one otherwise (iPhone). Rows tag themselves with their todo id.
struct SelectableList<Content: View>: View {
    let selection: Binding<String?>?
    @ViewBuilder let content: Content

    var body: some View {
        if let selection {
            List(selection: selection) { content }
        } else {
            List { content }
        }
    }
}

/// `.searchable` filtering for the lists.
enum ListSearch {
    /// True for an empty (or blank) query, else when any field contains it, ignoring case and
    /// diacritics.
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) ?? false }
    }
}
