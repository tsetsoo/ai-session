import AISessionCore
import SwiftTerm
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where a pointer event on a conversation's terminal should land.
///
/// The grid is an AppKit or UIKit view, so a SwiftUI card drawn over it does not win hit
/// testing. Cursor leaves mouse reporting on, and the click becomes a report to a pane that
/// has already exited. The Reconnect button has to be a view above the grid. A conversation
/// kept mounted behind the one on screen passes the event through, or its grid takes the click.
enum TerminalHitTarget: Equatable {
    /// The grid on screen, connected.
    case grid
    /// The Disconnected card, in front of the grid.
    case cover
    /// A conversation that is not the one on screen.
    case passThrough

    static func resolve(isFrontmost: Bool, isDisconnected: Bool) -> TerminalHitTarget {
        guard isFrontmost else { return .passThrough }
        return isDisconnected ? .cover : .grid
    }
}

#if os(macOS)
/// Cmd+C reaches this view when it is first responder. A drag under tmux mouse tracking is
/// not a local selection, and SwiftTerm's `copy` still clears the pasteboard in that case.
private final class LocalClipboardTerminalView: TerminalView {
    override func copy(_ sender: Any) {
        guard selectionActive else { return }
        super.copy(sender)
    }
}

/// Hosts the terminal and, while disconnected, the Reconnect card in front of it.
/// The card is a subview, so AppKit hit testing reaches the button. The grid keeps its
/// autoresizing mask and is not resized again from `layout()`.
final class TerminalClickGate: NSView {
    let terminalView: TerminalView
    private var coverView: NSView?
    private var passesThrough = false

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = [.width, .height]
        terminalView.frame = bounds
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ target: TerminalHitTarget, cover: NSView? = nil) {
        switch target {
        case .cover:
            guard let cover else {
                passesThrough = true
                setCover(nil)
                return
            }
            passesThrough = false
            setCover(cover)
        case .grid:
            passesThrough = false
            setCover(nil)
        case .passThrough:
            passesThrough = true
            setCover(nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passesThrough { return nil }
        return super.hitTest(point)
    }

    private func setCover(_ view: NSView?) {
        guard view !== coverView else { return }
        coverView?.removeFromSuperview()
        coverView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// AppKit host for SwiftTerm's macOS `TerminalView`. Copy/Paste/Select All come from the
/// standard Edit menu: they target the first responder, which is this view once focused.
private struct TerminalContainerView: NSViewRepresentable {
    let coordinator: TerminalCoordinator
    let palette: TerminalPalette
    let fontSize: Double
    let hitTarget: TerminalHitTarget
    let cover: AnyView?

    func makeCoordinator() -> CoverHost { CoverHost() }

    final class CoverHost {
        let view = NSHostingView(rootView: AnyView(EmptyView()))
    }

    func makeNSView(context: Context) -> TerminalClickGate {
        let view = LocalClipboardTerminalView(frame: .zero)
        TerminalAppearance.apply(to: view, palette: palette, fontSize: fontSize)
        view.optionAsMetaKey = true
        coordinator.attach(to: view)
        let gate = TerminalClickGate(terminalView: view)
        updateCover(gate, context: context)
        return gate
    }

    func updateNSView(_ gate: TerminalClickGate, context: Context) {
        TerminalAppearance.apply(to: gate.terminalView, palette: palette, fontSize: fontSize)
        coordinator.attach(to: gate.terminalView)
        updateCover(gate, context: context)
    }

    private func updateCover(_ gate: TerminalClickGate, context: Context) {
        if hitTarget == .cover, let cover {
            context.coordinator.view.rootView = cover
            gate.apply(.cover, cover: context.coordinator.view)
        } else {
            gate.apply(hitTarget)
        }
    }
}
#else
private struct TerminalContainerView: UIViewRepresentable {
    let coordinator: TerminalCoordinator
    let palette: TerminalPalette
    let fontSize: Double
    let hitTarget: TerminalHitTarget

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        // The surface docks `KeyBar` instead of SwiftTerm's `TerminalAccessory`.
        view.inputAccessoryView = UIView(frame: .zero)
        TerminalAppearance.apply(to: view, palette: palette, fontSize: fontSize)
        view.isUserInteractionEnabled = hitTarget == .grid
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        TerminalAppearance.apply(to: uiView, palette: palette, fontSize: fontSize)
        coordinator.attach(to: uiView)
        let interactive = hitTarget == .grid
        if uiView.isUserInteractionEnabled != interactive {
            uiView.isUserInteractionEnabled = interactive
        }
    }
}
#endif

/// Lets the chrome around a `TerminalSurface` (menus, key bars) act on its terminal. The
/// surface fills it in when it appears; until then every action is a no-op.
@MainActor
@Observable
final class TerminalHandle {
    fileprivate(set) var connectionState: TerminalConnectionState = .idle
    @ObservationIgnored fileprivate weak var coordinator: TerminalCoordinator?
    @ObservationIgnored fileprivate var reconnectAction: () -> Void = {}

    var isConnected: Bool { connectionState == .connected }

    func reconnect() { reconnectAction() }
    func focus() { coordinator?.focusTerminal() }
    func resignFocus() { coordinator?.resignFocus() }
    func paste() { coordinator?.pasteFromClipboard() }
    /// The selection if there is one, otherwise the whole visible screen. True when something
    /// was copied.
    @discardableResult
    func copyScreen() -> Bool { coordinator?.copySelection() ?? false }
    func send(_ bytes: [UInt8]) { coordinator?.send(bytes) }
    /// Types `text` as a paste (bracketed when the program asked for it), then Return.
    func submit(_ text: String) { coordinator?.submit(text) }
}

/// One live terminal on a host: connects when it appears, focuses after connecting, shows the
/// connecting and disconnected states on the terminal's own background, and closes SSH when it
/// goes away (tmux keeps running on the host). On iOS it docks the `KeyBar` under the terminal.
/// Navigation chrome belongs to the caller.
struct TerminalSurface: View {
    /// Room around the grid, filled with the terminal background so it reads as terminal.
    private static var inset: CGFloat {
        #if os(macOS)
        10
        #else
        6
        #endif
    }

    let config: HostConnectionConfig
    let mode: TerminalMode
    private let hostName: String?
    private let focusOnConnect: Bool
    private let handle: TerminalHandle?
    private let onDetach: (() -> Void)?
    private let disconnectedMessage: String
    private let onConnectionFailed: (Error) -> Void
    private let onEnded: (Int?) -> Void
    private let onUserInput: () -> Void
    private let tool: String?
    private let approveEnabled: Bool
    /// False while another conversation is the one on screen. The session stays connected.
    private let isFrontmost: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// Absent in previews and other screens that don't provide it.
    @Environment(AppModel.self) private var appModel: AppModel?
    @AppStorage("terminal.fontSize") private var fontSize = TerminalAppearance.defaultFontSize
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue
    @State private var coordinator: TerminalCoordinator
    @State private var connectionState: TerminalConnectionState = .idle
    @State private var isDisconnected = false
    /// Why the session ended, for the card: a lost connection, or the tool quitting.
    @State private var ending: TerminalEnding = .connectionLost
    /// Gates `connectingOverlay`. With a warm connection pool, attach (and reconnect) are
    /// usually fast enough that showing this immediately would just be a flash; it's only
    /// raised once `.connecting`/`.idle` has held for ~250ms. Applies to every connect/reconnect,
    /// not just the first, via the `onChange` below.
    @State private var showConnectingOverlay = false
    @State private var connectingOverlayTask: Task<Void, Never>?
    #if os(iOS)
    @State private var ctrlArmed = false
    @State private var keyboardVisible = false
    #endif

    /// - Parameters:
    ///   - hostName: shown while connecting; defaults to the config's host.
    ///   - handle: filled in so the caller's menus can reconnect, copy, paste and focus.
    ///   - onDetach: when set, the disconnected state offers Detach next to Reconnect.
    ///   - disconnectedMessage: the line under "Disconnected" when the connection was lost.
    ///   - onConnectionFailed: the connect failed, with why.
    ///   - onEnded: the session ended, with the PTY's exit status (nil = connection dropped).
    ///   - onUserInput: the user typed into the terminal or used the key bar (not the terminal's
    ///     own replies, see `TerminalInputClassifier`).
    ///   - tool: the conversation's tool; shows Approve on the key bar (iOS). Nil hides it.
    ///   - approveEnabled: whether Approve can be pressed now.
    init(
        config: HostConnectionConfig,
        mode: TerminalMode,
        hostName: String? = nil,
        focusOnConnect: Bool = true,
        handle: TerminalHandle? = nil,
        onDetach: (() -> Void)? = nil,
        disconnectedMessage: String = "The connection was closed.",
        onConnectionFailed: @escaping (Error) -> Void = { _ in },
        onEnded: @escaping (Int?) -> Void = { _ in },
        onUserInput: @escaping () -> Void = {},
        tool: String? = nil,
        approveEnabled: Bool = false,
        isFrontmost: Bool = true,
        makeTransport: @escaping (HostConnectionConfig, TerminalMode) -> any TerminalTransport = {
            SSHTerminalSession(config: $0, mode: $1)
        }
    ) {
        self.config = config
        self.mode = mode
        self.hostName = hostName
        self.focusOnConnect = focusOnConnect
        self.handle = handle
        self.onDetach = onDetach
        self.disconnectedMessage = disconnectedMessage
        self.onConnectionFailed = onConnectionFailed
        self.onEnded = onEnded
        self.onUserInput = onUserInput
        self.tool = tool
        self.approveEnabled = approveEnabled
        self.isFrontmost = isFrontmost
        _coordinator = State(initialValue: TerminalCoordinator(
            hostConfig: config, mode: mode, makeTransport: makeTransport
        ))
    }

    private var palette: TerminalPalette {
        TerminalAppearance.palette(theme: TerminalTheme(rawValue: themeRaw) ?? .system, colorScheme: colorScheme)
    }

    var body: some View {
        #if os(iOS)
        surface
            .safeAreaInset(edge: .bottom, spacing: 0) { keyBar }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) { note in
                // SwiftTerm applied Ctrl to a typed key.
                if (note.object as AnyObject?) === coordinator.terminalView {
                    ctrlArmed = false
                }
            }
            .onChange(of: ctrlArmed) { _, armed in
                coordinator.controlModifier = armed
            }
        #else
        surface
        #endif
    }

    #if os(iOS)
    /// Docked under the terminal, so the terminal resizes (through SwiftTerm's normal resize)
    /// when the keyboard comes and goes. Present from the start, so connecting doesn't resize it.
    private var keyBar: some View {
        KeyBar(
            tool: tool,
            approveEnabled: approveEnabled,
            ctrlArmed: $ctrlArmed,
            keyboardVisible: keyboardVisible,
            send: { bytes in
                coordinator.send(bytes)
                onUserInput()
            },
            toggleKeyboard: {
                if keyboardVisible {
                    coordinator.hideKeyboard()
                } else {
                    coordinator.focusTerminal()
                }
            },
            paste: {
                coordinator.pasteFromClipboard()
                onUserInput()
            }
        )
        .disabled(connectionState != .connected)
        .environment(\.colorScheme, palette == .dark ? .dark : .light)
    }
    #endif

    private var hitTarget: TerminalHitTarget {
        TerminalHitTarget.resolve(isFrontmost: isFrontmost, isDisconnected: isDisconnected)
    }

    private var surface: some View {
        ZStack {
            terminalGrid
            if showConnectingOverlay && (connectionState == .connecting || connectionState == .idle) {
                connectingOverlay
            }
            // On the Mac the card is a subview of the grid's host, in front of `TerminalView`.
            // A SwiftUI sibling never wins that hit test. On iOS the grid stops taking touches
            // and this sibling does.
            #if !os(macOS)
            if isDisconnected {
                disconnectedOverlay
                    .zIndex(1)
            }
            #endif
        }
        .onAppear {
            coordinator.setShown(isFrontmost)
            coordinator.onStateChange = { state in
                connectionState = state
                handle?.connectionState = state
                if state == .connected {
                    isDisconnected = false
                    // A session that finished connecting behind another conversation stays quiet.
                    if coordinator.isShown { PlatformSupport.connectedFeedback() }
                }
            }
            connectionState = coordinator.state
            handle?.connectionState = coordinator.state
            coordinator.onError = { error in onConnectionFailed(error) }
            coordinator.onDisconnected = { exitStatus in
                ending = TerminalEnding(exitStatus: exitStatus)
                isDisconnected = true
                if coordinator.isShown { PlatformSupport.disconnectedFeedback() }
                onEnded(exitStatus)
            }
            coordinator.onUserInput = onUserInput
            handle?.coordinator = coordinator
            handle?.reconnectAction = { Task { await reconnect() } }
        }
        .onChange(of: isFrontmost) { _, shown in
            coordinator.setShown(shown)
            if shown {
                // Not on first appear: connect already tells tmux the size, and a second
                // window-change makes it repaint.
                coordinator.syncSizeToView()
            } else {
                coordinator.resignFocus()
                handle?.resignFocus()
            }
        }
        .onChange(of: connectionState, initial: true) { _, newState in
            // Re-armed on every transition into `.connecting`/`.idle`, so this also covers
            // `reconnect()` — not just the very first connect from `.task` below.
            connectingOverlayTask?.cancel()
            if newState == .connecting || newState == .idle {
                connectingOverlayTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled {
                        showConnectingOverlay = true
                    }
                }
            } else {
                showConnectingOverlay = false
            }
        }
        .task {
            await coordinator.connect()
            #if DEBUG && os(iOS)
            // Screenshots: `-uiDemoCtrlArmed` arms Ctrl, `-uiDemoKeyboard down` keeps the keyboard away.
            if DemoFixtures.isEnabled {
                if ProcessInfo.processInfo.arguments.contains("-uiDemoCtrlArmed") { ctrlArmed = true }
                if DemoFixtures.value(after: "-uiDemoKeyboard") == "down" { return }
            }
            #endif
            guard focusOnConnect else { return }
            // Focus after the view is in a window so the soft keyboard can appear.
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Not from under the ⌘K palette's search field; closing it brings focus back.
            guard appModel?.allowsTerminalAutoFocus ?? true else { return }
            coordinator.focusTerminal()
        }
        .onDisappear {
            connectingOverlayTask?.cancel()
            coordinator.disconnect()
            // Unless a newer surface already took the handle over.
            if handle?.coordinator === coordinator {
                handle?.connectionState = .idle
            }
        }
    }

    /// Drawn on the terminal background (no scrim), in the terminal's own light/dark scheme so
    /// the system text colours stay legible whatever the app's appearance.
    private func onTerminalBackground(_ content: some View) -> some View {
        content
            .padding(DS.spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(palette.background))
            .environment(\.colorScheme, palette == .dark ? .dark : .light)
    }

    private var connectingOverlay: some View {
        onTerminalBackground(
            VStack(spacing: DS.spacing.m) {
                ProgressView()
                Text(connectionState == .idle ? "Preparing…" : "Connecting to \(hostName ?? config.host)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to \(hostName ?? config.host)")
        .transition(.opacity)
    }

    /// The grid host. Hit testing differs by platform: see `surface`.
    private var terminalGrid: some View {
        #if os(macOS)
        // The card is a subview of this host. Pass-through is the only case that must miss.
        TerminalContainerView(
            coordinator: coordinator,
            palette: palette,
            fontSize: fontSize,
            hitTarget: hitTarget,
            cover: hitTarget == .cover ? AnyView(disconnectedOverlay) : nil
        )
        .padding(Self.inset)
        .background(Color(palette.background))
        .allowsHitTesting(hitTarget != .passThrough)
        .ignoresSafeArea(.container, edges: .bottom)
        #else
        // The card is the sibling above. The grid has to miss or it keeps the click.
        TerminalContainerView(
            coordinator: coordinator,
            palette: palette,
            fontSize: fontSize,
            hitTarget: hitTarget
        )
        .padding(Self.inset)
        .background(Color(palette.background))
        .allowsHitTesting(hitTarget == .grid)
        #endif
    }

    /// The card after the session ended. A lost connection says so; a tool that quit (exit
    /// status, no network problem) says the conversation ended and offers to resume it.
    private var endedCard: (symbol: String, title: String, message: String, action: String) {
        let host = hostName ?? config.host
        let what = tool.map(RowText.toolName) ?? "The session"
        switch ending {
        case .connectionLost:
            return ("wifi.slash", "Disconnected", disconnectedMessage, "Reconnect")
        case .finished:
            return ("stop.circle", tool == nil ? "Session ended" : "Conversation ended",
                    "\(what) finished on \(host).", tool == nil ? "Reconnect" : "Resume")
        case .stopped:
            return ("stop.circle", tool == nil ? "Session ended" : "Conversation ended",
                    "\(what) stopped on \(host).", tool == nil ? "Reconnect" : "Resume")
        }
    }

    private var disconnectedOverlay: some View {
        let card = endedCard
        return onTerminalBackground(
            VStack(spacing: DS.spacing.m) {
                VStack(spacing: DS.spacing.m) {
                    Image(systemName: card.symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(card.title)
                        .font(.title3.weight(.semibold))
                    Text(card.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(onDetach == nil
                    ? "\(card.title). \(card.action)."
                    : "\(card.title). \(card.action) or detach.")
                HStack(spacing: DS.spacing.m) {
                    Button(card.action) {
                        Task { await reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    .accessibilityLabel(card.action)
                    if let onDetach {
                        Button("Detach", action: onDetach)
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Detach")
                    }
                }
                .padding(.top, DS.spacing.xs)
            }
        )
    }

    private func reconnect() async {
        isDisconnected = false
        await coordinator.reconnect()
    }
}
