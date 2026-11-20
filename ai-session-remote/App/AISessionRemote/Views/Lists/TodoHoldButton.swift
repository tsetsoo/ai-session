import AISessionCore
import SwiftUI

/// A todo's hold state applies to all of its conversations.
struct TodoHoldButton: View {
    let todo: Todo
    let store: TodoHubStore

    var body: some View {
        if !todo.completed {
            ForEach(TodoWorkStatus.allCases.filter { $0 != todo.workStatus }, id: \.self) { status in
                Button {
                    Task { await store.setWorkStatus(status, for: todo) }
                } label: {
                    Label("Move Todo to \(status.label)", systemImage: status.systemImage)
                }
                .disabled(store.isOffline)
            }
        }
    }
}
