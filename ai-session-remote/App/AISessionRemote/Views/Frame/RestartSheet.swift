import AISessionCore
import SwiftUI

/// "Restart…": start this conversation again, the same one in the same folder, on the
/// installed CLI version, optionally with other MCP servers (Claude, Codex) or Claude in
/// Chrome. The computer refuses while it works or waits for an answer; the frame asks then.
struct RestartSheet: View {
    let conversation: Conversation
    let store: TodoHubStore
    let hosts: [HostEntity]
    let onConfirm: (_ servers: [String]?, _ chrome: ChromeChoice) -> Void
    let onCancel: () -> Void

    @State private var servers: [String]?
    @State private var list = MCPServerListState.loading
    @State private var chrome = ChromeChoice.keep
    @State private var savedChrome: ChromeChoice?
    @State private var settingsUnavailable = false

    init(conversation: Conversation, store: TodoHubStore, hosts: [HostEntity],
         onConfirm: @escaping ([String]?, ChromeChoice) -> Void, onCancel: @escaping () -> Void) {
        self.conversation = conversation
        self.store = store
        self.hosts = hosts
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _servers = State(initialValue: conversation.mcpServers)
    }

    private var tool: String { RowText.toolName(conversation.tool) }
    private var managesServers: Bool { conversation.tool != "cursor" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(tool) starts again on the version installed on \(conversation.computer.name), in the same conversation and folder. Its model and permission mode stay as they are.")
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text("Text you typed but didn't send is lost. Files and uncommitted changes in the folder aren't touched.")
                }
                if conversation.tool == "claude" {
                    chromeSection
                }
                if managesServers {
                    serversSection
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Restart \(tool)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restart") { onConfirm(managesServers ? servers : conversation.mcpServers, chromeToSend) }
                        .disabled(managesServers && list == .loading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task {
            let config = { try HostLookup.config(for: conversation.computer, in: hosts) }
            if managesServers {
                list = await MCPServerListState.load(on: conversation.computer, store: store, config: config)
            }
            if conversation.tool == "claude" {
                if let settings = try? await RemoteRestart.settings(conversation, config: config()) {
                    savedChrome = ChromeChoice(saved: settings.chrome)
                    chrome = savedChrome ?? .keep
                } else {
                    settingsUnavailable = true
                }
            }
        }
    }

    /// Unchanged when it is what the conversation already has.
    private var chromeToSend: ChromeChoice {
        chrome == savedChrome ? .keep : chrome
    }

    @ViewBuilder
    private var chromeSection: some View {
        Section {
            Picker("Claude in Chrome", selection: $chrome) {
                if savedChrome == nil {
                    Text(ChromeChoice.keep.title).tag(ChromeChoice.keep)
                }
                ForEach([ChromeChoice.default, .on, .off], id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .disabled(settingsUnavailable)
        } footer: {
            Text(settingsUnavailable
                 ? "Update the todo scripts on \(conversation.computer.name) to choose this."
                 : "Lets Claude use your Chrome browser. Kept for this conversation's later starts too.")
        }
    }

    @ViewBuilder
    private var serversSection: some View {
        switch list {
        case .loading:
            Section("MCP Servers") {
                HStack(spacing: DS.spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading servers…").foregroundStyle(.secondary)
                }
            }
        case let .loaded(available):
            MCPServerChecklist(servers: available, selection: $servers,
                               allowsUnmanaged: conversation.mcpServers == nil)
        case .unavailable:
            Section("MCP Servers") {
                Text("No servers on \(conversation.computer.name)").foregroundStyle(.secondary)
            }
        case .failed:
            Section("MCP Servers") {
                LabeledContent("Unchanged", value: MCPServerListState.summary(conversation.mcpServers))
            }
        }
    }
}
