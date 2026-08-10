import AISessionCore
import SwiftData
import SwiftUI

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

    init(host: HostEntity? = nil) {
        self.host = host
        _displayName = State(initialValue: host?.displayName ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _pem = State(initialValue: "")
        _defaultPaths = State(initialValue: host?.defaultPaths.joined(separator: "\n") ?? "")
        _cliBinaries = State(initialValue: host?.cliBinaries ?? [:])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display name", text: $displayName)
                    TextField("Hostname", text: $hostname)
                        .textContentType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                }

                Section("Private key") {
                    TextEditor(text: $pem)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .overlay(alignment: .topLeading) {
                            if pem.isEmpty {
                                Text("Paste PEM private key")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("Default paths") {
                    TextEditor(text: $defaultPaths)
                        .frame(minHeight: 100)
                    Text("One path per line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("CLI binary overrides") {
                    ForEach(AITool.allCases, id: \.self) { tool in
                        TextField(
                            "\(tool.rawValue.capitalized) (optional)",
                            text: binding(for: tool)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                        .disabled(isLoadingKey)
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
        }
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
