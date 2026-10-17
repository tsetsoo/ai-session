#if DEBUG
import AISessionCore
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// `-uiDemo -uiDemoScreen frame`: the conversation frame for "Fix the rate import" over the
/// canned `DemoTransport`. `-uiDemoPhase idle|preparing` forces that phase, and
/// `-uiDemoProblem <case>` (a `FrameProblem` case name) forces that problem. Debug builds only.
struct DemoFrameScreen: View {
    private static let phase = DemoFixtures.value(after: "-uiDemoPhase")
    private static let problem = DemoFixtures.value(after: "-uiDemoProblem")
    private static let hostID = UUID()

    private let todo: Todo
    @State private var store: TodoHubStore
    @State private var loader: ConversationLoader

    init() {
        var todo = DemoFixtures.todos[0]
        // "No computer" only makes sense for a todo that has never had a conversation.
        let linked = Self.problem != "noComputer"
        if !linked { todo.conversationStatus = nil }
        self.todo = todo
        _store = State(initialValue: Self.makeStore(linked: linked))
        _loader = State(initialValue: ConversationLoader(todo: todo, dependencies: Self.dependencies()))
    }

    var body: some View {
        NavigationStack {
            ConversationFrame(
                todo: todo,
                loader: loader,
                store: store,
                onDeleted: {},
                makeTransport: { _, _ in DemoTransport() }
            )
            .task { await drive() }
        }
        #if os(macOS)
        // Launched from a script, the window would stay inactive and draw its buttons greyed.
        .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        #endif
    }

    private func drive() async {
        guard Self.phase != "idle" else { return }
        await loader.start()
        switch Self.problem {
        case "unreachable": loader.connectionFailed()
        case "helpersMissing": loader.ended(exitStatus: 127)
        case "toolMissing": loader.ended(exitStatus: 90)
        case "folderMissing": loader.ended(exitStatus: 93)
        case "conversationNotFound": loader.ended(exitStatus: 94)
        default: break
        }
    }

    /// A store seeded from a throwaway cache file, so the header shows fixture data offline.
    @MainActor
    private static func makeStore(linked: Bool) -> TodoHubStore {
        let cache = TodoHubCache(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-demo-todo-hub-cache.json"))
        let conversations = DemoFixtures.conversations.filter { linked || $0.todoId != DemoFixtures.todos[0].id }
        try? cache.save(TodoHubSnapshot(todos: DemoFixtures.todos, conversations: conversations))
        return TodoHubStore(cache: cache)
    }

    private static func dependencies() -> ConversationLoader.Dependencies {
        let conversation = DemoFixtures.conversations[0]
        return ConversationLoader.Dependencies(
            openConversation: { _ in
                if phase == "preparing" {
                    try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
                }
                switch problem {
                case "noComputer": throw TodoHubError.conflict("Section Sp has no computer assigned")
                case "hub": throw TodoHubError.unreachable("The request timed out.")
                default: return conversation
                }
            },
            cachedConversation: { _ in nil },
            isOffline: { false },
            resolveConfig: { computer in
                switch problem {
                case "needsAccess": throw HostLookup.Failure.noHost(computer)
                case "keyMissing": throw HostLookup.Failure.keyUnavailable(computer.name)
                default: return (hostID, DemoFixtures.config)
                }
            }
        )
    }
}

extension DemoFixtures {
    /// Opening a todo in a `-uiDemo` launch: its fixture conversation (or a new one on its
    /// section's computer) over the canned transport, never the hub or SSH.
    @MainActor
    static func loaderDependencies() -> ConversationLoader.Dependencies {
        let hostID = UUID()
        return ConversationLoader.Dependencies(
            openConversation: { todo in
                if let existing = conversations.first(where: { $0.todoId == todo.id }) { return existing }
                guard let mapping = sectionComputers.first(where: { $0.section == todo.section }) else {
                    throw TodoHubError.conflict("Section \(todo.section.rawValue) has no computer assigned")
                }
                return Conversation(
                    todoId: todo.id, computer: mapping.computer, cwd: mapping.cwd, tool: mapping.tool,
                    tmuxName: "todo-\(todo.id)", sessionId: "demo-\(todo.id)", status: .busy,
                    statusMessage: nil, createdAt: "2026-10-17T09:00:00Z"
                )
            },
            cachedConversation: { _ in nil },
            isOffline: { false },
            resolveConfig: { _ in (hostID, config) }
        )
    }
}
#endif
