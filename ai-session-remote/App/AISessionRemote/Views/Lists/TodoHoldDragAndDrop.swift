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
    /// A row can be dragged to On hold when its todo is active and the hub is reachable.
    static func canDrag(_ todo: Todo?, isOffline: Bool) -> Bool {
        guard let todo else { return false }
        return !todo.completed && !todo.onHold && !isOffline
    }

    static func accept(_ providers: [NSItemProvider], store: TodoHubStore) -> Bool {
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
            _ = accept(items, store: store)
        }
        return true
    }

    static func accept(_ items: [TodoDragItem], store: TodoHubStore) -> Bool {
        guard !store.isOffline else { return false }
        let ids = Set(items.map(\.todoID))
        // Resolve against current data: the todo might have changed during the drag.
        let todos = store.todos.filter { ids.contains($0.id) && !$0.completed && !$0.onHold }
        guard !todos.isEmpty else { return false }
        Task {
            for todo in todos { await store.setOnHold(true, for: todo) }
        }
        return true
    }
}

/// A real list row remains available as a drop target even when no todos are held.
struct TodoHoldDropArea: View {
    let store: TodoHubStore
    @State private var isTargeted = false

    var body: some View {
        Label(isTargeted ? "Release to put on hold" : "Drag todos here to put on hold",
              systemImage: "pause.circle")
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
                TodoHoldDrop.accept(providers, store: store)
            }
            .opacity(store.isOffline ? 0.5 : 1)
            .accessibilityLabel("On hold drop area")
            .help(store.isOffline ? "Reconnect to put todos on hold" : "Drag a todo or conversation here to put its todo on hold")
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

/// Only held rows (which an on-hold change moves to another section anyway) and the header
/// carry a drop target, so the condition can switch the modifier on and off.
private struct TodoHoldDropTarget: ViewModifier {
    let store: TodoHubStore
    let enabled: Bool
    @State private var isTargeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .background(isTargeted ? DS.accent.opacity(0.12) : Color.clear)
                .onDrop(of: [TodoDragItem.contentType], isTargeted: $isTargeted) { providers in
                    TodoHoldDrop.accept(providers, store: store)
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

    /// Existing held rows also accept drops, making the whole section a target.
    func todoHoldDropTarget(store: TodoHubStore, enabled: Bool = true) -> some View {
        #if os(macOS)
        modifier(TodoHoldDropTarget(store: store, enabled: enabled))
        #else
        self
        #endif
    }
}
