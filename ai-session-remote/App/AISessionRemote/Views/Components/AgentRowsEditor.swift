import AISessionCore
import SwiftUI

/// Agent rows (tool + model + remove) and Add Agent: Research Now and the Start step of a todo.
struct AgentRowsEditor: View {
    @Binding var rows: [ResearchAgentRow]
    let offered: [String]

    var body: some View {
        ForEach($rows) { $row in
            HStack {
                Picker("Agent", selection: $row.tool) {
                    ForEach(offered, id: \.self) { Text(ResearchAgents.toolName($0)).tag($0) }
                    if !offered.contains(row.tool) {
                        Text("\(ResearchAgents.toolName(row.tool)) (not installed)").tag(row.tool)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Model", text: $row.model, prompt: Text("Default model"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .foregroundStyle(ResearchAgents.isValidModel(row.model) ? Color.primary : DS.warning)
                Button {
                    rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(!ResearchAgents.canRemove(rows))
                .help("Remove this agent")
            }
        }
        Button("Add Agent", systemImage: "plus") {
            rows.append(StartAgents.addedRow(to: rows, offered: offered))
        }
        .disabled(!ResearchAgents.canAdd(rows) || offered.isEmpty)
    }
}
