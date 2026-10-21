import AISessionCore
import SwiftUI

/// The name field and the rule that a cancelled summary creates nothing.
enum DuplicateIn {
    static func proposedName(existingLabels: [String]) -> String {
        DuplicateName.proposal(existingLabels: existingLabels)
    }

    /// An empty field submits the fill-in, not an empty name.
    static func submittedName(_ field: String, proposal: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? proposal : trimmed
    }

    /// What has to happen after the hub row exists, before the terminal attaches.
    enum FollowUp: Equatable {
        /// Claude forked the source. The row's minted id is not the fork's; store the one it creates.
        case captureFork(sourceSessionId: String)
        /// Codex and Cursor have no id yet. Start one and store the id the tool prints.
        case captureFresh
        /// The row already has the id the terminal should resume.
        case resume
    }

    static func followUp(plan: DuplicateHandoff.Plan, created: Conversation) -> FollowUp {
        switch plan {
        case let .fork(sourceSessionId, _):
            return .captureFork(sourceSessionId: sourceSessionId)
        case .start:
            return created.sessionId.isEmpty ? .captureFresh : .resume
        case .cancelled:
            return .resume
        }
    }

    /// `cancelled` returns without calling `create`. A fork or a start does.
    static func perform(_ plan: DuplicateHandoff.Plan, create: () async throws -> Void) async rethrows {
        switch plan {
        case .cancelled:
            return
        case .fork, .start:
            try await create()
        }
    }
}

/// Toolbar menu: Claude, Codex, Cursor, and the name of the new conversation.
struct DuplicateInMenu: View {
    var proposedName: String
    var onConfirm: (String, String) -> Void
    @State private var name = ""

    var body: some View {
        Menu {
            TextField("Name", text: $name)
            Button("Claude") { confirm("claude") }
            Button("Codex") { confirm("codex") }
            Button("Cursor") { confirm("cursor") }
        } label: {
            Image(systemName: "plus.square.on.square")
        }
        .accessibilityLabel("Duplicate in")
        #if os(macOS)
        .help("Duplicate in")
        #endif
        .onAppear { if name.isEmpty { name = proposedName } }
        .onChange(of: proposedName) { _, proposal in
            if name.isEmpty { name = proposal }
        }
    }

    private func confirm(_ tool: String) {
        onConfirm(tool, DuplicateIn.submittedName(name, proposal: proposedName))
    }
}
