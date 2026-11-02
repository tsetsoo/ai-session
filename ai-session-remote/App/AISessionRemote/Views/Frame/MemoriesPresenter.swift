import AISessionCore
import SwiftUI

/// ⋯ ▸ Memories: the memories panel next to the conversation, an inspector on the Mac and a
/// sheet on iOS. It needs a linked conversation. The Mac's conversation column presents one for
/// whichever conversation is in front, so switching swaps the panel's contents instead of
/// closing and reopening the inspector (which also resized the terminal).
struct MemoriesPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let todoID: String
    let conversation: Conversation?
    let store: TodoHubStore

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .inspector(isPresented: $isPresented) {
                // AppKit keeps a collapsed inspector's content built and laid out. Unopened, the
                // panel fetched and laid out every memory of the project in each kept-alive
                // frame, which stalled every conversation switch.
                Group {
                    if isPresented { panel } else { Color.clear }
                }
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
                .id(todoID)
        } else {
            ContentUnavailableView("No conversation yet", systemImage: "lightbulb")
        }
    }
}
