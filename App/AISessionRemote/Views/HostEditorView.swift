import AISessionCore
import SwiftData
import SwiftUI
import UIKit

struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let host: HostEntity?
    @State private var displayName: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var pem: String
    @State private var defaultPaths: String
    @State private var cliBinaries: [AITool: String]
    @State private var errorMessage: String?
    @State private var isLoadingKey = false
    @State private var showingForgetHostKeyConfirmation = false
    @State private var forgetHostKeyMessage: String?
    @State private var showAdvanced = false

    init(host: HostEntity? = nil) {
        self.host = host
        _displayName = State(initialValue: host?.displayName ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _pem = State(initialValue: "")
        _defaultPaths = State(initialValue: host?.defaultPaths.joined(separator: "\n") ?? "")
        _cliBinaries = State(initialValue: host?.cliBinaries ?? [:])
        let hasAdvanced = !(host?.defaultPaths.isEmpty ?? true) || !(host?.cliBinaries.isEmpty ?? true)
        _showAdvanced = State(initialValue: hasAdvanced)
    }

    private var canSave: Bool {
        !isLoadingKey
            && !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $displayName)
                    TextField("Hostname / Tailscale IP", text: $hostname)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Use a Tailscale IP or MagicDNS name. Password auth is not supported — paste a private key below.")
                }

                Section {
                    if isLoadingKey {
                        HStack {
                            ProgressView()
                            Text("Loading key from Keychain…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        TextEditor(text: $pem)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                            .overlay(alignment: .topLeading) {
                                if pem.isEmpty {
                                    Text("Paste PEM private key (BEGIN … PRIVATE KEY)")
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }

                        if !pem.isEmpty {
                            Label("Key ready (\(pemLineCount) lines)", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Button {
                            if let clip = UIPasteboard.general.string, !clip.isEmpty {
                                pem = clip
                            }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                    }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Stored in the iOS Keychain. Never leave this field empty when saving.")
                }

                Section {
                    Toggle("Show advanced options", isOn: $showAdvanced.animation())
                    if showAdvanced {
                        TextEditor(text: $defaultPaths)
                            .font(.body.monospaced())
                            .frame(minHeight: 80)
                        Text("One working-directory bookmark per line. Shown as quick picks when starting a session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(AITool.allCases, id: \.self) { tool in
                            TextField(
                                "\(AppTheme.displayName(for: tool)) binary (optional)",
                                text: binding(for: tool)
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        }
                    }
                } header: {
                    Text("Advanced")
                }

                if host != nil {
                    Section {
                        Button("Forget Host Key", role: .destructive) {
                            showingForgetHostKeyConfirmation = true
                        }
                    } footer: {
                        Text("Clears the trusted SSH host key for this host. Use this after reinstalling the host or rotating its key — the next connection will trust whatever key it presents.")
                    }
                }
            }
            .navigationTitle(host == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .task {
                guard let host, pem.isEmpty else { return }
                isLoadingKey = true
                defer { isLoadingKey = false }
                do {
                    pem = try HostRepository(modelContext: modelContext).privateKey(for: host)
                } catch {
                    errorMessage = "Could not load the private key: \(error.localizedDescription)"
                }
            }
            .alert("Could not save host", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "Forget the trusted SSH host key for this host? The next connection will trust whatever key the host presents.",
                isPresented: $showingForgetHostKeyConfirmation,
                titleVisibility: .visible
            ) {
                Button("Forget Host Key", role: .destructive) { forgetHostKey() }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Host Key Forgotten",
                isPresented: Binding(
                    get: { forgetHostKeyMessage != nil },
                    set: { if !$0 { forgetHostKeyMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(forgetHostKeyMessage ?? "")
            }
        }
    }

    private var pemLineCount: Int {
        pem.split(whereSeparator: \.isNewline).count
    }

    private func forgetHostKey() {
        guard let host else { return }
        HostRepository(modelContext: modelContext).forgetHostKey(for: host)
        forgetHostKeyMessage = "The trusted host key for this host has been cleared."
    }

    private func binding(for tool: AITool) -> Binding<String> {
        Binding(
            get: { cliBinaries[tool] ?? "" },
            set: { cliBinaries[tool] = $0 }
        )
    }

    private func save() {
        do {
            guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw HostRepositoryError.invalidPort
            }
            let paths = defaultPaths
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let binaries = cliBinaries.filter {
                !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let repository = HostRepository(modelContext: modelContext)
            if let host {
                try repository.update(
                    host,
                    displayName: displayName,
                    hostname: hostname,
                    port: port,
                    username: username,
                    pem: pem,
                    defaultPaths: paths,
                    cliBinaries: binaries
                )
            } else {
                try repository.create(
                    displayName: displayName,
                    hostname: hostname,
                    port: port,
                    username: username,
                    pem: pem,
                    defaultPaths: paths,
                    cliBinaries: binaries
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    HostEditorView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
