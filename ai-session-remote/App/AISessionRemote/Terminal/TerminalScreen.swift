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

/// Decides whether flushed PTY bytes are drawn now or held until the surface is on screen.
/// `isShown` and flush both run on the main thread.
struct HiddenTerminalOutput {
    enum Decision: Equatable {
        case feed([UInt8])
        case hold
    }

    private(set) var held: [UInt8] = []

    /// How much hidden output is kept. Older bytes are dropped so a warm session that keeps
    /// printing cannot grow the hold without bound. The tail is what the screen shows on return.
    static let maxHeldBytes = 256 * 1024

    /// Shown output is returned for an immediate feed. Hidden output is appended to the hold.
    /// If the surface is already shown and bytes were still held, they are released in front of
    /// `bytes` as one feed so the screen catches up in order.
    mutating func receive(_ bytes: [UInt8], isShown: Bool) -> Decision {
        guard isShown else {
            appendHeld(bytes)
            return .hold
        }
        guard !held.isEmpty else { return .feed(bytes) }
        if !bytes.isEmpty {
            held.append(contentsOf: bytes)
        }
        let pending = held
        held.removeAll(keepingCapacity: true)
        return .feed(pending)
    }

    /// Bytes to feed when the surface becomes visible. Hiding leaves the hold in place.
    /// A second call after a successful flush returns nil so the same bytes are not replayed.
    mutating func flushHeld(isShown: Bool) -> [UInt8]? {
        guard isShown, !held.isEmpty else { return nil }
        let pending = held
        held.removeAll(keepingCapacity: true)
        return pending
    }

    /// Drops held bytes. Used on disconnect and reconnect so the next session is not replayed.
    mutating func clear() {
        held.removeAll(keepingCapacity: false)
    }

    private mutating func appendHeld(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        held.append(contentsOf: bytes)
        if held.count > Self.maxHeldBytes {
            held.removeFirst(held.count - Self.maxHeldBytes)
        }
    }
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
    /// The surface is the one on screen. Output for a background conversation is held and fed
    /// once from `setShown(true)`. A hidden surface does not take the keyboard or play the
    /// connect sound. Set on the main thread; the coalescer flushes on the main thread too.
    private(set) var isShown = true

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

