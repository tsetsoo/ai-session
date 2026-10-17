import AISessionCore
import SwiftData
import SwiftUI

/// The hub's computers with live counts, the sections each serves and whether this device can
/// reach it; then "Other computers", saved hosts that are no hub computer. Tapping a hub
/// computer calls `onOpen`.
struct ComputerListView: View {
    let onOpen: (Computer) -> Void

    @Environment(AppModel.self) private var model
    @Query(sort: \HostEntity.displayName) private var hosts: [HostEntity]
    @State private var setUpPrefill: HostEditorPrefill?

    init(onOpen: @escaping (Computer) -> Void) {
        self.onOpen = onOpen
    }

    private var store: TodoHubStore { model.store }

    var body: some View {
        let board = model.board
        let others = Self.otherHosts(hosts, computers: store.computers)
        List {
            ListStatusBanner(store: store)
            Section {
                if store.computers.isEmpty {
                    Text("No computers yet. Add one in Settings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.computers) { computer in
                    ComputerRow(
                        computer: computer,
                        sections: TodoSection.allCases.filter { store.sectionComputers[$0]?.computer.id == computer.id },
                        running: board.runningCount(computerID: computer.id),
                        needsYou: board.needsYouCount(computerID: computer.id),
                        hasAccess: HostLookup.host(for: computer, in: hosts) != nil,
                        onSetUp: { setUpPrefill = HostEditorPrefill(computer: computer) }
                    )
                    .rowTap { onOpen(computer) }
                }
            } footer: {
                if !store.computers.isEmpty {
                    Text("Tap a computer for its conversations, other sessions, conversations you can link, and a shell.")
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { host in
                        NavigationLink {
                            SessionsListView(host: host)
                        } label: {
                            OtherComputerRow(name: host.displayName.isEmpty ? host.hostname : host.displayName)
                        }
                    }
                } header: {
                    Text("Other computers").textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        // Again whenever a conversation changed after its computer was listed.
        .task(id: model.relistRequests) { await model.refreshLiveness(hosts: hosts) }
        .refreshable {
            // Background: a failure shows in the banner, not in the Todos list's alert.
            await store.refresh(trigger: .background)
            await model.refreshLiveness(hosts: hosts)
        }
        .sheet(item: $setUpPrefill) { prefill in
            // Create mode: the host and its key are saved together, and Cancel leaves nothing.
            HostEditorView(prefill: prefill)
        }
    }

    /// Saved hosts that match none of the hub's computers.
    static func otherHosts(_ hosts: [HostEntity], computers: [Computer]) -> [HostEntity] {
        hosts.filter { host in
            !computers.contains { HostLookup.host(for: $0, in: [host]) != nil }
        }
    }
}

/// Rounded tile with a computer symbol, leading every computer row.
struct ComputerIcon: View {
    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ComputerRow: View {
    let computer: Computer
    let sections: [TodoSection]
    let running: Int
    let needsYou: Int
    let hasAccess: Bool
    let onSetUp: () -> Void

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            ComputerIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text(computer.name)
                    .font(.body.weight(.semibold))
                if hasAccess {
                    Text(RowText.computerLine(running: running, needsYou: needsYou))
                        .foregroundStyle(needsYou > 0 ? DS.accent : Color.secondary)
                } else {
                    Text("This device can't open conversations here yet")
                        .foregroundStyle(.secondary)
                }
                if !sections.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(sections) { section in
                            Text(section.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Sections \(sections.map(\.rawValue).joined(separator: ", "))")
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !hasAccess {
                Button("Set Up", action: onSetUp)
                    .buttonStyle(AccentButtonStyle())
            } else {
                #if os(iOS)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                #endif
            }
        }
        .padding(.vertical, DS.spacing.xs)
        .frame(minHeight: DS.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}

private struct OtherComputerRow: View {
    let name: String

    var body: some View {
        HStack(spacing: DS.spacing.m) {
            ComputerIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold))
                Text("Sessions only").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: DS.rowMinHeight)
    }
}

#if DEBUG
#Preview("Computers") {
    NavigationStack {
        ComputerListView { _ in }
            .navigationTitle("Computers")
    }
    .environment(AppModel(demo: true))
    .modelContainer(for: HostEntity.self, inMemory: true)
}
#endif
