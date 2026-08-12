import AISessionCore
import SwiftTerm
import SwiftUI
import UIKit

/// Owns the `SwiftTerm.TerminalView` <-> `TerminalTransport` wiring: feeds remote bytes into the
/// view, forwards keystrokes/resizes back to the SSH PTY, and does a best-effort clipboard copy.
///
/// Deliberately a plain (non-actor) class: `TerminalViewDelegate` is a nonisolated protocol that
/// UIKit calls synchronously from the main thread, and the transport's own callbacks are
/// documented to arrive off the main thread (see `TerminalTransport`) — so every hop back to
/// UI/state here goes through an explicit `DispatchQueue.main.async` rather than relying on
/// actor isolation.
enum TerminalConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case failed
}

final class TerminalCoordinator: TerminalViewDelegate {
    weak var terminalView: TerminalView?
    var onError: ((String) -> Void)?
    var onDisconnected: (() -> Void)?
    var onStateChange: ((TerminalConnectionState) -> Void)?

    private let hostConfig: HostConnectionConfig
    private let mode: TerminalMode
    private var session: (any TerminalTransport)?
    private(set) var state: TerminalConnectionState = .idle {
        didSet { onStateChange?(state) }
    }

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
        state = .connecting
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols > 0 ? terminal.cols : 80
        let rows = terminal.rows > 0 ? terminal.rows : 24

        let session = SSHTerminalSession(config: hostConfig, mode: mode)
        session.onOutput = { [weak self] bytes in
            DispatchQueue.main.async {
                self?.terminalView?.feed(byteArray: bytes[...])
            }
        }
        session.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                self?.state = .failed
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
            state = .connected
        } catch {
            self.session = nil
            state = .failed
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

    func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              let bytes = text.data(using: .utf8)?.map({ $0 }),
              !bytes.isEmpty
        else { return }
        send(bytes)
    }

    func reconnect() async {
        disconnect()
        await connect()
    }

    /// Makes the embedded `TerminalView` first responder so the soft keyboard and
    /// SwiftTerm's built-in `TerminalAccessory` (Ctrl/Esc/Tab/arrows) appear.
    func focusTerminal() {
        guard let terminalView else { return }
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
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
        // SwiftTerm's setup clears `nativeBackgroundColor` onto the layer then
        // sets the property to `.clear`. Re-paint both so unused glyph gaps and
        // safe-area bleed match the terminal chrome (no mismatched bars).
        view.nativeBackgroundColor = .black
        view.layer.backgroundColor = UIColor.black.cgColor
        view.backgroundColor = .black
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        coordinator.attach(to: uiView)
    }
}

/// Interactive terminal for a single tmux session. SwiftTerm owns the soft-key
/// accessory above the system keyboard (`TerminalAccessory`: Ctrl, Esc, Tab, arrows).
/// Detaching closes SSH only — tmux keeps running on the host.
struct TerminalScreen: View {
    let hostConfig: HostConnectionConfig
    let mode: TerminalMode
    let title: String
    let onKill: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: TerminalCoordinator
    @State private var connectionState: TerminalConnectionState = .idle
    @State private var errorMessage: String?
    @State private var killErrorMessage: String?
    @State private var showingKillConfirmation = false
    @State private var keyboardVisible = false
    @State private var isDisconnected = false

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
        ZStack {
            TerminalContainerView(coordinator: coordinator)
                .background(Color.black)
                .ignoresSafeArea(.container, edges: .bottom)

            if connectionState == .connecting || connectionState == .idle {
                connectingOverlay
            }
            if isDisconnected {
                disconnectedOverlay
            }
            if connectionState == .connected && !keyboardVisible {
                VStack {
                    Spacer()
                    SoftKeyBar { key in
                        switch key {
                        case .ctrlC: coordinator.send([0x03])
                        case .tab: coordinator.send([0x09])
                        case .esc: coordinator.send([0x1B])
                        case .paste: coordinator.pasteFromClipboard()
                        }
                    }
                }
                .transition(.move(edge: .bottom))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.focusTerminal()
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Show Keyboard")
                .disabled(connectionState != .connected)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        coordinator.focusTerminal()
                    } label: {
                        Label("Show Keyboard", systemImage: "keyboard")
                    }
                    Button {
                        coordinator.pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await reconnect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    Button {
                        coordinator.copySelection()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if case .attach = mode {
                        Button(role: .destructive) {
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
            coordinator.onStateChange = { state in
                connectionState = state
                if state == .connected {
                    isDisconnected = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            connectionState = coordinator.state
            coordinator.onError = { message in errorMessage = message }
            coordinator.onDisconnected = {
                isDisconnected = true
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .task {
            await coordinator.connect()
            // Focus after the view is in a window so the soft keyboard + SwiftTerm
            // accessory bar (Ctrl/Esc/Tab/arrows) can appear.
            try? await Task.sleep(nanoseconds: 150_000_000)
            coordinator.focusTerminal()
        }
        .onDisappear {
            coordinator.disconnect()
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(connectionState == .idle ? "Preparing…" : "Connecting…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(hostConfig.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(24)
            .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to \(hostConfig.host)")
        .transition(.opacity)
    }

    private var disconnectedOverlay: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Disconnected")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("The SSH connection was closed.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 12) {
                    Button("Reconnect") {
                        Task { await reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Detach") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
            .padding(24)
            .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disconnected. Reconnect or detach.")
    }

    private func reconnect() async {
        isDisconnected = false
        errorMessage = nil
        await coordinator.reconnect()
    }

    private static func killMessage(for error: Error) -> String {
        if let sshError = error as? SSHRemoteError {
            return sshError.userMessage
        }
        return "Could not kill the session: \(error.localizedDescription)"
    }
}
