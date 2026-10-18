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
    /// The connect failed. `TerminalCoordinator.message(for:)` words it for an alert.
    var onError: ((Error) -> Void)?
    var onDisconnected: ((Int?) -> Void)?
    var onStateChange: ((TerminalConnectionState) -> Void)?
    /// The user typed into the terminal view. SwiftTerm's own replies through the same channel
    /// (DA/DSR/cursor, focus and mouse reports, colour and version replies) don't count, and
    /// neither do bytes sent with `send(_:)`.
    var onUserInput: (() -> Void)?
    /// The surface is the one on screen. A conversation kept attached in the background still
    /// receives output, but it must not take the keyboard or play the connect sound.
    var isShown = true

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

    /// Bumped on every connect and disconnect. A pane that exits (Cursor does this) delivers
    /// its close on the next main turn. Reconnect must ignore that late close, or it marks
    /// the new session failed and the Disconnected card never leaves.
    private var sessionGeneration = 0

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
        sessionGeneration += 1
        let generation = sessionGeneration
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
                guard let self, self.sessionGeneration == generation else { return }
                self.session = nil
                self.state = .failed
                self.onDisconnected?(exitStatus)
            }
        }
        self.session = session

        do {
            try await session.connect(cols: cols, rows: rows)
            guard sessionGeneration == generation else { return }
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
            guard sessionGeneration == generation else { return }
            self.session = nil
            state = .failed
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.onError?(error)
            }
        }
    }

    /// Closes the SSH connection only. `tmux` keeps the session running on the remote host.
    func disconnect() {
        // Must run before tearing down `session`: without it, a resize debounced for this
        // session could still fire later (after a `reconnect()`) and land — at a now-stale
        // size — on whatever new session replaces it.
        // Also drops this session's generation so its close, which arrives on a later turn,
        // cannot fail the session `reconnect()` is about to open.
        sessionGeneration += 1
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

    /// Makes the embedded `TerminalView` first responder so the soft keyboard appears.
    func focusTerminal() {
        guard isShown, let terminalView else { return }
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

    /// Drops keyboard focus if this terminal has it, so a hidden session doesn't keep typing.
    func resignFocus() {
        guard let terminalView else { return }
        #if os(iOS)
        if terminalView.isFirstResponder {
            _ = terminalView.resignFirstResponder()
        }
        #else
        if terminalView.window?.firstResponder === terminalView {
            terminalView.window?.makeFirstResponder(nil)
        }
        #endif
    }

    #if os(iOS)
    /// Puts the soft keyboard away.
    func hideKeyboard() {
        guard let terminalView, terminalView.isFirstResponder else { return }
        _ = terminalView.resignFirstResponder()
    }

    /// SwiftTerm's sticky Ctrl: applies to the next typed key, then resets itself (posting
    /// `.terminalViewControlModifierReset`).
    var controlModifier: Bool {
        get { terminalView?.controlModifier ?? false }
        set { terminalView?.controlModifier = newValue }
    }
    #endif

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
        // A frame kept mounted behind the one on screen can be given a useless size. Applying
        // it would resize that tmux session. The real size is sent again when it is shown.
        guard isShown else { return }
        resizeDebouncer.sizeChanged(cols: newCols, rows: newRows) { [weak self] cols, rows in
            self?.session?.resize(cols: cols, rows: rows)
        }
    }

    /// The frame came back on screen: tell tmux the size it has now.
    func syncSizeToView() {
        guard let terminalView else { return }
        let terminal = terminalView.getTerminal()
        sizeChanged(source: terminalView, newCols: terminal.cols, newRows: terminal.rows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !TerminalInputClassifier.isTerminalReport(Array(data)) {
            onUserInput?()
        }
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

    static func message(for error: Error) -> String {
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

/// Interactive terminal for a single tmux session. On iOS the surface docks the key bar (Esc,
/// Tab, Ctrl, arrows) under it. Detaching closes SSH only — tmux keeps running on the host.
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
        TerminalSurface(
            config: hostConfig,
            mode: mode,
            handle: terminal,
            onDetach: { dismiss() },
            disconnectedMessage: "The SSH connection was closed.",
            onConnectionFailed: { error in errorMessage = TerminalCoordinator.message(for: error) },
            makeTransport: makeTransport
        )
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
    }

    private static func killMessage(for error: Error) -> String {
        if let sshError = error as? SSHRemoteError {
            return sshError.userMessage
        }
        return "Could not kill the session: \(error.localizedDescription)"
    }
}
