import AISessionCore
import SwiftUI

/// Where a fix lives in Settings; `SettingsView(initial:)` opens on it.
enum SettingsDestination: Hashable {
    case server
    case sections(TodoSection?)
    case access
    case terminal
    case notifications
}

/// What a `FrameStateView` button can ask the frame to do.
struct FrameActions {
    var openSettings: (SettingsDestination) -> Void
    var setUpAccess: (Computer) -> Void
    /// This device's access to the named computer: its own editor when the frame can find it,
    /// else Access & keys.
    var editAccess: (String) -> Void
    var retry: () -> Void
    var copy: (String) -> Void
    var unlink: () -> Void
}

extension Conversation {
    /// Body of the "Delete this conversation?" confirmation.
    var deleteConfirmationMessage: String {
        tool == "codex"
            ? "Ends the conversation on \(computer.name), archives it there and unlinks it. The todo stays."
            : "Ends the conversation on \(computer.name), deletes it there and unlinks it. The todo stays."
    }
}

/// Toolbar items for a conversation.
///
/// The detail column keeps several frames mounted in one window. Each of them used to publish
/// a toolbar, and AppKit threw inside `NSToolbar` insert when a selection change added items
/// whose identifiers were already in the bar. The column owns the title and the actions, and
/// those identifiers do not include the todo. A frame publishes a toolbar only when it is the
/// only frame in its window.
enum ConversationToolbar {
    static let titleID = "conversation.title"
    static let actionsID = "conversation.actions"
    /// Gap between the status pill, copy, pop-out, and menu. The old toolbar group spaced
    /// these; an `HStack` with no spacing packs them together.
    static let controlSpacing = DS.spacing.s

    static func framePublishesToolbar(sharesColumn: Bool) -> Bool {
        !sharesColumn
    }

    /// Same ids for every todo, so selecting another conversation updates these items
    /// instead of inserting a second set.
    static func columnItemIDs(todoID: String) -> [String] {
        [titleID, actionsID]
    }

    /// A phone screen or a pop-out window. The title item is omitted when the window title
    /// already names the todo.
    static func frameItemIDs(showsTitle: Bool) -> [String] {
        showsTitle ? [titleID, actionsID] : [actionsID]
    }

    /// A toolbar click can arrive before the frame is mounted. Run it once that frame is
    /// the one on screen; leave it waiting otherwise.
    static func commandToRun(
        pending: ConversationToolbarRequest?,
        todoID: String,
        isFrontmost: Bool
    ) -> ConversationToolbarCommand? {
        guard let pending, pending.todoID == todoID, isFrontmost else { return nil }
        return pending.command
    }

    @MainActor
    static func displayStatus(todo: Todo, store: TodoHubStore, selectedKey: String? = nil) -> ConversationDisplayStatus? {
        let conversation = store.displayed(forTodo: todo.id, selectedKey: selectedKey)
        guard conversation != nil || todo.conversationStatus != nil else { return nil }
        return ConversationDisplayStatus(
            conversation?.status ?? todo.conversationStatus ?? .unknown,
            tmuxAlive: nil
        )
    }
}

/// What the column's toolbar asks the frontmost frame to do. The frame owns the terminal,
/// the confirmation dialogs and the "Copied" toast.
enum ConversationToolbarCommand: Equatable {
    case copyResume
    case memories
    case close
    case delete
    case reconnect
    case copyScreen
    case paste
    case duplicate(tool: String, name: String)
}

struct ConversationToolbarRequest: Equatable {
    var command: ConversationToolbarCommand
    var todoID: String
    /// Two equal commands in a row still both arrive.
    var id = UUID()
}

/// Ready / connected, published by the frontmost frame so the column toolbar can enable
/// the terminal actions. Background frames publish nil.
struct ConversationTerminalState: Equatable {
    var todoID: String
    var isReady: Bool
    var isConnected: Bool
    /// A duplicate is being made; Duplicate in is off until it is done.
    var isDuplicating = false
}

struct ConversationTerminalStateKey: PreferenceKey {
    static var defaultValue: ConversationTerminalState? = nil
    static func reduce(value: inout ConversationTerminalState?, nextValue: () -> ConversationTerminalState?) {
        if let next = nextValue() { value = next }
    }
}

/// The ⋯ menu of the conversation frame. Conversation actions need a linked conversation (and
/// the hub, to close or delete it); terminal actions need a connected terminal.
struct ConversationMenu: View {
    let hasConversation: Bool
    /// Close and Delete: a linked conversation and the hub online.
    let canChange: Bool
    let isReady: Bool
    let isConnected: Bool
    /// iOS has no ⎘ button in the header, so copying the resume command lives here.
    let onCopyResume: (() -> Void)?
    /// The project's (or else the todo's) memories next to the conversation.
    let onMemories: () -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onCopyScreen: () -> Void
    let onPaste: () -> Void

