import AISessionCore
import SwiftUI

/// ⋯ ▸ Memories: the memories panel next to the conversation on the Mac and a sheet on iOS. It needs a linked conversation. The Mac's conversation column presents one for
/// whichever conversation is in front, so switching swaps the panel's contents instead of
/// closing and reopening the inspector (which also resized the terminal).
/// What the conversation's side column shows. One inspector swaps between panels.
enum ConversationSidePanel: Equatable {
    case memories
    /// The Mac's delegated-work panel (the phone has the cards in its chat).
    case workers
    case browser

    static func toggle(_ panel: Self, in current: Binding<Self?>, reduceMotion: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
            current.wrappedValue = current.wrappedValue == panel ? nil : panel
        }
    }
}

struct MemoriesPresenter: ViewModifier {
    @Binding var isPresented: Bool
    var kind: ConversationSidePanel = .memories
    let todoID: String
    let conversation: Conversation?
    let store: TodoHubStore
    var browserDestination: TerminalBrowserDestination? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(macOS)
        NativeCollapsibleSplit(isVisible: isPresented, onVisibilityChange: { isPresented = $0 },
                               isVertical: true, collapsedSize: 0, minimumExpandedSize: 180,
                               initialExpandedSize: 340, minimumLeadingSize: 200,
                               top: content, bottom: Group {
            if isPresented { panel } else { Color.clear }
        })
        #else
        content
            .sheet(isPresented: Binding(get: { isPresented && kind == .memories }, set: { isPresented = $0 })) {
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
        #if os(macOS)
        if kind == .browser {
            if let browserDestination {
                TerminalBrowserPane(
                    destination: browserDestination,
                    isOnScreen: isPresented,
                    onClose: {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { isPresented = false }
                    }
                )
                .id(browserDestination.id)
            } else {
                ContentUnavailableView("Terminal Browser", systemImage: "globe",
                                       description: Text("Open a conversation to preview a page."))
            }
        } else if kind == .workers, let conversation {
            WorkersPanel(conversation: conversation, store: store)
                .id("workers|\(conversation.id)|\(conversation.sessionId)")
        } else if let conversation {
            // A fresh panel per conversation on screen, including between two conversations
            // of one todo: its rows start from that conversation's cache.
            MemoriesPanel(todoId: todoID, store: store, conversation: conversation)
                .id("\(todoID)|\(conversation.id)|\(conversation.sessionId)")
        } else {
            ContentUnavailableView("No conversation yet", systemImage: kind == .workers ? "person.2" : "lightbulb")
        }
        #else
        if let conversation {
            MemoriesPanel(todoId: todoID, store: store, conversation: conversation)
                .id("\(todoID)|\(conversation.id)|\(conversation.sessionId)")
        } else {
            ContentUnavailableView("No conversation yet", systemImage: "lightbulb")
        }
        #endif
    }
}
