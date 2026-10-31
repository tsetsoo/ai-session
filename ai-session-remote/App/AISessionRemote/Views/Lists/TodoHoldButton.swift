import AISessionCore
import SwiftUI

/// A todo's hold state applies to all of its conversations.
struct TodoHoldButton: View {
    let todo: Todo
    let store: TodoHubStore

    var body: some View {
        #if os(macOS)
        if !todo.completed {
            Button {
                Task { await store.setOnHold(!todo.onHold, for: todo) }
            } label: {
                Label(todo.onHold ? "Resume Todo" : "Put Todo on Hold",
                      systemImage: todo.onHold ? "play.circle" : "pause.circle")
            }
            .disabled(store.isOffline)
        }
        #endif
    }
}
