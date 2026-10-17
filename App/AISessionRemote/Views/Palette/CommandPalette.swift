import AISessionCore
import SwiftUI

/// ⌘K: a floating panel centred over the shell that jumps to a conversation, todo or project,
/// or runs an action (`PaletteModel` lists and ranks them).
///
/// The search field keeps keyboard focus: ↑/↓ move, ⏎ opens, ⌘⏎ opens in a new window (Mac)
/// and esc closes, all through `.onKeyPress` on the field. Clicking outside the panel closes it.
struct CommandPalette: View {
    @Binding var isPresented: Bool
    /// The shell's selected todo, for "Link a conversation to …".
    let selectedTodoID: String?
    /// A row was chosen; `newWindow` is ⌘⏎. The palette has already closed.
    let onActivate: (_ item: PaletteItem, _ newWindow: Bool) -> Void

    @Environment(AppModel.self) private var model
    @State private var query: String
    /// The highlighted row's id; `nil` is the first row.
    @State private var highlighted: String?
    @FocusState private var fieldFocused: Bool
    /// The results' natural height; the list scrolls past `maxResultsHeight`.
    @State private var resultsHeight: CGFloat = 300

    private static let width: CGFloat = 600
    private static let maxResultsHeight: CGFloat = 460
    private static let searchPrompt = "Search conversations, todos and actions"

    init(isPresented: Binding<Bool>, selectedTodoID: String? = nil, initialQuery: String = "",
         onActivate: @escaping (_ item: PaletteItem, _ newWindow: Bool) -> Void) {
        _isPresented = isPresented
        self.selectedTodoID = selectedTodoID
        self.onActivate = onActivate
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        let store = model.store
        let groups = PaletteModel.groups(
            query: query, board: model.board, todos: store.todos, projects: store.projects,
            selectedTodoID: selectedTodoID, canEdit: model.isConfigured && !store.isOffline
        )
        let items = groups.flatMap(\.items)
        let current = items.first { $0.id == highlighted }?.id ?? items.first?.id
        ZStack(alignment: .top) {
            Color(white: 0.08).opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityHidden(true)
            panel(groups: groups, items: items, current: current)
                .frame(maxWidth: Self.width)
                .padding(.top, 96)
                .padding(.horizontal, DS.spacing.l)
        }
    }

    private func panel(groups: [PaletteGroup], items: [PaletteItem], current: String?) -> some View {
        VStack(spacing: 0) {
            searchField(items: items, current: current)
            Divider()
            results(groups: groups, current: current)
            Divider()
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Search field

    private func searchField(items: [PaletteItem], current: String?) -> some View {
        HStack(spacing: DS.spacing.s + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(Self.searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($fieldFocused)
                .accessibilityLabel(Self.searchPrompt)
                .onChange(of: query) { _, _ in highlighted = nil }
                // The field keeps focus while the palette is open: a terminal that connects
                // (or the window settling) would otherwise take the keys. Clicking outside closes
                // the palette instead.
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { DispatchQueue.main.async { fieldFocused = true } }
                }
                .onKeyPress(.downArrow) {
                    move(by: 1, items: items, current: current)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, items: items, current: current)
                    return .handled
                }
                .onKeyPress(.escape) {
                    isPresented = false
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    guard let item = items.first(where: { $0.id == current }) else { return .handled }
                    activate(item, newWindow: press.modifiers.contains(.command))
                    return .handled
                }
            Text("esc")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15))
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.spacing.l)
        .frame(height: 52)
        .onAppear { fieldFocused = true }
    }

    private func move(by step: Int, items: [PaletteItem], current: String?) {
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == current } ?? 0
        highlighted = items[min(max(index + step, 0), items.count - 1)].id
    }

    private func activate(_ item: PaletteItem, newWindow: Bool) {
        isPresented = false
        onActivate(item, newWindow)
    }

    // MARK: Results

    @ViewBuilder
    private func results(groups: [PaletteGroup], current: String?) -> some View {
        if groups.isEmpty {
            Text("No results for “\(query)”")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, group.kind == groups.first?.kind ? 6 : 10)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in
                                row(item, isHighlighted: item.id == current)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, DS.spacing.s)
                    .padding(.top, DS.spacing.s)
                    .padding(.bottom, 10)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ResultsHeightKey.self, value: geometry.size.height)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(resultsHeight, Self.maxResultsHeight))
                .onPreferenceChange(ResultsHeightKey.self) { resultsHeight = $0 }
                .onChange(of: current) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        Button {
            activate(item, newWindow: false)
        } label: {
            PaletteRow(item: item, query: query)
                .padding(.horizontal, 10)
                .frame(height: item.isAction ? 36 : 40)
                .background(isHighlighted ? DS.accentTint : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.spacing.l) {
            Text("↑↓ move")
            Text("⏎ open")
            #if os(macOS)
            Text("⌘⏎ open in new window")
            #endif
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.spacing.l)
        .padding(.vertical, 9)
        .accessibilityHidden(true)
    }
}

