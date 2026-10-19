import AISessionCore
import SwiftUI

/// Manage the hub's computers and which computer each section uses.
struct ComputersView: View {
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddComputer = false
    @State private var editingSection: TodoSection?
    /// Shown inside this sheet: the Todos screen's alert can't present over it.
    @State private var errorMessage: String?

    /// `editing` opens that section's computer at once (a fix from the frame).
    init(store: TodoHubStore, editing section: TodoSection? = nil) {
        self.store = store
        _editingSection = State(initialValue: section)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TodoSection.allCases) { section in
                        Button {
                            editingSection = section
                        } label: {
                            HStack {
                                Text(section.rawValue).font(.headline).frame(width: 32, alignment: .leading)
                                if let mapping = store.sectionComputers[section] {
                                    Text(mapping.computer.name)
                                } else {
                                    Text("No computer").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("New conversations for a section's todos start on its computer, in this folder.")
                }

                Section("Computers") {
                    if store.computers.isEmpty {
                        Text("No computers yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.computers) { computer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(computer.name)
                            Text("\(computer.username)@\(computer.hostname):\(computer.port)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                run { try await store.deleteComputer(computer) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        showingAddComputer = true
                    } label: {
                        Label("Add Computer", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showingAddComputer) {
                AddComputerSheet { name, hostname, port, username in
                    run { try await store.addComputer(name: name, hostname: hostname, port: port, username: username) }
                }
            }
            .sheet(item: $editingSection) { section in
                SectionMappingSheet(
                    section: section,
                    computers: store.computers,
                    current: store.sectionComputers[section]
                ) { computerID in
                    run { try await store.assign(section, computerID: computerID) }
                }
            }
            .alert(
                "Computers",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = TodoHubStore.message(for: error)
            }
        }
    }
}

private struct AddComputerSheet: View {
    let onAdd: (String, String, Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Hostname (Tailscale name or IP)", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("New Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name.trimmed, hostname.trimmed, Int(port) ?? 22, username.trimmed)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let p = Int(port), (1...65535).contains(p) else { return false }
        return !name.trimmed.isEmpty && !hostname.trimmed.isEmpty && !hostname.contains(" ")
            && !username.trimmed.isEmpty
    }
}

private struct SectionMappingSheet: View {
    let section: TodoSection
    let computers: [Computer]
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var computerID: String?

    init(section: TodoSection, computers: [Computer], current: SectionComputer?,
         onSave: @escaping (String?) -> Void) {
        self.section = section
        self.computers = computers
        self.onSave = onSave
        _computerID = State(initialValue: current?.computer.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Computer", selection: $computerID) {
                    Text("None").tag(String?.none)
                    ForEach(computers) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            .navigationTitle(section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(computerID)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
