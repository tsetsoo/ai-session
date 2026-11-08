import AISessionCore
import SwiftUI

/// A todo with several open conversations: a tab for each (one on screen at a time), Side by
/// Side on the Mac, and Continue with This for the one shown. After Continue, only the note
/// that opens the closed attempts again.
struct ConversationSwitcherBar: View {
    var conversations: [Conversation]
    var selectedKey: String?
    @Binding var sideBySide: Bool
    var onSelect: (Conversation) -> Void
    var onContinue: (Conversation) -> Void
    var onReopenClosed: () -> Void
    /// A research todo's attempts that failed to start: shown beside the tabs, with Retry.
    var failed: [IdeaAttempt] = []
    var onRetry: (IdeaAttempt) -> Void = { _ in }

    private var tabs: [Conversation] { ConversationSwitcherModel.tabs(conversations) }
    private var selected: Conversation? {
        tabs.first { $0.listKey == selectedKey } ?? tabs.first
    }

    var body: some View {
        if ConversationSwitcherModel.showsSwitcher(conversations, failed: failed.count) {
            HStack(spacing: 8) {
                Picker("Conversation", selection: Binding(
                    get: { sideBySide ? Self.sideBySideTag : (selected?.listKey ?? "") },
                    set: { key in
                        if key == Self.sideBySideTag {
                            sideBySide = true
                        } else if let match = tabs.first(where: { $0.listKey == key }) {
                            sideBySide = false
                            onSelect(match)
                        }
                    }
                )) {
                    ForEach(tabs, id: \.listKey) { conversation in
                        Text(tabTitle(conversation)).tag(conversation.listKey)
                    }
                    #if os(macOS)
                    Text("Side by Side").tag(Self.sideBySideTag)
                    #endif
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ForEach(failed) { attempt in
                    Menu {
                        Text(ResearchAgents.stateText(attempt) ?? "Failed")
                        Button("Retry", systemImage: "arrow.clockwise") { onRetry(attempt) }
                    } label: {
                        Label("\(ResearchAgents.label(attempt)) · failed", systemImage: "exclamationmark.triangle")
                    }
                    .fixedSize()
                    .foregroundStyle(DS.warning)
                    .help("This agent didn't start")
                }
                Spacer(minLength: 0)
                if !sideBySide, let selected {
                    ConversationPaneHeader(conversation: selected, showsName: false) { onContinue(selected) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else if let note = ConversationSwitcherModel.closedNote(conversations) {
            HStack {
                Spacer()
                Button(note, systemImage: "rectangle.stack", action: onReopenClosed)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Open the other attempts again")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func tabTitle(_ conversation: Conversation) -> String {
        let glyph = ConversationSwitcherModel.statusGlyph(conversation.status)
        let label = ConversationSwitcherModel.label(conversation)
        return glyph.isEmpty ? label : "\(label) \(glyph)"
    }

    static let sideBySideTag = "side-by-side"
}

/// Tool · model, status, time since it started, and Continue with This.
struct ConversationPaneHeader: View {
    var conversation: Conversation
    var showsName = true
    var onContinue: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsName {
                Text(ConversationSwitcherModel.label(conversation)).font(.callout.weight(.semibold))
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(statusLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if showsName { Spacer(minLength: 0) }
            Button("Continue with This", action: onContinue)
                .controlSize(.small)
                .help("Keep this one; the others close and can be opened again")
        }
    }

    private func statusLine(now: Date) -> String {
        let status: String = switch conversation.status {
        case .busy: "Working"
        case .waiting: "Needs you"
        case .idle: "Ready"
        case .unknown: "Starting"
        case .closed: "Closed"
        }
        guard let elapsed = ConversationSwitcherModel.elapsed(since: conversation.createdAt, now: now) else { return status }
        return "\(status) · \(elapsed)"
    }
}
