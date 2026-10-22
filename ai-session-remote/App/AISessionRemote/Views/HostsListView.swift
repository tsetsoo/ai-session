import AISessionCore
import Foundation
import SwiftData
import SwiftUI

struct HostsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var showingHostEditor = false
    @State private var editingHost: HostEntity?
    @State private var errorMessage: String?
    @State private var reachability: [UUID: Bool] = [:]
    @State private var isProbing = false
    @State private var plainShellHost: HostEntity?
    /// Hosts waiting on the delete confirmation: deleting also removes the private key.
    @State private var hostsToDelete: [HostEntity] = []

    var body: some View {
        // The only stack in the Access & keys sheet (`AccessSettings` draws just a Done row
        // above it); host rows push into that host's sessions. The bar stays hidden so the
        // title below sits under Done instead of in a second bar.
        NavigationStack {
            VStack(spacing: 0) {
                header
                Group {
                    if hosts.isEmpty {
                        emptyState
                    } else {
                        hostList
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await refreshReachability()
            }
            .sheet(isPresented: $showingHostEditor) {
                HostEditorView()
            }
            .sheet(item: $editingHost) { host in
                HostEditorView(host: host)
            }
            .sheet(item: $plainShellHost) { host in
                NavigationStack {
                    plainShellDestination(for: host)
                }
            }
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: Binding(
                    get: { !hostsToDelete.isEmpty },
                    set: { if !$0 { hostsToDelete = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button(hostsToDelete.count == 1 ? "Delete Host and Key" : "Delete Hosts and Keys", role: .destructive) {
                    delete(hostsToDelete)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(hostsToDelete.count == 1
                    ? "Its connection details and private key are removed from this device. To add it again you'll need the key file."
                    : "Their connection details and private keys are removed from this device. To add them again you'll need the key files.")
            }
            .alert("Could not delete host", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard !hosts.isEmpty else { return }
                await refreshReachability()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Access & keys")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button {
                showingHostEditor = true
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(.fill.tertiary, in: Circle())
            }
            .accessibilityLabel("Add Host")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Hosts",
            systemImage: "server.rack",
            description: Text("Tap + to add a Tailscale-reachable machine with an SSH key.")
        )
    }

    private var hostList: some View {
        List {
            ForEach(hosts) { host in
                NavigationLink {
                    SessionsListView(host: host)
                } label: {
                    hostRow(host)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        editingHost = host
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(DS.accentSolid)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Not the destructive role (or onDelete): either slides the row away before
                    // the confirmation, and back again on Cancel.
                    Button {
                        hostsToDelete = [host]
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                    .tint(.red)
                    Button {
                        plainShellHost = host
                    } label: {
                        Label("SSH", systemImage: "terminal")
                    }
                    .tint(.gray)
                }
                .contextMenu {
                    Button {
                        editingHost = host
                    } label: {
                        Label("Edit Host", systemImage: "pencil")
                    }
                    Button {
                        plainShellHost = host
                    } label: {
                        Label("Plain SSH", systemImage: "terminal")
                    }
                    Divider()
                    Button(role: .destructive) {
                        hostsToDelete = [host]
                    } label: {
                        Label("Delete…", systemImage: "trash")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if isProbing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
                    .accessibilityLabel("Checking host reachability")
            }
        }
    }

    private func hostRow(_ host: HostEntity) -> some View {
        let status = reachability[host.id]
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.reachabilityColor(status).opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.reachabilityColor(status))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName.isEmpty ? host.hostname : host.displayName)
                    .font(.headline)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(AppTheme.reachabilityLabel(status))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AppTheme.reachabilityColor(status))
                    if let relative = AppTheme.relativeTime(from: host.lastReachableAt), status == true {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let health = host.binaryHealth {
                    HStack(spacing: 7) {
                        binaryStatus("tmux", ok: health.tmuxOK)
                        binaryStatus("claude", ok: health.claudeOK)
                        binaryStatus("codex", ok: health.codexOK)
                        binaryStatus("agent", ok: health.agentOK)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: host, status: status))
    }

    private func binaryStatus(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(name)
        }
        .accessibilityLabel("\(name) \(ok ? "available" : "missing")")
    }

    private func accessibilityLabel(for host: HostEntity, status: Bool?) -> String {
        let name = host.displayName.isEmpty ? host.hostname : host.displayName
        return "\(name), \(host.username) at \(host.hostname) port \(host.port), \(AppTheme.reachabilityLabel(status))"
    }

    @ViewBuilder
    private func plainShellDestination(for host: HostEntity) -> some View {
        if let connection = try? SessionServiceFactory().make(for: host) {
            TerminalScreen(
                hostConfig: connection.config,
                mode: .plainShell,
                title: "Plain SSH",
                onKill: {}
            )
        } else {
            ContentUnavailableView(
                "Terminal Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The private key for this host is unavailable. Edit the host and save its key again.")
            )
        }
    }

    private var deleteConfirmationTitle: String {
        guard hostsToDelete.count == 1, let host = hostsToDelete.first else {
            return "Delete \(hostsToDelete.count) hosts?"
        }
        return "Delete \(host.displayName.isEmpty ? host.hostname : host.displayName)?"
    }

    private func delete(_ hostsToRemove: [HostEntity]) {
        let repository = HostRepository(modelContext: modelContext)
        for host in hostsToRemove {
            do {
                try repository.delete(host)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Probes every host concurrently (each bounded by `ReachabilityProbe`'s own short
    /// deadlines) so a single unreachable/misconfigured host can't stall the dots for the
    /// rest of the list the way a sequential loop would. Only `Sendable` data
    /// (`HostConnectionConfig`, `UUID`) crosses into the concurrent tasks — `HostEntity`
    /// itself is a non-`Sendable` SwiftData model, so it's only touched back here on the
    /// main actor once each probe's result comes in.
    @MainActor
    private func refreshReachability() async {
        isProbing = true
        defer { isProbing = false }

        let repository = HostRepository(modelContext: modelContext)
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })

        var configsByID: [UUID: HostConnectionConfig] = [:]
        var servicesByID: [UUID: SessionService] = [:]
        for host in hosts {
            guard let pem = try? repository.privateKey(for: host) else {
                reachability[host.id] = false
                continue
            }
            configsByID[host.id] = HostConnectionConfig(
                host: host.hostname,
                port: host.port,
                username: host.username,
                privateKeyPEM: Data(pem.utf8),
                hostID: host.id.uuidString
            )
            if let connection = try? SessionServiceFactory().make(for: host) {
                servicesByID[host.id] = connection.service
            }
        }

        await withTaskGroup(of: (UUID, Bool, HostBinaryHealth?).self) { group in
            for (hostID, config) in configsByID {
                group.addTask {
                    let reachable = await ReachabilityProbe().isReachable(config)
                    guard reachable, let service = servicesByID[hostID] else {
                        return (hostID, false, nil)
                    }
                    let health = try? await service.probeBinaries(config: config)
                    return (hostID, true, health)
                }
            }
            for await (hostID, reachable, health) in group {
                reachability[hostID] = reachable
                if reachable {
                    hostsByID[hostID]?.lastReachableAt = Date()
                    hostsByID[hostID]?.binaryHealth = health
                    hostsByID[hostID]?.binaryHealthCheckedAt = Date()
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
