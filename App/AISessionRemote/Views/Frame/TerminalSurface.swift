import AISessionCore
import SwiftTerm
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(macOS)
/// AppKit host for SwiftTerm's macOS `TerminalView`. Copy/Paste/Select All come from the
/// standard Edit menu: they target the first responder, which is this view once focused.
private struct TerminalContainerView: NSViewRepresentable {
    let coordinator: TerminalCoordinator
    let palette: TerminalPalette
    let fontSize: Double

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        TerminalAppearance.apply(to: view, palette: palette, fontSize: fontSize)
        view.optionAsMetaKey = true
        coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        TerminalAppearance.apply(to: nsView, palette: palette, fontSize: fontSize)
        coordinator.attach(to: nsView)
    }
}
#else
private struct TerminalContainerView: UIViewRepresentable {
    let coordinator: TerminalCoordinator
    let palette: TerminalPalette
    let fontSize: Double

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        // The surface docks `KeyBar` instead of SwiftTerm's `TerminalAccessory`.
        view.inputAccessoryView = UIView(frame: .zero)
        TerminalAppearance.apply(to: view, palette: palette, fontSize: fontSize)
        coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        TerminalAppearance.apply(to: uiView, palette: palette, fontSize: fontSize)
        coordinator.attach(to: uiView)
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
    /// The selection if there is one, otherwise the whole visible screen.
    func copyScreen() { coordinator?.copySelection() }
    func send(_ bytes: [UInt8]) { coordinator?.send(bytes) }
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
    ///   - disconnectedMessage: the line under "Disconnected".
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

    private var surface: some View {
        ZStack {
            TerminalContainerView(coordinator: coordinator, palette: palette, fontSize: fontSize)
                .padding(Self.inset)
                .background(Color(palette.background))
                #if os(macOS)
                .ignoresSafeArea(.container, edges: .bottom)
                #endif

            if showConnectingOverlay && (connectionState == .connecting || connectionState == .idle) {
                connectingOverlay
            }
            if isDisconnected {
                disconnectedOverlay
            }
        }
        .onAppear {
            coordinator.isShown = isFrontmost
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
                isDisconnected = true
                if coordinator.isShown { PlatformSupport.disconnectedFeedback() }
                onEnded(exitStatus)
            }
            coordinator.onUserInput = onUserInput
            handle?.coordinator = coordinator
            handle?.reconnectAction = { Task { await reconnect() } }
        }
        .onChange(of: isFrontmost) { _, shown in
            coordinator.isShown = shown
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

    private var disconnectedOverlay: some View {
        onTerminalBackground(
            VStack(spacing: DS.spacing.m) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .font(.title3.weight(.semibold))
                Text(disconnectedMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: DS.spacing.m) {
                    Button("Reconnect") {
                        Task { await reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    if let onDetach {
                        Button("Detach", action: onDetach)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.top, DS.spacing.xs)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(onDetach == nil ? "Disconnected. Reconnect." : "Disconnected. Reconnect or detach.")
    }

    private func reconnect() async {
        isDisconnected = false
        await coordinator.reconnect()
    }
}
