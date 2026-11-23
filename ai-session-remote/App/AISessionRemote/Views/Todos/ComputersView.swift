import AISessionCore
import SwiftData
import SwiftUI

/// Manage the hub's computers.
struct ComputersView: View {
    let store: TodoHubStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddComputer = false
    /// Shown inside this sheet: the Todos screen's alert can't present over it.
    @State private var errorMessage: String?
    @State private var computerToDelete: Computer?
    @State private var serversComputer: Computer?
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]

    init(store: TodoHubStore) { self.store = store }

    var body: some View {
        NavigationStack {
            List {
                Section("Computers") {
                    if store.computers.isEmpty {
                        Text("No computers yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.computers) { computer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(computer.name)
                            Text("\(computer.username)@\(computer.hostname):\(computer.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .swipeActions {
                            // Not the destructive role: it would slide the row away before the
                            // confirmation, and back again on Cancel.
                            Button {
                                computerToDelete = computer
                            } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                            .tint(DS.destructive)
                            Button {
                                serversComputer = computer
                            } label: {
                                Label("Default Servers…", systemImage: "server.rack")
                            }
                            .tint(DS.memory)
                        }
                        .contextMenu {
                            ComputerOrderActions(computerID: computer.id, store: store)
                            Button {
                                serversComputer = computer
                            } label: {
                                Label("Default Servers…", systemImage: "server.rack")
                            }
                            Button(role: .destructive) {
                                computerToDelete = computer
                            } label: {
                                Label("Delete…", systemImage: "trash")
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
            .skinnedList()
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
            .sheet(item: $serversComputer) { computer in
                MCPServersSheet(
                    computer: computer, store: store, hosts: hosts, selection: computer.mcpDefault,
                    allowsUnmanaged: true, unmanagedTitle: "No default",
                    unmanagedDetail: "A new conversation starts with the tool's own servers",
                    confirmTitle: "Save",
                    onConfirm: { names in
                        serversComputer = nil
                        run { try await store.setDefaultServers(names, for: computer) }
                    },
                    onCancel: { serversComputer = nil }
                )
            }
            .confirmationDialog(
                "Delete \(computerToDelete?.name ?? "computer")?",
                isPresented: Binding(get: { computerToDelete != nil }, set: { if !$0 { computerToDelete = nil } }),
                titleVisibility: .visible,
                presenting: computerToDelete
            ) { computer in
                Button("Delete Computer", role: .destructive) {
                    run { try await store.deleteComputer(computer) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It's removed from the todo server for all your devices. A computer still used for routing, conversations or projects can't be deleted.")
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
                FormTextField("Name", text: $name)
                FormTextField("Hostname (Tailscale name or IP)", text: $hostname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                FormTextField("Port", text: $port).keyboardType(.numberPad)
                FormTextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .skinnedList()
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
