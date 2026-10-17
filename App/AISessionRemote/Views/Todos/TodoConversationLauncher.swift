import AISessionCore
import SwiftUI

/// Opening a todo's conversation, shared by the Todos list and project pages: get-or-create
/// it on the hub, then find the SSH host and key for its computer.
@MainActor
enum TodoConversationLauncher {
    enum Outcome {
        case opened(OpenTodoConversation)
        /// No saved host matches the computer; offer to add one.
        case missingHost(Computer)
        case failed(String)
    }

    static func open(_ todo: Todo, store: TodoHubStore, hosts: [HostEntity]) async -> Outcome {
        let conversation: Conversation
        if store.isOffline, let cached = store.conversations[todo.id], cached.status != .closed {
            // The hub is down but the computer may not be: attach with what we know.
            conversation = cached
        } else {
            do {
                conversation = try await store.openConversation(for: todo)
            } catch let TodoHubError.conflict(message) {
                return .failed(conflictMessage(message))
            } catch {
                return .failed(TodoHubStore.message(for: error))
            }
        }
        guard let host = HostLookup.host(for: conversation.computer, in: hosts) else {
            return .missingHost(conversation.computer)
        }
        do {
            let connection = try SessionServiceFactory().make(for: host)
            return .opened(OpenTodoConversation(
                conversation: conversation,
                hostID: host.id,
                config: connection.config,
                title: todo.title
            ))
        } catch {
            return .failed("The private key for \(host.displayName) is unavailable. Edit the host under Hosts and save its key again.")
        }
    }

    /// The server's 409 text, plus where to fix the common "no computer" case.
    static func conflictMessage(_ serverMessage: String) -> String {
        guard serverMessage.localizedCaseInsensitiveContains("no computer") else { return serverMessage }
        return serverMessage + ". Assign one under Settings → Computers."
    }

    static func newHostPrefill(for computer: Computer) -> HostEditorPrefill {
        HostEditorPrefill(
            displayName: computer.name,
            hostname: computer.hostname,
            port: computer.port,
            username: computer.username
        )
    }
}

/// The terminal for a todo's conversation, with a toolbar button for the memories panel (an
/// inspector on the Mac, a sheet on iOS). `TerminalScreen` itself is unchanged; this only
/// wraps it.
struct TodoConversationScreen: View {
    let open: OpenTodoConversation
    let store: TodoHubStore
    @State private var showingMemories = false

    var body: some View {
        terminal
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingMemories.toggle()
                    } label: {
                        Image(systemName: "lightbulb")
                    }
                    .accessibilityLabel("Memories")
                    .help("Memories")
                }
            }
            #if os(macOS)
            .inspector(isPresented: $showingMemories) {
                memoriesPanel
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 520)
            }
            #else
            .sheet(isPresented: $showingMemories) {
                NavigationStack {
                    memoriesPanel
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingMemories = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            #endif
    }

    private var memoriesPanel: some View {
        MemoriesPanel(todoId: open.conversation.todoId, store: store, initialConversation: open.conversation)
    }

    private var terminal: some View {
        let conversation = open.conversation
        return TerminalScreen(
            hostConfig: open.config,
            mode: .attach(TmuxCommandBuilder.openTodoConversation(
                tmuxName: conversation.tmuxName,
                cwd: conversation.cwd,
                sessionId: conversation.sessionId,
                tool: conversation.tool
            )),
            title: open.title,
            // "Kill Session" in the terminal menu = Close conversation: ends tmux, keeps
            // the Claude conversation resumable.
            onKill: {
                try await store.closeConversation(conversation, config: open.config)
            }
        )
    }
}
