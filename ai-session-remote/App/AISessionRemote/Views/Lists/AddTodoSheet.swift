import AISessionCore
import SwiftUI

struct AddTodoSheet: View {
    /// Offered as a Project picker when there are any.
    let projects: [Project]
    let onAdd: (TodoSection, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var section: TodoSection
    @State private var title = ""
    @State private var projectId: String?
    @FocusState private var titleFocused: Bool

    init(section: TodoSection = .i, projects: [Project] = [],
         onAdd: @escaping (TodoSection, String, String?) -> Void) {
        self.projects = projects
        self.onAdd = onAdd
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Section", selection: $section) {
                    ForEach(TodoSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // A plain TextField keeps the keyboard's dictation button available.
                TextField("Title", text: $title, axis: .vertical)
                    .focused($titleFocused)
                if !projects.isEmpty {
                    Picker("Project", selection: $projectId) {
                        Text("None").tag(String?.none)
                        ForEach(projects) { project in
                            Text(project.name).tag(String?.some(project.id))
                        }
                    }
                }
            }
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(section, title.trimmingCharacters(in: .whitespacesAndNewlines), projectId)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium])
    }
}
