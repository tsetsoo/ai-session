import AISessionCore
import SwiftUI

/// ⋯ ▸ Memories: the memories panel next to the conversation, an inspector on the Mac and a
/// sheet on iOS. It needs a linked conversation.
struct MemoriesPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let todoID: String
    let conversation: Conversation?
    let store: TodoHubStore

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .inspector(isPresented: $isPresented) {
                panel
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 520)
            }
            #else
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    panel
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            #endif
    }

    @ViewBuilder
    private var panel: some View {
        if let conversation {
            MemoriesPanel(todoId: todoID, store: store, initialConversation: conversation)
        } else {
            ContentUnavailableView("No conversation yet", systemImage: "lightbulb")
        }
    }
}
