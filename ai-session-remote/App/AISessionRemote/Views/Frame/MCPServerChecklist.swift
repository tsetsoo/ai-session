import AISessionCore
import SwiftUI

/// The MCP servers on a computer as ticked rows. A selection of nil is "Tool's own servers"
/// (not managed); `[]` is managed with none. A server whose file has an error is shown, off,
/// with its reason.
struct MCPServerChecklist: View {
    let servers: [MCPServer]
    @Binding var selection: [String]?
    /// Offers the top row that means nil.
    let allowsUnmanaged: Bool
    var unmanagedTitle = MCPServerListState.toolOwnTitle
    var unmanagedDetail = "What the tool's own settings turn on"

    var body: some View {
        if allowsUnmanaged {
            Section {
                row(title: unmanagedTitle, detail: unmanagedDetail, isOn: selection == nil) {
                    selection = nil
                }
            }
        }
        Section {
            ForEach(servers) { server in
                row(
                    title: server.name,
                    detail: server.error ?? server.summary,
                    isOn: server.error == nil && selection?.contains(server.name) == true
                ) {
                    toggle(server.name)
                }
                .disabled(server.error != nil)
            }
        }
    }

    private func row(title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .foregroundStyle(DS.accent)
                    .opacity(isOn ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Ticking from "Tool's own servers" starts a managed selection with just that server.
    private func toggle(_ name: String) {
        var names = selection ?? []
        if let index = names.firstIndex(of: name) {
            names.remove(at: index)
        } else {
            names.append(name)
        }
        selection = names
    }
}

/// Where reading a computer's server list got to.
enum MCPServerListState: Equatable {
    case loading
    case loaded([MCPServer])
    /// No list on that computer (older scripts, or no server files): no checklist at all.
    case unavailable
    case failed

    @MainActor
    static func load(
        on computer: Computer, store: TodoHubStore, config: () throws -> HostConnectionConfig
    ) async -> MCPServerListState {
        do {
            let servers = try await store.mcpServers(on: computer, config: config())
            return servers.isEmpty ? .unavailable : .loaded(servers)
        } catch {
            return .failed
        }
    }

    /// A computer with no list at all (no helper) can't manage servers, so the selection becomes
    /// nil. An empty server folder keeps it: a `[]` default still means "none".
    static func clearsSelection(_ state: MCPServerListState, hasList: Bool?) -> Bool {
        state == .unavailable && hasList == false
    }

    static let toolOwnTitle = "Tool's own servers"

    /// The ticked names in a line, for a row that opens the checklist. `unmanaged` is what nil reads as.
    static func summary(_ selection: [String]?, unmanaged: String = toolOwnTitle) -> String {
        guard let selection else { return unmanaged }
        return selection.isEmpty ? "None" : selection.joined(separator: ", ")
    }

    static func failureMessage(_ computer: Computer) -> String {
        "Can't read the servers on \(computer.name)."
    }
}

/// The checklist in a sheet: Cancel keeps the selection, `confirmTitle` hands back the new one.
/// Reads the list itself unless the caller already has it.
struct MCPServersSheet: View {
    let computer: Computer
    let store: TodoHubStore
    let hosts: [HostEntity]
    let allowsUnmanaged: Bool
    let unmanagedTitle: String
    let unmanagedDetail: String
    let confirmTitle: String
    let onConfirm: ([String]?) -> Void
    let onCancel: () -> Void

    /// What was saved, shown as plain text when the list can't be read.
    private let stored: [String]?
    @State private var draft: [String]?
    @State private var state: MCPServerListState

    init(
        computer: Computer, store: TodoHubStore, hosts: [HostEntity], selection: [String]?,
        allowsUnmanaged: Bool, unmanagedTitle: String = MCPServerListState.toolOwnTitle,
        unmanagedDetail: String = "What the tool's own settings turn on",
        list: MCPServerListState = .loading, confirmTitle: String,
        onConfirm: @escaping ([String]?) -> Void, onCancel: @escaping () -> Void
    ) {
        self.computer = computer
        self.store = store
        self.hosts = hosts
        self.allowsUnmanaged = allowsUnmanaged
        self.unmanagedTitle = unmanagedTitle
        self.unmanagedDetail = unmanagedDetail
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.stored = selection
        _draft = State(initialValue: selection)
        _state = State(initialValue: list)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Servers")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle) { onConfirm(draft) }
                            .disabled(!isLoaded)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
        .task {
            guard state == .loading else { return }
            state = await MCPServerListState.load(on: computer, store: store) {
                try HostLookup.config(for: computer, in: hosts)
            }
        }
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            FrameStateBlock(showsProgress: true, title: "Reading servers on \(computer.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(servers):
            Form {
                MCPServerChecklist(
                    servers: servers, selection: $draft, allowsUnmanaged: allowsUnmanaged,
                    unmanagedTitle: unmanagedTitle, unmanagedDetail: unmanagedDetail
                )
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
        case .unavailable:
            FrameStateBlock(title: "No servers on \(computer.name)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            Form {
                Section {
                    LabeledContent("Saved", value: MCPServerListState.summary(stored, unmanaged: unmanagedTitle))
                } footer: {
                    Text(MCPServerListState.failureMessage(computer))
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
        }
    }
}

/// The start state's "Servers" row: reads the computer's list, then opens the checklist.
/// Hidden when the computer has no list, and the selection is then nil (no `--mcp`, as before).
struct MCPServersStartRow: View {
    let computer: Computer
    let store: TodoHubStore
    let hosts: [HostEntity]
    @Binding var selection: [String]?
    let allowsUnmanaged: Bool

    @State private var state = MCPServerListState.loading
    @State private var showingChecklist = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                HStack(spacing: DS.spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading servers…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .loaded:
                Button { showingChecklist = true } label: {
                    HStack(spacing: DS.spacing.s) {
                        Text("Servers")
                            .foregroundStyle(.primary)
                        Spacer(minLength: DS.spacing.m)
                        Text(MCPServerListState.summary(selection))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, DS.spacing.m)
                    .padding(.vertical, DS.spacing.s)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 360)
                .accessibilityLabel("Servers, \(MCPServerListState.summary(selection))")
            case .unavailable:
                EmptyView()
            case .failed:
                Text(MCPServerListState.failureMessage(computer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .task(id: computer.id) {
            state = .loading
            state = await MCPServerListState.load(on: computer, store: store) {
                try HostLookup.config(for: computer, in: hosts)
            }
            if MCPServerListState.clearsSelection(state, hasList: store.hasMCPList(computer)) { selection = nil }
        }
        .sheet(isPresented: $showingChecklist) {
            if case let .loaded(servers) = state {
                MCPServersSheet(
                    computer: computer, store: store, hosts: hosts, selection: selection,
                    allowsUnmanaged: allowsUnmanaged, list: .loaded(servers), confirmTitle: "Done",
                    onConfirm: { selection = $0; showingChecklist = false },
                    onCancel: { showingChecklist = false }
                )
            }
        }
    }
}
