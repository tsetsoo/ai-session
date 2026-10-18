import SwiftUI

/// A `List` that highlights the selected todo when given a selection (the Mac list column),
/// and a plain tap-driven one otherwise (iPhone). Rows tag themselves with their todo id.
struct SelectableList<Content: View>: View {
    let selection: Binding<String?>?
    @ViewBuilder let content: Content

    @Environment(\.listPrimaryAction) private var primaryAction

    var body: some View {
        if let selection {
            #if os(macOS)
            List(selection: selection) { content }
                // ⏎ or a double-click on a row; rows keep their own context menus.
                .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                    if let id = ids.first, ids.count == 1 { primaryAction?(id) }
                })
            #else
            List(selection: selection) { content }
            #endif
        } else {
            List { content }
        }
    }
}

extension EnvironmentValues {
    /// ⏎ or a double-click on a selectable row in the Mac list column, with the row's tag.
    /// Selection alone never starts anything; this does.
    @Entry var listPrimaryAction: ((String) -> Void)?
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
