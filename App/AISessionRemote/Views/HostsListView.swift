import SwiftData
import SwiftUI

struct HostsListView: View {
    @Query private var hosts: [HostEntity]

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
                        VStack(alignment: .leading) {
                            Text(host.displayName)
                                .font(.headline)
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Hosts")
        }
    }
}

#Preview {
    HostsListView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
