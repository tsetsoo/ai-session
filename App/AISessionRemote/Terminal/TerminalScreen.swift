import AISessionCore
import NIOCore
import SwiftTerm
import SwiftUI
import UIKit

/// Owns the `SwiftTerm.TerminalView` <-> `SSHTerminalSession` wiring: feeds remote bytes into the
/// view, forwards keystrokes/resizes back to the SSH PTY, and does a best-effort clipboard copy.
///
/// Deliberately a plain (non-actor) class: `TerminalViewDelegate` is a nonisolated protocol that
/// UIKit calls synchronously from the main thread, and `SSHTerminalSession`'s own callbacks always
/// arrive on its private NIO event loop thread — so every hop back to UI/state here goes through
/// an explicit `DispatchQueue.main.async` rather than relying on actor isolation.
final class TerminalCoordinator: TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var onError: ((String) -> Void)?
    var onDisconnected: (() -> Void)?

    private let hostConfig: HostConnectionConfig
    private let mode: TerminalMode
    private var session: SSHTerminalSession?

    init(hostConfig: HostConnectionConfig, mode: TerminalMode) {
        self.hostConfig = hostConfig
        self.mode = mode
    }

    func attach(to terminalView: TerminalView) {
        guard self.terminalView !== terminalView else { return }
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
    }

    /// Connects and execs the attach command. Safe to call once; subsequent calls (e.g. from a
    /// SwiftUI `.task` re-run) are a no-op while a session already exists.
    func connect() async {
        guard session == nil, let terminalView else { return }
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24

        let session = SSHTerminalSession(config: hostConfig, mode: mode)
        session.onOutput = { [weak self] outputBuffer in
            var outputBuffer = outputBuffer
            let bytes = outputBuffer.readBytes(length: outputBuffer.readableBytes) ?? []
            guard !bytes.isEmpty else { return }
            DispatchQueue.main.async {
                self?.terminalView?.feed(byteArray: bytes[...])
            }
        }
        session.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                self?.onDisconnected?()
            }
        }
        self.session = session

        do {
            try await session.connect(cols: cols, rows: rows)
            let liveTerminal = terminalView.getTerminal()
            if liveTerminal.cols > 0, liveTerminal.rows > 0 {
                session.resize(cols: liveTerminal.cols, rows: liveTerminal.rows)
            }
        } catch {
            self.session = nil
            let message = Self.message(for: error)
            DispatchQueue.main.async { [weak self] in
                self?.onError?(message)
            }
        }
    }

    /// Closes the SSH connection only. `tmux` keeps the session running on the remote host.
    func disconnect() {
        session?.disconnect()
        session = nil
    }

    func send(_ bytes: [UInt8]) {
        session?.send(bytes[...])
    }

    /// Best-effort clipboard copy: copies the active selection if there is one, otherwise
    /// briefly selects the whole visible buffer to grab its text.
    func copySelection() {
        guard let terminalView else { return }
        let text: String?
        if terminalView.selectionActive {
            text = terminalView.getSelection()
        } else {
            terminalView.selectAll()
            text = terminalView.getSelection()
            terminalView.selectNone()
        }
        if let text, !text.isEmpty {
            UIPasteboard.general.string = text
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(cols: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session?.send(data)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private static func message(for error: Error) -> String {
        if let error = error as? SSHRemoteError {
            return error.userMessage
        }
        switch error {
        case SSHTerminalSessionError.invalidPrivateKey:
            return "The SSH key for this host could not be parsed."
        case SSHTerminalSessionError.connectionFailed:
            return "Could not reach the host. Check the network and try again."
        case SSHTerminalSessionError.channelSetupFailed:
            return "The SSH server rejected the terminal session."
        default:
            return "Connection failed: \(error.localizedDescription)"
        }
    }
}

private struct TerminalContainerView: UIViewRepresentable {
    let coordinator: TerminalCoordinator

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.backgroundColor = .black
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        coordinator.attach(to: uiView)
    }
}

/// Interactive terminal for a single tmux session: SwiftTerm renders the VT100 output, an SSH PTY
/// (exec'd `tmux attach -t '<name>'`) drives it, and a `SoftKeyBar` covers keys hard to reach on a
/// touch keyboard. Detaching (back/dismiss) only closes the SSH connection — tmux keeps running.
struct TerminalScreen: View {
    let hostConfig: HostConnectionConfig
    let mode: TerminalMode
    let title: String
    let onKill: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: TerminalCoordinator
    @State private var errorMessage: String?
    @State private var killErrorMessage: String?
    @State private var showingKillConfirmation = false

    init(
        hostConfig: HostConnectionConfig,
        mode: TerminalMode,
        title: String,
        onKill: @escaping () async throws -> Void
    ) {
        self.hostConfig = hostConfig
        self.mode = mode
        self.title = title
        self.onKill = onKill
        _coordinator = State(initialValue: TerminalCoordinator(hostConfig: hostConfig, mode: mode))
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(coordinator: coordinator)
                .background(Color.black)
            SoftKeyBar { key in
                coordinator.send(key.bytes)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        coordinator.copySelection()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if case .attach = mode {
                        Button {
                            showingKillConfirmation = true
                        } label: {
                            Label("Kill Session", systemImage: "xmark.circle")
                        }
                    }
                    Button {
                        dismiss()
                    } label: {
                        Label("Detach", systemImage: "arrow.uturn.left")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Kill this session? This ends the tmux session on the remote host.",
            isPresented: $showingKillConfirmation,
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                Task {
                    do {
                        try await onKill()
                        dismiss()
                    } catch {
                        killErrorMessage = Self.killMessage(for: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Could Not Kill Session",
            isPresented: Binding(
                get: { killErrorMessage != nil },
                set: { if !$0 { killErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(killErrorMessage ?? "")
        }
        .alert(
            "Connection Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            coordinator.onError = { message in errorMessage = message }
            coordinator.onDisconnected = {
                if errorMessage == nil {
                    errorMessage = "The connection was closed."
                }
            }
        }
        .task {
            await coordinator.connect()
        }
        .onDisappear {
            coordinator.disconnect()
        }
    }

    private static func killMessage(for error: Error) -> String {
        if let sshError = error as? SSHRemoteError {
            return sshError.userMessage
        }
        return "Could not kill the session: \(error.localizedDescription)"
    }
}
