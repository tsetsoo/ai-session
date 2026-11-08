import AISessionCore
import SwiftUI

/// Research Now: which agents research the idea, and on which computer. Opens every time,
/// with Claude and Codex at their default models.
struct ResearchAgentsSheet: View {
    let idea: Idea
    let store: TodoHubStore
    /// The note to show after starting (an older hub started Claude only), or nil.
    let onStarted: (String?) -> Void
    let onCancel: () -> Void

    @State private var computerId = ""
    @State private var rows: [ResearchAgentRow] = []
    @State private var starting = false
    @State private var errorMessage: String?

    private var computer: Computer? { store.computers.first { $0.id == computerId } }
    private var offered: [String] { ResearchAgents.offeredTools(installed: computer?.tools) }
    private var canStart: Bool {
        !starting && !computerId.isEmpty && !rows.isEmpty
            && rows.allSatisfy { offered.contains($0.tool) && ResearchAgents.isValidModel($0.model) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Computer", selection: $computerId) {
                        ForEach(store.computers) { Text($0.name).tag($0.id) }
                    }
                } footer: {
                    if computer != nil, computer?.tools == nil {
                        Text("This computer hasn't said which tools it has. An agent that isn't installed there won't start.")
                    } else if offered.isEmpty {
                        Text("No agent tools are installed on this computer.")
                    }
                }
                Section {
                    AgentRowsEditor(rows: $rows, offered: offered)
                } header: {
                    Text("Agents")
                } footer: {
                    Text("\(ResearchAgents.countText(rows.count)) Each agent works in its own copy of the project, from the same commit.")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(DS.warning)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Research Now")
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
        .frame(minWidth: 460, minHeight: 380)
        #endif
        .onAppear(perform: setUp)
        .onChange(of: computerId) { _, _ in keepOfferedTools() }
    }

    private func setUp() {
        guard computerId.isEmpty else { return }
        if let project = store.project(id: idea.projectId) {
            computerId = store.usualComputer(for: project).id
        } else {
            computerId = store.computers.first?.id ?? ""
        }
        rows = ResearchAgents.defaults(offered: offered)
    }

    /// Another computer: rows with a tool it lacks switch to one it has.
    private func keepOfferedTools() {
        guard let fallback = offered.first else { return }
        for index in rows.indices where !offered.contains(rows[index].tool) {
            rows[index].tool = fallback
        }
    }

    private func start() {
        starting = true
        Task {
            do {
                let note = try await store.researchIdea(idea, rows: rows, computerId: computerId)
                onStarted(note)
            } catch {
                errorMessage = TodoHubStore.message(for: error)
                starting = false
            }
        }
    }
}
