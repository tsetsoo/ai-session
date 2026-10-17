import AISessionCore
import SwiftUI

struct AddTodoSheet: View {
    let onAdd: (TodoSection, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var section: TodoSection
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    init(section: TodoSection = .i, onAdd: @escaping (TodoSection, String) -> Void) {
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
            }
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(section, title.trimmingCharacters(in: .whitespacesAndNewlines))
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
