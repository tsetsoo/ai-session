import AISessionCore
import SwiftUI

/// Enter and test the todo server URL and API token.
struct TodoHubSettingsView: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = TodoHubSettings.baseURLString
    @State private var token = TodoHubSettings.token
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @AppStorage(NotificationCenterCoordinator.enabledKey) private var notifyNeedsYou = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.118.255.23:8080", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API token (optional)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Todo server")
                } footer: {
                    Text("The token is stored in the Keychain. Leave it empty if the server runs without TODO_API_TOKEN.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(parsedURL == nil || isTesting)
                    if let testResult {
                        Label(testResult, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                }

                // Until the redesigned Settings → Notifications screen lands (UI session), the
                // toggle lives here.
                Section {
                    Toggle("Notify me when a conversation needs me", isOn: Binding(
                        get: { notifyNeedsYou },
                        set: { on in
                            Task { notifyNeedsYou = await NotificationCenterCoordinator.shared.setNeedsYouEnabled(on) }
                        }
                    ))
                } header: {
                    Text("Notifications")
                }
                if notifyNeedsYou {
                    NotificationSettingsView()
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                    .disabled(parsedURL == nil)
                }
            }
        }
    }

    private var parsedURL: URL? { TodoHubClient.baseURL(from: urlText) }

    /// Stays open when the Keychain refuses the token, so the failure is visible here
    /// rather than as "token rejected" on every later request.
    private func save() {
        do {
            try TodoHubSettings.setToken(token)
        } catch {
            testSucceeded = false
            testResult = "Couldn't save the token to the Keychain: \(error.localizedDescription)"
            return
        }
        TodoHubSettings.baseURLString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave()
        dismiss()
    }

    /// Health first (proves the server is reachable), then an authenticated call (proves the token).
    private func test() async {
        guard let url = parsedURL else { return }
        #if DEBUG
        if DemoFixtures.isEnabled {
            testSucceeded = false
            testResult = "Not available in the demo."
            return
        }
        #endif
        isTesting = true
        defer { isTesting = false }
        let client = TodoHubClient(baseURL: url, token: token)
        do {
            try await client.health()
            _ = try await client.listSectionComputers()
            testSucceeded = true
            testResult = "Connected"
        } catch {
            testSucceeded = false
            testResult = TodoHubStore.message(for: error)
        }
    }
}
