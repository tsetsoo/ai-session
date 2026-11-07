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

    /// The menu's Resume After Session Limit: shown for a Codex conversation the hub has
    /// stored, with its current value. Claude continues on its own.
    static func resumeToggle(_ conversation: Conversation?) -> Bool? {
        guard let conversation, conversation.canAutoResumeAfterLimit, !conversation.id.isEmpty else { return nil }
        return conversation.resumeOnReset
    }

    @MainActor
    static func displayStatus(todo: Todo, store: TodoHubStore, selectedKey: String? = nil) -> ConversationDisplayStatus? {
        let conversation = store.displayed(forTodo: todo.id, selectedKey: selectedKey)
        guard conversation != nil || todo.conversationStatus != nil else { return nil }
        return ConversationDisplayStatus(
            conversation?.status ?? todo.conversationStatus ?? .unknown,
            tmuxAlive: nil,
            paused: conversation?.paused != nil
        )
    }
}

/// What the column's toolbar asks the frontmost frame to do. The frame owns the terminal,
/// the confirmation dialogs and the "Copied" toast.
enum ConversationToolbarCommand: Equatable {
    case rename
    case servers
    case restart
    case copyResume
    case memories
    /// The Mac's Workers panel.
    case workers
    case close
    case delete
    case reconnect
    case copyScreen
    case paste
    /// Review Changes… (Mac): the frame knows the conversation, including one the hub hasn't listed yet.
    case review
    /// Resume After Session Limit on or off.
    case toggleResume
    /// The one-tap Resume once a weekly or unknown limit has reset.
    case resumeNow
    case addAgent
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
    /// Rename: the hub online (a todo without a conversation can be renamed too).
    let canRename: Bool
    let onRename: () -> Void
    /// Servers…: a Claude or Codex conversation and the hub online.
    let canChangeServers: Bool
    let onServers: () -> Void
    /// Restart…: a linked conversation.
    let canRestart: Bool
    let onRestart: () -> Void
    let isReady: Bool
    let isConnected: Bool
    /// iOS has no ⎘ button in the header, so copying the resume command lives here.
    let onCopyResume: (() -> Void)?
    /// The project's (or else the todo's) memories next to the conversation.
    let onMemories: () -> Void
    /// The conversation's delegated work (Mac); nil hides it.
    var onWorkers: (() -> Void)? = nil
    let onClose: () -> Void
    let onDelete: () -> Void
    let onReconnect: () -> Void
    let onCopyScreen: () -> Void
    let onPaste: () -> Void
    /// Review Changes… (Mac): the conversation's worktree changes in their own window. On
    /// the phone: its open review items.
    var onReview: (() -> Void)? = nil
    /// Resume After Session Limit: nil hides it (no conversation, or not Codex).
    var resumeOnReset: Bool? = nil
    var onToggleResume: () -> Void = {}

    @AppStorage(TextSizeShortcuts.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename…", systemImage: "pencil")
            }
            .disabled(!canRename)
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
            if let onWorkers {
                Button(action: onWorkers) {
                    Label("Workers", systemImage: "person.2")
                }
                .disabled(!hasConversation)
            }
            if let onReview {
                Button(action: onReview) {
                    #if os(macOS)
                    Label("Review Changes…", systemImage: "text.badge.checkmark")
                    #else
                    Label("Review", systemImage: "text.badge.checkmark")
                    #endif
                }
                .disabled(!hasConversation)
            }
            Button(action: onServers) {
                Label("Servers…", systemImage: "server.rack")
            }
            .disabled(!canChangeServers)
            Button(action: onRestart) {
                Label("Restart…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!canRestart)
            if let resumeOnReset {
                // Continues on its own once a 5-hour limit resets. Weekly limits always ask.
                Toggle(isOn: Binding(get: { resumeOnReset }, set: { _ in onToggleResume() })) {
                    Label("Resume After Session Limit", systemImage: "arrow.clockwise.circle")
                }
                .disabled(!canChange)
            }
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
    /// Click or tap to rename; nil while renaming isn't possible (offline).
    var onRename: (() -> Void)?

    var body: some View {
        if let onRename {
            Button(action: onRename) { label }
                .buttonStyle(.plain)
                #if os(macOS)
                .help("Rename")
                #endif
                .accessibilityHint("Renames the todo")
        } else {
            label
        }
    }

    private var label: some View {
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
    /// Why it is paused and when it resumes, shown with a paused status.
    var statusDetail: String? = nil
    /// The conversation branch's pull/merge request, when its computer found one.
    var pullRequest: PullRequestLink? = nil
    var showsCopy: Bool
    var canCopy: Bool
    var showsPopOut: Bool
    var hasConversation: Bool
    var canChange: Bool
    var canRename: Bool
    var canChangeServers: Bool
    var canRestart: Bool
    var isReady: Bool
    var isConnected: Bool
    /// iOS keeps Copy Resume Command in the menu; the Mac has a button for it.
    var copyInMenu: Bool
    var onRename: () -> Void
    var onServers: () -> Void
    var onRestart: () -> Void
    var onCopy: () -> Void
    var onPopOut: () -> Void
    var onMemories: () -> Void
    var onWorkers: (() -> Void)? = nil
    var onClose: () -> Void
    var onDelete: () -> Void
    var onReconnect: () -> Void
    var onCopyScreen: () -> Void
    var onPaste: () -> Void
    /// Offered only while this frame is showing a conversation.
    var showsAddAgent: Bool
    var onAddAgent: () -> Void
    /// A duplicate is being made. The frame shows its progress; a second one waits.
    var isDuplicating = false
    var onReview: (() -> Void)? = nil
    /// Resume After Session Limit in the menu: nil hides it.
    var resumeOnReset: Bool? = nil
    var onToggleResume: () -> Void = {}
    /// A weekly or unknown limit has reset: the one-tap Resume.
    var showsResumeNow = false
    var onResumeNow: () -> Void = {}

    var body: some View {
        HStack(spacing: ConversationToolbar.controlSpacing) {
            if let pullRequest {
                PullRequestChip(pullRequest: pullRequest, compact: copyInMenu)
            }
            if let status {
                StatusBadge(status, style: .pill, detail: statusDetail)
                    .padding(.horizontal, DS.spacing.xs)
            }
            if showsResumeNow {
                ResumeAfterLimitButton(action: onResumeNow)
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
            if showsAddAgent {
                Button(action: onAddAgent) {
                    Image(systemName: "plus.square.on.square")
                }
                .accessibilityLabel("Add Agent")
                #if os(macOS)
                .help("Add Agent…")
                #endif
                    .disabled(isDuplicating)
            }
            ConversationMenu(
                hasConversation: hasConversation,
                canChange: canChange,
                canRename: canRename,
                onRename: onRename,
                canChangeServers: canChangeServers,
                onServers: onServers,
                canRestart: canRestart,
                onRestart: onRestart,
                isReady: isReady,
                isConnected: isConnected,
                onCopyResume: copyInMenu ? onCopy : nil,
                onMemories: onMemories,
                onWorkers: onWorkers,
                onClose: onClose,
                onDelete: onDelete,
                onReconnect: onReconnect,
                onCopyScreen: onCopyScreen,
                onPaste: onPaste,
                onReview: onReview,
                resumeOnReset: resumeOnReset,
                onToggleResume: onToggleResume
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
