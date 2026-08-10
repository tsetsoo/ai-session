import AISessionCore
import Foundation
import SwiftData
import SwiftUI

struct HostsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var hosts: [HostEntity]
    @State private var showingHostEditor = false
    @State private var editingHost: HostEntity?
    @State private var errorMessage: String?
    @State private var reachability: [UUID: Bool] = [:]

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
                            SessionsListView(host: host)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                reachabilityDot(for: host)
                                VStack(alignment: .leading) {
                                    Text(host.displayName.isEmpty ? host.hostname : host.displayName)
                                        .font(.headline)
                                    Text("\(host.username)@\(host.hostname):\(host.port)")
                                        .foregroundStyle(.secondary)
                                }
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
            .refreshable {
                await refreshReachability()
            }
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

    @ViewBuilder
    private func reachabilityDot(for host: HostEntity) -> some View {
        let color: Color = {
            switch reachability[host.id] {
            case .some(true): .green
            case .some(false): .red
            case .none: Color.secondary.opacity(0.3)
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    /// Probes every host concurrently (each bounded by `ReachabilityProbe`'s own short
    /// deadlines) so a single unreachable/misconfigured host can't stall the dots for the
    /// rest of the list the way a sequential loop would. Only `Sendable` data
    /// (`HostConnectionConfig`, `UUID`) crosses into the concurrent tasks — `HostEntity`
    /// itself is a non-`Sendable` SwiftData model, so it's only touched back here on the
    /// main actor once each probe's result comes in.
    @MainActor
    private func refreshReachability() async {
        let repository = HostRepository(modelContext: modelContext)
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })

        var configsByID: [UUID: HostConnectionConfig] = [:]
        for host in hosts {
            guard let pem = try? repository.privateKey(for: host) else {
                reachability[host.id] = false
                continue
            }
            configsByID[host.id] = HostConnectionConfig(
                host: host.hostname,
                port: host.port,
                username: host.username,
                privateKeyPEM: Data(pem.utf8)
            )
        }

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for (hostID, config) in configsByID {
                group.addTask {
                    (hostID, await ReachabilityProbe().isReachable(config))
                }
            }
            for await (hostID, reachable) in group {
                reachability[hostID] = reachable
                if reachable {
                    hostsByID[hostID]?.lastReachableAt = Date()
                }
            }
        }

        try? modelContext.save()
    }
}

#Preview {
    HostsListView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
