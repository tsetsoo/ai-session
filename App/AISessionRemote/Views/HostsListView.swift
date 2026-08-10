import SwiftData
import SwiftUI

struct HostsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var hosts: [HostEntity]
    @State private var showingHostEditor = false
    @State private var selectedHost: HostEntity?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host to get started.")
                    )
                } else {
                    ForEach(hosts) { host in
                        Button {
                            selectedHost = host
                        } label: {
                            VStack(alignment: .leading) {
                                Text(host.displayName.isEmpty ? host.hostname : host.displayName)
                                    .font(.headline)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteHosts)
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingHostEditor = true
                    } label: {
                        Label("Add Host", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingHostEditor) {
                HostEditorView()
            }
            .sheet(item: $selectedHost) { host in
                HostEditorView(host: host)
            }
            .alert("Could not delete host", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func deleteHosts(at offsets: IndexSet) {
        let repository = HostRepository(modelContext: modelContext)
        for index in offsets {
            do {
                try repository.delete(hosts[index])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    HostsListView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
