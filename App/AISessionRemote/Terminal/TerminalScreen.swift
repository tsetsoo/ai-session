import AISessionCore
import SwiftTerm
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    var onDisconnected: ((Int?) -> Void)?
    var onStateChange: ((TerminalConnectionState) -> Void)?
    /// Anything the terminal view sends: typed keys, but also SwiftTerm's own replies (DA/DSR/
    /// cursor reports, focus and mouse reports). Not bytes sent with `send(_:)`.
    var onUserInput: (() -> Void)?

    private let hostConfig: HostConnectionConfig
    private let mode: TerminalMode
    private var session: (any TerminalTransport)?
    private(set) var state: TerminalConnectionState = .idle {
        didSet { onStateChange?(state) }
    }

    /// Batches remote output into one `feed()` per display frame instead of one per inbound SSH
    /// chunk. `append` is thread-safe and called from `session.onOutput`, which arrives off the
    /// main thread; `onFlush` runs after the injected scheduler hops to the main thread.
    private let coalescer: TerminalOutputCoalescer

    /// Debounces `sizeChanged` reports (see `TerminalResizeDebouncer`). Only ever touched from
    /// the main thread.
    private let resizeDebouncer: TerminalResizeDebouncer

    private let makeTransport: (HostConnectionConfig, TerminalMode) -> any TerminalTransport

    init(
        hostConfig: HostConnectionConfig,
        mode: TerminalMode,
        makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = {
            SSHTerminalSession(config: $0, mode: $1)
        }
    ) {
        self.hostConfig = hostConfig
        self.mode = mode
        self.makeTransport = makeTransport
        self.coalescer = TerminalOutputCoalescer { drain in
            DispatchQueue.main.async(execute: drain)
        }
        self.resizeDebouncer = TerminalResizeDebouncer { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        // Safe to capture `self` here: by this point every stored property has an initial
        // value, so `self` is fully initialized.
        self.coalescer.onFlush = { [weak self] bytes in
            self?.terminalView?.feed(byteArray: bytes[...])
        }
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

        let session = makeTransport(hostConfig, mode)
        session.onOutput = { [weak self] bytes in
            // Arrives off the main thread; the coalescer is thread-safe and does the main-thread
            // hop itself before `feed`ing SwiftTerm.
            self?.coalescer.append(bytes)
        }
        session.onDisconnect = { [weak self] exitStatus in
            DispatchQueue.main.async {
                self?.state = .failed
                self?.onDisconnected?(exitStatus)
            }
        }
        self.session = session

        do {
            try await session.connect(cols: cols, rows: rows)
            let liveTerminal = terminalView.getTerminal()
            // The PTY was already requested at cols x rows; only tell the host if the view
            // actually changed size while connecting. An unnecessary window-change makes tmux
            // repaint the whole screen at the worst possible moment.
            if liveTerminal.cols > 0, liveTerminal.rows > 0,
               liveTerminal.cols != cols || liveTerminal.rows != rows {
                session.resize(cols: liveTerminal.cols, rows: liveTerminal.rows)
                resizeDebouncer.noteSentSize(cols: liveTerminal.cols, rows: liveTerminal.rows)
            } else {
                resizeDebouncer.noteSentSize(cols: cols, rows: rows)
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
        // Must run before tearing down `session`: without it, a resize debounced for this
        // session could still fire later (after a `reconnect()`) and land — at a now-stale
        // size — on whatever new session replaces it.
        resizeDebouncer.cancelPending()
        session?.disconnect()
        session = nil
    }

    func send(_ bytes: [UInt8]) {
        session?.send(bytes[...])
    }

    func pasteFromClipboard() {
        guard let text = PlatformSupport.pasteboardString,
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
        #if os(iOS)
        if !terminalView.isFirstResponder {
            _ = terminalView.becomeFirstResponder()
        }
        #else
        if terminalView.window?.firstResponder !== terminalView {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        #endif
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
            PlatformSupport.pasteboardString = text
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resizeDebouncer.sizeChanged(cols: newCols, rows: newRows) { [weak self] cols, rows in
            self?.session?.resize(cols: cols, rows: rows)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?()
        session?.send(data)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        PlatformSupport.open(url)
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

/// Interactive terminal for a single tmux session. SwiftTerm owns the soft-key
/// accessory above the system keyboard (`TerminalAccessory`: Ctrl, Esc, Tab, arrows).
/// Detaching closes SSH only — tmux keeps running on the host.
struct TerminalScreen: View {
    let hostConfig: HostConnectionConfig
    let mode: TerminalMode
    let title: String
    let onKill: () async throws -> Void
    private let makeTransport: (HostConnectionConfig, TerminalMode) -> any TerminalTransport

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue
    @State private var terminal = TerminalHandle()
    @State private var errorMessage: String?
    @State private var killErrorMessage: String?
    @State private var showingKillConfirmation = false
    @State private var keyboardVisible = false

    init(
        hostConfig: HostConnectionConfig,
        mode: TerminalMode,
        title: String,
        onKill: @escaping () async throws -> Void,
        makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = {
            SSHTerminalSession(config: $0, mode: $1)
        }
    ) {
        self.hostConfig = hostConfig
        self.mode = mode
        self.title = title
        self.onKill = onKill
        self.makeTransport = makeTransport
    }

    private var palette: TerminalPalette {
        TerminalAppearance.palette(theme: TerminalTheme(rawValue: themeRaw) ?? .system, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            TerminalSurface(
                config: hostConfig,
                mode: mode,
                handle: terminal,
                onDetach: { dismiss() },
                disconnectedMessage: "The SSH connection was closed.",
                onConnectionFailed: { message in errorMessage = message },
                makeTransport: makeTransport
            )
            #if os(iOS)
            if terminal.connectionState == .connected && !keyboardVisible {
                VStack {
                    Spacer()
                    SoftKeyBar { key in
                        switch key {
                        case .ctrlC: terminal.send([0x03])
                        case .tab: terminal.send([0x09])
                        case .esc: terminal.send([0x1B])
                        case .paste: terminal.paste()
                        }
                    }
                }
                .transition(.move(edge: .bottom))
            }
            #endif
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(palette.background).opacity(0.85), for: .navigationBar)
        .toolbarColorScheme(palette == .dark ? .dark : .light, for: .navigationBar)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    terminal.focus()
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Show Keyboard")
                .disabled(!terminal.isConnected)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        terminal.focus()
                    } label: {
                        Label("Show Keyboard", systemImage: "keyboard")
                    }
                    Button {
                        terminal.paste()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        errorMessage = nil
                        terminal.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    Button {
                        terminal.copyScreen()
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
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        #endif
    }

    private static func killMessage(for error: Error) -> String {
        if let sshError = error as? SSHRemoteError {
            return sshError.userMessage
        }
        return "Could not kill the session: \(error.localizedDescription)"
    }
}
