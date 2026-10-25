import AISessionCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Connection fields to start a new host from (e.g. a todo-server computer). Nothing is
/// saved until the user adds a key and taps Save.
struct HostEditorPrefill: Identifiable {
    var displayName: String
    var hostname: String
    var port: Int
    var username: String

    var id: String { "\(username)@\(hostname):\(port)" }
}

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
    /// The key already in the Keychain for `host`. Never shown: saving without Replace Key
    /// writes it back unchanged.
    @State private var storedPEM: String?
    @State private var replacingKey = false
    @State private var alert: EditorAlert?
    @State private var isLoadingKey = false
    @State private var showingForgetHostKeyConfirmation = false
    @State private var forgetHostKeyMessage: String?
    @State private var showAdvanced = false
    @State private var showingKeyImporter = false

    /// Edits `host`, or creates a new one (optionally starting from `prefill`) when `host` is nil.
    init(host: HostEntity? = nil, prefill: HostEditorPrefill? = nil) {
        self.host = host
        _displayName = State(initialValue: host?.displayName ?? prefill?.displayName ?? "")
        _hostname = State(initialValue: host?.hostname ?? prefill?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? prefill?.port ?? 22))
        _username = State(initialValue: host?.username ?? prefill?.username ?? "")
        _pem = State(initialValue: "")
        _defaultPaths = State(initialValue: host?.defaultPaths.joined(separator: "\n") ?? "")
        _cliBinaries = State(initialValue: host?.cliBinaries ?? [:])
        let hasAdvanced = !(host?.defaultPaths.isEmpty ?? true) || !(host?.cliBinaries.isEmpty ?? true)
        _showAdvanced = State(initialValue: hasAdvanced)
    }

    private struct EditorAlert {
        var title: String
        var message: String
    }

    /// A key is stored and the user hasn't asked to replace it.
    private var keepsStoredKey: Bool {
        storedPEM != nil && !replacingKey
    }

    /// What Save writes to the Keychain: the stored key, or the one entered here.
    private var keyToSave: String {
        keepsStoredKey ? storedPEM ?? "" : pem
    }

    private var canSave: Bool {
        !isLoadingKey
            && !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !keyToSave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField("Display name", text: $displayName)
                    FormTextField("Hostname / Tailscale IP", text: $hostname)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    FormTextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    FormTextField("Username", text: $username)
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
                    } else if keepsStoredKey {
                        Label("Key saved", systemImage: "checkmark.seal.fill")
                        Button("Replace Key…") {
                            pem = ""
                            replacingKey = true
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
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            if let clip = PlatformSupport.pasteboardString, !clip.isEmpty {
                                pem = clip
                            }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            showingKeyImporter = true
                        } label: {
                            Label("Choose Key File…", systemImage: "key")
                        }

                        #if os(macOS)
                        let sshKeys = PlatformSupport.sshKeyCandidates()
                        if !sshKeys.isEmpty {
                            Menu {
                                ForEach(sshKeys, id: \.self) { url in
                                    Button(url.lastPathComponent) { loadKey(from: url) }
                                }
                            } label: {
                                Label("Use Key from ~/.ssh", systemImage: "folder")
                            }
                        }
                        #endif

                        if storedPEM != nil {
                            Button("Keep Saved Key") {
                                pem = ""
                                replacingKey = false
                            }
                        }
                    }
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Stored in the Keychain on this device.")
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
                            FormTextField(
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
                guard let host, storedPEM == nil else { return }
                isLoadingKey = true
                defer { isLoadingKey = false }
                do {
                    storedPEM = try HostRepository(modelContext: modelContext).privateKey(for: host)
                } catch {
                    alert = EditorAlert(
                        title: "Could not load the saved key",
                        message: "This device couldn't read the key saved for this host. Paste or choose the key again, then save."
                    )
                }
            }
            .fileImporter(
                isPresented: $showingKeyImporter,
                allowedContentTypes: [.data, .text, .item]
            ) { result in
                switch result {
                case .success(let url): loadKey(from: url)
                case .failure(let error):
                    alert = EditorAlert(title: "Could not open the key file", message: error.localizedDescription)
                }
            }
            .alert(alert?.title ?? "", isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alert?.message ?? "")
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

    /// Reads a private key file into the editor. Files picked through the importer are
    /// security-scoped on iOS, so access is requested for the duration of the read.
    private func loadKey(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("PRIVATE KEY") else {
                alert = EditorAlert(
                    title: "Not a private key",
                    message: "\(url.lastPathComponent) does not look like a private key. Choose the file that starts with BEGIN … PRIVATE KEY."
                )
                return
            }
            pem = text
        } catch {
            alert = EditorAlert(
                title: "Could not read the key file",
                message: "\(url.lastPathComponent) couldn't be read. Check it's a text key file, or paste the key instead."
            )
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
                    pem: keyToSave,
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
            alert = EditorAlert(title: "Could not save host", message: error.localizedDescription)
        }
    }
}

#Preview {
    HostEditorView()
        .modelContainer(for: HostEntity.self, inMemory: true)
}