    @AppStorage(TextSizeShortcuts.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize

    var body: some View {
        Menu {
            if let onCopyResume {
                Button(action: onCopyResume) {
                    Label("Copy Resume Command", systemImage: "doc.on.doc")
                }
                .disabled(!hasConversation)
            }
            Button(action: onMemories) {
                Label("Memories", systemImage: "lightbulb")
            }
            .disabled(!hasConversation)
            Button(action: onClose) {
                Label("Close Conversation", systemImage: "xmark.circle")
            }
            .disabled(!canChange)
            Button(role: .destructive, action: onDelete) {
                Label("Delete Conversation…", systemImage: "trash")
            }
            .disabled(!canChange)
            Divider()
            Button(action: onReconnect) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(!isReady)
            Button(action: onCopyScreen) {
                Label("Copy Screen", systemImage: "doc.on.clipboard")
            }
            .disabled(!isConnected)
            Button(action: onPaste) {
                Label("Paste", systemImage: "doc.on.clipboard.fill")
            }
            .disabled(!isConnected)
            Menu {
                Button("Bigger") { TextSizeShortcuts.step(by: 1) }
                Button("Smaller") { TextSizeShortcuts.step(by: -1) }
                Button("Default") { fontSize = TerminalAppearance.defaultFontSize }
            } label: {
                Label("Text Size", systemImage: "textformat.size")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

struct ConversationToolbarTitle: View {
    enum Style {
        /// iOS principal item.
        case centered
        /// Mac toolbar, at the leading edge of the detail column.
        case leading
    }

    var title: String
    var subtitle: String
    var style: Style

    var body: some View {
        VStack(alignment: style == .leading ? .leading : .center, spacing: 1) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(style == .leading ? .subheadline : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(style == .leading ? .isHeader : [])
    }
}

/// Status, copy, pop-out and the ⋯ menu. One view inside a single toolbar item, so a status
/// pill appearing does not insert another `NSToolbar` item.
struct ConversationToolbarActions: View {
    var status: ConversationDisplayStatus?
    var showsCopy: Bool
    var canCopy: Bool
    var showsPopOut: Bool
    var hasConversation: Bool
    var canChange: Bool
    var isReady: Bool
    var isConnected: Bool
    /// iOS keeps Copy Resume Command in the menu; the Mac has a button for it.
    var copyInMenu: Bool
    var onCopy: () -> Void
    var onPopOut: () -> Void
    var onMemories: () -> Void
    var onClose: () -> Void
    var onDelete: () -> Void
    var onReconnect: () -> Void
    var onCopyScreen: () -> Void
    var onPaste: () -> Void
    /// Offered only while this frame is showing a conversation.
    var showsDuplicate: Bool
    var duplicateName: String
    var onDuplicate: (String, String) -> Void
    /// A duplicate is being made. The frame shows its progress; a second one waits.
    var isDuplicating = false

    var body: some View {
        HStack(spacing: ConversationToolbar.controlSpacing) {
            if let status {
                StatusBadge(status, style: .pill)
                    .padding(.horizontal, DS.spacing.xs)
            }
            if showsCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                #if os(macOS)
                .help("Copy Resume Command")
                #endif
                .accessibilityLabel("Copy Resume Command")
                .disabled(!canCopy)
            }
            if showsPopOut {
                Button(action: onPopOut) {
                    Image(systemName: ConversationFrame.popOutSymbol)
                }
                #if os(macOS)
                .help("Open in New Window (⇧⌘O)")
                #endif
                .accessibilityLabel("Open in New Window")
            }
            if showsDuplicate {
                DuplicateInMenu(proposedName: duplicateName, onConfirm: onDuplicate)
                    .disabled(isDuplicating)
            }
            ConversationMenu(
                hasConversation: hasConversation,
                canChange: canChange,
                isReady: isReady,
                isConnected: isConnected,
                onCopyResume: copyInMenu ? onCopy : nil,
                onMemories: onMemories,
                onClose: onClose,
                onDelete: onDelete,
                onReconnect: onReconnect,
                onCopyScreen: onCopyScreen,
                onPaste: onPaste
            )
        }
    }
}

/// Brief confirmation after copying, shown over the top of the terminal area.
struct CopiedToast: View {
    var body: some View {
        Text("Copied")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, DS.spacing.l)
            .padding(.vertical, DS.spacing.s)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, DS.spacing.m)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Shown over the top of the terminal area while a duplicate is read, summarised and started.
struct DuplicatingToast: View {
    var body: some View {
        HStack(spacing: DS.spacing.s) {
            ProgressView()
                .controlSize(.small)
            Text("Duplicating…")
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, DS.spacing.l)
        .padding(.vertical, DS.spacing.s)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, DS.spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Duplicating the conversation")
    }
}
