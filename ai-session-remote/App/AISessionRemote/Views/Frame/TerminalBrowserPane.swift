#if os(macOS)
import AISessionCore
import SwiftUI

struct TerminalBrowserPane: View {
    let destination: TerminalBrowserDestination
    let isOnScreen: Bool
    let onClose: () -> Void

    @State private var address = ""
    @State private var previewOnMac = false
    @State private var launch: Launch?
    @State private var message: String?
    @State private var preparation: Task<Void, Never>?

    private struct Launch: Identifiable {
        let id = UUID()
        let command: String
    }

    private static let localConfig = HostConnectionConfig(
        host: "localhost", port: 22, username: NSUserName(), privateKeyPEM: Data()
    )

    private var hostIsLocal: Bool {
        ThisMac.matches(hostname: destination.hostname, username: destination.username)
    }
    private var isLocal: Bool { hostIsLocal || previewOnMac }
    private var sshTarget: String? {
        // Upstream accepts a single user@host[:port] target, or a string of SSH options.
        // Restrict saved host fields to a single target so they cannot add SSH options.
        let name = /^[A-Za-z0-9_.][A-Za-z0-9_.-]*$/
        guard destination.username.wholeMatch(of: name) != nil,
              destination.hostname.wholeMatch(of: name) != nil,
              (1...65535).contains(destination.port) else { return nil }
        let target = "\(destination.username)@\(destination.hostname)"
        return destination.port == 22 ? target : "\(target):\(destination.port)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Terminal Browser", systemImage: "globe")
                Spacer()
                Button("Close Browser", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(8)

            if !hostIsLocal {
                Picker("Preview Network", selection: $previewOnMac) {
                    Text(destination.computerName).tag(false)
                    Text("This Mac").tag(true)
                }
                .labelsHidden()
                .padding([.horizontal, .bottom], 8)
                .onChange(of: previewOnMac) {
                    preparation?.cancel()
                    preparation = nil
                    launch = nil
                    message = nil
                }
            }

            HStack {
                TextField("http://localhost:3000", text: $address)
                    .accessibilityLabel("Browser URL")
                    .onSubmit(open)
                Button("Open", action: open)
                    .disabled(preparation != nil)
            }
            .padding([.horizontal, .bottom], 8)

            if preparation != nil {
                ProgressView("Preparing Terminal Browser…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 8)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 8)
            }

            Divider()
            if let launch {
                TerminalSurface(
                    config: Self.localConfig,
                    mode: .attach(launch.command),
                    hostName: "Terminal Browser",
                    onEnded: { status in
                        guard let status, status != 0 else { return }
                        message = isLocal
                            ? "Terminal Browser exited with status \(status)."
                            : "Terminal Browser exited with status \(status). Check your Mac’s OpenSSH credentials and configuration for \(destination.computerName)."
                    },
                    selectsTextOnDrag: false,
                    isOnScreen: isOnScreen
                )
                .id(launch.id)
            } else {
                Spacer()
            }
        }
        .onDisappear {
            preparation?.cancel()
            preparation = nil
        }
    }

    private func open() {
        guard preparation == nil else { return }
        let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entered.contains("://") ? entered : "http://\(entered)"
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let urlHost = url.host, !urlHost.isEmpty else {
            message = "Enter an HTTP or HTTPS URL."
            return
        }

        var options = ["open"]
        if !isLocal {
            guard let sshTarget else {
                message = "Terminal Browser requires a hostname or IPv4 address for SSH."
                return
            }
            options += ["--ssh", sshTarget]
        }
        options.append(url.absoluteString)
        message = nil
        preparation = Task {
            do {
                let browser = try await BundledTerminalBrowser.shared.prepare()
                guard !Task.isCancelled else { return }
                let arguments = ["/usr/bin/env"] + browser.environment + [browser.executable.path] + options
                // LocalConnection runs attach commands in a shell. Keep each CLI argument literal.
                let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
                    .joined(separator: " ")
                launch = Launch(command: "exec \(command)")
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            preparation = nil
        }
    }
}
#endif
