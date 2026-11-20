import AISessionCore
import SwiftUI

#if os(macOS)
import UniformTypeIdentifiers
import OSLog

/// Use an app-specific payload so dropping text or files cannot change a todo.
struct TodoDragItem: Codable {
    let todoID: String

    static let contentType = UTType(exportedAs: "com.aisessionremote.todo", conformingTo: .data)

    func itemProvider() -> NSItemProvider {
        Logger(subsystem: "com.aisessionremote.mac.drag", category: "Todos").debug("Todo drag began")
        let provider = NSItemProvider(object: todoID as NSString)
        let data = try! JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor
enum TodoHoldDrop {
    /// Any unfinished todo can switch sections while the hub is reachable.
    static func canDrag(_ todo: Todo?, isOffline: Bool) -> Bool {
        guard let todo else { return false }
        return !todo.completed && !isOffline
    }

    static func accept(_ providers: [NSItemProvider], store: TodoHubStore, status: TodoWorkStatus) -> Bool {
        Logger(subsystem: "com.aisessionremote.mac.drag", category: "Todos").debug("Todo drop received")
        guard !store.isOffline else { return false }
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(TodoDragItem.contentType.identifier) }
        guard !providers.isEmpty else { return false }
        Task {
            var items: [TodoDragItem] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: TodoDragItem.contentType.identifier) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                if let data, let item = try? JSONDecoder().decode(TodoDragItem.self, from: data) {
                    items.append(item)
                }
            }
            _ = accept(items, store: store, status: status)
        }
        return true
    }

    static func accept(_ items: [TodoDragItem], store: TodoHubStore, status: TodoWorkStatus) -> Bool {
        guard !store.isOffline else { return false }
        let ids = Set(items.map(\.todoID))
        // Resolve against current data: the todo might have changed during the drag.
        let todos = store.todos.filter { ids.contains($0.id) && !$0.completed && $0.workStatus != status }
        guard !todos.isEmpty else { return false }
        Task {
            for todo in todos { await store.setWorkStatus(status, for: todo) }
        }
        return true
    }
}

/// An empty status section still needs a full-width drop target.
struct TodoHoldDropArea: View {
    let store: TodoHubStore
    let status: TodoWorkStatus
    @State private var isTargeted = false

    var body: some View {
        Label(isTargeted ? "Release to move to \(status.label)" : "Drop to move to \(status.label)",
              systemImage: status.systemImage)
            .font(.callout)
            .foregroundStyle(isTargeted ? DS.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, DS.spacing.m)
            .background(DS.accent.opacity(isTargeted ? 0.12 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? DS.accent : Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(Rectangle())
            .onDrop(of: [TodoDragItem.contentType], isTargeted: $isTargeted) { providers in
                TodoHoldDrop.accept(providers, store: store, status: status)
            }
            .opacity(store.isOffline ? 0.5 : 1)
            .accessibilityLabel("\(status.label) drop area")
            .help(store.isOffline ? "Reconnect to move todos" : "Drop a todo or conversation to move its todo to \(status.label)")
    }
}

/// `.itemProvider` rather than `.onDrag`: in a selectable `List` the table starts the drag itself,
/// so a click still selects the row. `.onDrag` adds its own mouse-down handling that swallowed
/// clicks with any small mouse movement. The modifier chain is the same in every state, so a todo
/// or offline change never rebuilds the row in the middle of a click.
private struct TodoDragSource: ViewModifier {
    let todo: Todo?
    let store: TodoHubStore

    func body(content: Content) -> some View {
        content.itemProvider(provider)
    }

    private var provider: (() -> NSItemProvider?)? {
        guard let todo, TodoHoldDrop.canDrag(todo, isOffline: store.isOffline) else { return nil }
        let id = todo.id
        return { TodoDragItem(todoID: id).itemProvider() }
    }
}

private struct TodoHoldDropTarget: ViewModifier {
    let store: TodoHubStore
    let status: TodoWorkStatus?
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let status {
            content
                .contentShape(Rectangle())
                .background(isTargeted ? DS.accent.opacity(0.12) : Color.clear)
                .onDrop(of: [TodoDragItem.contentType], isTargeted: $isTargeted) { providers in
                    TodoHoldDrop.accept(providers, store: store, status: status)
                }
        } else {
            content
        }
    }
}
#endif

extension View {
    func todoDragSource(_ todo: Todo?, store: TodoHubStore) -> some View {
        #if os(macOS)
        modifier(TodoDragSource(todo: todo, store: store))
        #else
        self
        #endif
    }

    func todoStatusDropTarget(store: TodoHubStore, status: TodoWorkStatus?) -> some View {
        #if os(macOS)
        modifier(TodoHoldDropTarget(store: store, status: status))
        #else
        self
        #endif
    }
}

func showsWorkStatusSection(hasItems: Bool) -> Bool {
    #if os(macOS)
    true
    #else
    hasItems
    #endif
}
