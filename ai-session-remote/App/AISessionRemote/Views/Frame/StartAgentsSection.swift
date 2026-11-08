import AISessionCore
import SwiftUI

/// The Start step's agents and first message. One agent (`rows` empty) keeps today's tool
/// picker, shown by the caller, plus an optional first message and Add Agent. Several show
/// the agent rows, the commit they all start from, and a required first message.
struct StartAgentsSection: View {
    @Binding var rows: [ResearchAgentRow]
    @Binding var toolChoice: String
    @Binding var text: String
    @Binding var base: StartBase?
    let offered: [String]
    let refusal: String?
    let loadBase: () async throws -> StartBase

    @State private var baseError: String?

    private var several: Bool { rows.count > 1 }

    var body: some View {
        VStack(spacing: DS.spacing.s) {
            if several {
                VStack(alignment: .leading, spacing: DS.spacing.xs) {
                    AgentRowsEditor(rows: $rows, offered: offered)
                }
                .frame(maxWidth: 400)
                if let refusal {
                    note(refusal, warning: true)
                } else if let base {
                    note(StartAgents.baseLine(base))
                } else if let baseError {
                    note(baseError, warning: true)
                } else {
                    note("Finding the latest main…")
                }
                note("\(ResearchAgents.countText(rows.count)) Each agent works in its own copy of the project.")
            }
            TextField(
                "First message", text: $text,
                prompt: Text(several ? "First message" : "First message (optional)"), axis: .vertical
            )
            .lineLimit(3...8)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 400)
            if several {
                note("Every agent gets this as its first message.")
            } else {
                Button("Add Agent", systemImage: "plus") {
                    rows = [ResearchAgentRow(tool: toolChoice)]
                    rows.append(StartAgents.addedRow(to: rows, offered: offered))
                }
                .buttonStyle(.borderless)
                .disabled(offered.isEmpty)
                .help("Start this todo with several agents, each in its own copy of the project")
            }
        }
        .onChange(of: rows.count) { _, count in
            // Back to one agent: today's tool picker, with that agent's tool.
            if count == 1 {
                toolChoice = rows[0].tool
                rows = []
            }
        }
        .task(id: several && refusal == nil) {
            guard several, refusal == nil, base == nil else { return }
            baseError = nil
            do {
                base = try await loadBase()
            } catch {
                guard !Task.isCancelled else { return }
                baseError = TodoHubStore.message(for: error)
            }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(warning ? DS.warning : .secondary)
            .multilineTextAlignment(.center)
    }
}
