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
    let onClose: () -> Void
    let onDelete: () -> Void
    let terminal: TerminalHandle

    @AppStorage(TextSizeShortcuts.fontSizeKey) private var fontSize = TerminalAppearance.defaultFontSize

    var body: some View {
        Menu {
            if let onCopyResume {
                Button(action: onCopyResume) {
                    Label("Copy Resume Command", systemImage: "doc.on.doc")
                }
                .disabled(!hasConversation)
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
            Button {
                terminal.reconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .disabled(!isReady)
            Button {
                terminal.copyScreen()
            } label: {
                Label("Copy Screen", systemImage: "doc.on.clipboard")
            }
            .disabled(!isConnected)
            Button {
                terminal.paste()
            } label: {
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