private struct ResultsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Rows

/// One palette row, after the MacPalette board: a status dot or icon, the title with the
/// query's match in bold, "Sp · mac-studio", then the status and ⌘n hint (conversations) or the
/// shortcut (actions).
private struct PaletteRow: View {
    let item: PaletteItem
    let query: String

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 16)
            Text(highlighted(title))
                .fontWeight(isNeedsYou ? .semibold : .regular)
                .lineLimit(1)
                .layoutPriority(1)
            if let meta {
                Text(meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.spacing.s)
            trailing
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var isNeedsYou: Bool {
        if case .conversation(_, _, .needsYou, _) = item { return true }
        return false
    }

    @ViewBuilder private var leading: some View {
        switch item {
        case let .conversation(_, _, status, _):
            StatusBadge(status, style: .dot)
        case .todo:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .project:
            Image(systemName: "folder").foregroundStyle(.secondary)
        case let .action(action):
            Image(systemName: action.systemImage)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item {
        case let .conversation(_, _, status, shortcut):
            if status == .needsYou {
                StatusBadge(status)
            } else {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(shortcut.map { "⌘\($0)" } ?? "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        case let .todo(_, _, status):
            if let status {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .project:
            EmptyView()
        case let .action(action):
            if let shortcut = action.shortcutHint {
                Text(shortcut)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch item {
        case let .conversation(todo, _, _, _), let .todo(todo, _, _): return todo.title
        case let .project(project): return project.name
        case let .action(action): return action.title
        }
    }

    /// "Sp · mac-studio", "P · no conversation yet", or a project's "mac-studio · ~/code/x".
    private var meta: String? {
        switch item {
        case let .conversation(todo, conversation, _, _):
            return "\(todo.section.rawValue) · \(conversation.computer.name)"
        case let .todo(todo, conversation, _):
            return "\(todo.section.rawValue) · \(conversation?.computer.name ?? "no conversation yet")"
        case let .project(project):
            return "\(project.computer.name) · \(project.folder)"
        case .action:
            return nil
        }
    }

    /// The query's first contiguous match in bold (case- and accent-insensitive); a scattered
    /// fuzzy match isn't marked.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isAction, !query.isEmpty,
              let range = attributed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return attributed }
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        if isNeedsYou { attributed[range].foregroundColor = DS.accent }
        return attributed
    }

    private var accessibilityText: String {
        var parts = [title]
        if let meta { parts.append(meta) }
        switch item {
        case let .conversation(_, _, status, shortcut):
            parts.append(status.label)
            if let shortcut { parts.append("Command \(shortcut)") }
        case let .todo(_, _, status):
            if let status { parts.append(status.label) }
        case .project:
            parts.append("Project")
        case let .action(action):
            if action == .newTodo { parts.append("Command N") }
        }
        return parts.joined(separator: ", ")
    }
}

private extension PaletteItem {
    var isAction: Bool {
        if case .action = self { return true }
        return false
    }
}

private extension PaletteAction {
    var systemImage: String {
        switch self {
        case .newTodo: return "plus"
        case .linkConversation: return "link"
        case .newTodoFromConversation: return "text.bubble"
        case .openSettings: return "gearshape"
        }
    }

    /// The menu shortcut that does the same.
    var shortcutHint: String? {
        switch self {
        case .newTodo: return "⌘N"
        #if os(macOS)
        case .openSettings: return "⌘,"
        #endif
        default: return nil
        }
    }
}