    /// Bytes flushed while this surface is off screen. Cleared in `disconnect()`, which
    /// `reconnect()` calls first, so the next session is not replayed.
    private var hiddenOutput = HiddenTerminalOutput()

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
        },
        resizeScheduler: TerminalResizeDebouncer.Scheduler? = nil
    ) {
        self.hostConfig = hostConfig
        self.mode = mode
        self.makeTransport = makeTransport
        self.coalescer = TerminalOutputCoalescer { drain in
            DispatchQueue.main.async(execute: drain)
        }
        let scheduler = resizeScheduler ?? { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        self.resizeDebouncer = TerminalResizeDebouncer(scheduler: scheduler)
        // Safe to capture `self` here: by this point every stored property has an initial
        // value, so `self` is fully initialized.
        self.coalescer.onFlush = { [weak self] token, bytes in
            self?.deliverFlushed(token, bytes)
        }
    }

    /// Shown surfaces feed SwiftTerm immediately. Hidden ones append to `hiddenOutput` and
    /// catch up in one feed from `setShown(true)`. Bytes from a session `disconnect()` already
    /// retired are ignored, including a drain that was queued before the disconnect.
    private func deliverFlushed(_ token: Int, _ bytes: [UInt8]) {
        guard token == sessionGeneration else { return }
        switch hiddenOutput.receive(bytes, isShown: isShown) {
        case .feed(let pending):
            guard !pending.isEmpty else { return }
            terminalView?.feed(byteArray: pending[...])
        case .hold:
            break
        }
    }

    /// Records whether this surface is on screen and, when it becomes visible, feeds every
    /// byte held while it was hidden. Hiding cancels a resize already waiting out the
    /// debounce, so that window-change cannot land on the hidden session.
    func setShown(_ shown: Bool) {
        isShown = shown
        guard shown else {
            resizeDebouncer.cancelPending()
            return
        }
        guard let terminalView else { return }
        guard let pending = hiddenOutput.flushHeld(isShown: true) else { return }
        terminalView.feed(byteArray: pending[...])
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
        let outputToken = generation
        session.onOutput = { [weak self] bytes in
            // Arrives off the main thread. The coalescer is thread-safe and hops to the main
            // thread, where a shown surface feeds SwiftTerm and a hidden one holds the bytes.
            // `outputToken` is this connect's generation, so a flush from the session
            // `disconnect()` retired cannot land on the next one.
            self?.coalescer.append(bytes, token: outputToken)
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
        // Drop output held while this surface was hidden, and anything still queued in the
        // coalescer. A drain already scheduled then flushes an empty buffer. `reconnect()`
        // calls this before opening the next session, so that session is not replayed.
        hiddenOutput.clear()
        coalescer.discard()
        session?.disconnect()
        session = nil
    }

    func send(_ bytes: [UInt8]) {
        session?.send(bytes[...])
    }

    /// Pastes the clipboard the way SwiftTerm's own paste does: bracketed when the program
    /// asked for bracketed paste, so a multi-line paste isn't taken as several Returns.
    func pasteFromClipboard() {
        guard let text = PlatformSupport.pasteboardString, !text.isEmpty else { return }
        send(TerminalPaste.bytes(for: text, bracketed: isBracketedPasteMode))
    }

    /// Types `text` as a paste, then Return.
    func submit(_ text: String) {
        send(TerminalPaste.submission(text, bracketed: isBracketedPasteMode))
    }

    /// The program in the terminal turned bracketed paste on (`ESC[?2004h`).
    private var isBracketedPasteMode: Bool {
        terminalView?.getTerminal().bracketedPasteMode ?? false
    }

    /// Runs `disconnect()` on this turn, before the first await, so a close already queued
    /// for the pane that just exited cannot fail the session this opens.
    @MainActor
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
    /// briefly selects the whole visible buffer to grab its text. True when something was
    /// copied, so the caller can say so.
    @discardableResult
    func copySelection() -> Bool {
        guard let terminalView else { return false }
        let text: String?
        if terminalView.selectionActive {
            text = terminalView.getSelection()
        } else {
            terminalView.selectAll()
            text = terminalView.getSelection()
            terminalView.selectNone()
        }
        guard let text, !text.isEmpty else { return false }
        PlatformSupport.pasteboardString = text
        return true
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // A frame kept mounted behind the one on screen can be given a useless size. Applying
        // it would resize that tmux session. The real size is sent again when it is shown.
        guard isShown else { return }
        resizeDebouncer.sizeChanged(cols: newCols, rows: newRows) { [weak self] cols, rows in
            guard let self, self.isShown else { return }
            self.session?.resize(cols: cols, rows: rows)
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

    /// OSC 52 from the session: tmux (`set-clipboard on`) or the program itself. SwiftTerm's
    /// default delegate drops this, so a copy inside the session never reached this computer.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = TerminalClipboard.pasteboardText(from: content) else { return }
        let apply = {
            PlatformSupport.pasteboardString = text.isEmpty ? nil : text
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
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
    @State private var showingCopied = false
    @State private var copiedTask: Task<Void, Never>?

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
        .overlay(alignment: .top) {
            if showingCopied {
                CopiedToast().transition(.opacity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(palette.background).opacity(0.85), for: .navigationBar)
        .toolbarColorScheme(palette == .dark ? .dark : .light, for: .navigationBar)
        .toolbar {
            // No ⌨ here on iOS: the key bar's ⌨ shows and hides the keyboard.
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
                        copyScreen()
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

    /// Copies the selection, or else the screen, and says so like the conversation frame does.
    private func copyScreen() {
        guard terminal.copyScreen() else { return }
        copiedTask?.cancel()
        withAnimation { showingCopied = true }
        copiedTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingCopied = false }
        }
    }

    private static func killMessage(for error: Error) -> String {
        if let sshError = error as? SSHRemoteError {
            return sshError.userMessage
        }
        return "Could not kill the session: \(error.localizedDescription)"
    }
}
