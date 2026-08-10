import SwiftData
import SwiftUI

struct HostsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var hosts: [HostEntity]
    @State private var showingHostEditor = false
    @State private var editingHost: HostEntity?
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
                        NavigationLink {
                            SessionsPlaceholderView(host: host)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(host.displayName.isEmpty ? host.hostname : host.displayName)
                                    .font(.headline)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingHost = host
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editingHost = host
                            } label: {
                                Label("Edit Host", systemImage: "pencil")
                            }
                        }
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
            .sheet(item: $editingHost) { host in
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

private struct SessionsPlaceholderView: View {
    let host: HostEntity

    var body: some View {
        ContentUnavailableView(
            "Sessions",
            systemImage: "terminal",
            description: Text("Sessions for \(host.displayName.isEmpty ? host.hostname : host.displayName) will appear here.")
        )
        .navigationTitle("Sessions")
    }
}

#Preview {
    HostsListView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
