import AISessionCore
import SwiftUI

/// Push notification settings stored on the todo server (shared by every device), plus the
/// Mac-only "alert here too" switch. `Form` sections, meant to sit under the "Notify me when
/// a conversation needs me" toggle in Settings → Notifications.
struct NotificationSettingsView: View {
    /// Todo id → title, to name muted todos; ids are shown when missing.
    var todoTitles: [String: String] = [:]

    @State private var settings: PushSettings?
    @State private var serverStatus: PushServerStatus?
    @State private var loadError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var testResults: String?
    @State private var isTesting = false
    @AppStorage(NotificationCenterCoordinator.macAlertsTooKey) private var macAlertsToo = false
    private let coordinator = NotificationCenterCoordinator.shared

    var body: some View {
        Group {
            Section {
                Label(stateText, systemImage: stateIcon)
                if let serverStatus, !serverStatus.configured {
                    Text("The todo server has no APNs key yet, so it can't send pushes.")
                        .foregroundStyle(.secondary)
                } else if let lastError = serverStatus?.lastError {
                    Text("Last push error: \(lastError)").foregroundStyle(.secondary)
                }
                #if os(iOS)
                Button {
                    Task { await sendTest() }
                } label: {
                    HStack {
                        Text("Send Test Notification")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting || coordinator.pushState != .registered)
                if let testResults {
                    Text(testResults).foregroundStyle(.secondary)
                }
                #else
                Toggle("Alert on this Mac too", isOn: $macAlertsToo)
                #endif
            } footer: {
                #if os(macOS)
                Text("While an iPhone gets push notifications, this Mac stays quiet unless this is on.")
                #endif
            }

            if let loadError {
                Section { Text(loadError).foregroundStyle(.red) }
            }

            if let binding = Binding($settings) {
                Section {
                    Toggle("When a long run finishes", isOn: doneEnabled(binding))
                    if let minutes = binding.wrappedValue.doneAfterMinutes {
                        Stepper("After at least \(minutes) min", value: doneMinutes(binding), in: 1...600)
                    }
                } footer: {
                    Text("Besides \"needs you\", notify when Claude finishes a turn that ran this long.")
                }

                Section {
                    Toggle("Quiet hours", isOn: quietEnabled(binding))
                    if binding.wrappedValue.quietHours != nil {
                        DatePicker("From", selection: quietTime(binding, \.start), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: quietTime(binding, \.end), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Notifications in quiet hours arrive silently and wait in Notification Center.")
                }

                Section("Muted sections") {
                    ForEach(TodoSection.allCases) { section in
                        Toggle(section.rawValue, isOn: sectionMuted(binding, section))
                    }
                }

                if !binding.wrappedValue.mutedTodoIds.isEmpty {
                    Section("Muted todos") {
                        ForEach(binding.wrappedValue.mutedTodoIds, id: \.self) { todoId in
                            HStack {
                                Text(todoTitles[todoId] ?? todoId).lineLimit(1)
                                Spacer()
                                Button("Unmute") { Task { await unmute(todoId) } }
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private var stateText: String {
        switch coordinator.pushState {
        case .off: "Notifications are off"
        case let .localOnly(reason): reason
        case .registered: "Push notifications are on for this device"
        }
    }

    private var stateIcon: String {
        coordinator.pushState == .registered ? "checkmark.circle.fill" : "bell"
    }

    // MARK: Bindings

    private func doneEnabled(_ s: Binding<PushSettings>) -> Binding<Bool> {
        Binding(
            get: { s.wrappedValue.doneAfterMinutes != nil },
            set: { on in update(s) { $0.doneAfterMinutes = on ? 5 : nil } }
        )
    }

    private func doneMinutes(_ s: Binding<PushSettings>) -> Binding<Int> {
        Binding(
            get: { s.wrappedValue.doneAfterMinutes ?? 5 },
            set: { minutes in update(s) { $0.doneAfterMinutes = minutes } }
        )
    }

    private func quietEnabled(_ s: Binding<PushSettings>) -> Binding<Bool> {
        Binding(
            get: { s.wrappedValue.quietHours != nil },
            set: { on in
                update(s) {
                    $0.quietHours = on ? QuietHours(start: "22:30", end: "07:30", tz: TimeZone.current.identifier) : nil
                }
            }
        )
    }

    private func quietTime(_ s: Binding<PushSettings>, _ field: WritableKeyPath<QuietHours, String>) -> Binding<Date> {
        Binding(
            get: { s.wrappedValue.quietHours.flatMap { QuietHours.date(fromHHMM: $0[keyPath: field]) } ?? Date() },
            set: { date in
                update(s) {
                    $0.quietHours?[keyPath: field] = QuietHours.hhmm(from: date)
                    // The phone's timezone, so the window follows the user when they travel.
                    $0.quietHours?.tz = TimeZone.current.identifier
                }
            }
        )
    }

    private func sectionMuted(_ s: Binding<PushSettings>, _ section: TodoSection) -> Binding<Bool> {
        Binding(
            get: { s.wrappedValue.mutedSections.contains(section) },
            set: { muted in
                update(s) { settings in
                    settings.mutedSections.removeAll { $0 == section }
                    if muted { settings.mutedSections.append(section) }
                }
            }
        )
    }

    /// Apply locally, then save after 0.5 s without further changes.
    private func update(_ s: Binding<PushSettings>, _ change: (inout PushSettings) -> Void) {
        change(&s.wrappedValue)
        let snapshot = s.wrappedValue
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let client = TodoHubSettings.makeClient() else { return }
            do {
                settings = try await client.savePushSettings(snapshot)
                loadError = nil
            } catch {
                loadError = (error as? TodoHubError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    // MARK: Server calls

    private func load() async {
        guard let client = TodoHubSettings.makeClient() else {
            loadError = "Set up the todo server first."
            return
        }
        do {
            settings = try await client.pushSettings()
            serverStatus = try? await client.pushStatus()
            loadError = nil
        } catch TodoHubError.notFound {
            loadError = "The todo server has no push support yet."
        } catch {
            loadError = (error as? TodoHubError)?.userMessage ?? error.localizedDescription
        }
    }

    private func unmute(_ todoId: String) async {
        do {
            try await coordinator.setMuted(todoId: todoId, false)
            settings?.mutedTodoIds.removeAll { $0 == todoId }
        } catch {
            loadError = (error as? TodoHubError)?.userMessage ?? error.localizedDescription
        }
    }

    private func sendTest() async {
        guard let client = TodoHubSettings.makeClient() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let results = try await client.sendTestPush()
            testResults = results.isEmpty
                ? "No registered devices."
                : results.map { "\($0.tokenPrefix)…: \($0.ok ? "sent" : $0.reason ?? "failed")" }.joined(separator: "\n")
        } catch {
            testResults = (error as? TodoHubError)?.userMessage ?? error.localizedDescription
        }
    }
}

#Preview {
    Form {
        NotificationSettingsView()
    }
}
