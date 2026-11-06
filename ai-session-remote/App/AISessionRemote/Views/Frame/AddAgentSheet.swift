import AISessionCore
import SwiftUI

/// What the person chose in the Add Agent sheet.
struct AddAgentChoice: Equatable {
    var tool: String
    var model: String
    var name: String
    var handoff: AddAgentHandoff
    /// The edited summary (Summary, and Full conversation when it is too long).
    var summary: String?
}

/// Add Agent: another agent on this todo, with a hand-off from this conversation. Replaces
/// Duplicate. Summary is the default: it is written now and can be edited before it's sent.
struct AddAgentSheet: View {
    var proposedName: String
    /// The new agent gets a worktree of its own (else both work in the same folder).
    var ownWorktree: Bool
    var loadSummary: () async throws -> String
    var onStart: (AddAgentChoice) -> Void
    var onCancel: () -> Void

    @State private var tool = "codex"
    @State private var model = ""
    @State private var name = ""
    @State private var handoff = AddAgentHandoff.defaultChoice
    @State private var summary = ""
    @State private var summaryState = SummaryState.idle

    private enum SummaryState: Equatable {
        case idle, loading, ready, failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Agent", selection: $tool) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Cursor").tag("cursor")
                    }
                    TextField("Model", text: $model, prompt: Text("Default"))
                        .autocorrectionDisabled()
                    TextField("Name", text: $name, prompt: Text(proposedName))
                }
                Section {
                    Picker("Start with", selection: $handoff) {
                        Text("Summary").tag(AddAgentHandoff.summary)
                        Text("Full conversation").tag(AddAgentHandoff.full)
                        Text("Fresh with the same first message").tag(AddAgentHandoff.fresh)
                    }
                    if handoff == .summary {
                        summaryEditor
                    }
                } footer: {
                    Text(footer)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start).disabled(!canStart)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
        .task(id: handoff) { await loadSummaryIfNeeded() }
    }

    @ViewBuilder private var summaryEditor: some View {
        switch summaryState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing a summary of this conversation…").foregroundStyle(.secondary)
            }
        case .ready:
            TextEditor(text: $summary)
                .frame(minHeight: 180)
                .accessibilityLabel("Summary")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red)
                Button("Try Again") { Task { await loadSummaryIfNeeded(force: true) } }
            }
        }
    }

    private var footer: String {
        var lines: [String] = []
        switch handoff {
        case .summary: lines.append("The new agent starts with this summary as its first message.")
        case .full: lines.append("The new agent gets the whole conversation (a summary if it is too long).")
        case .fresh: lines.append("The new agent starts from the same first message, without this conversation.")
        }
        lines.append(ownWorktree
            ? "It works in a worktree of its own."
            : "Both agents will work in the same folder.")
        return lines.joined(separator: " ")
    }

    private var canStart: Bool {
        switch handoff {
        case .summary: return summaryState == .ready && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .full, .fresh: return true
        }
    }

    private func loadSummaryIfNeeded(force: Bool = false) async {
        guard handoff == .summary, force || summaryState == .idle else { return }
        summaryState = .loading
        do {
            summary = try await loadSummary()
            summaryState = .ready
        } catch {
            summaryState = .failed(TodoHubStore.message(for: error))
        }
    }

    private func start() {
        onStart(AddAgentChoice(
            tool: tool, model: model, name: DuplicateIn.submittedName(name, proposal: proposedName),
            handoff: handoff, summary: summaryState == .ready ? summary : nil
        ))
    }
}
