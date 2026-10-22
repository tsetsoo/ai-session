import AISessionCore
import SwiftUI

/// The iPhone's terminal keys, docked under the terminal: above the keyboard when it is up and
/// at the bottom when it is down. The keys scroll sideways when they don't fit, and Approve stays
/// pinned on the right. Draws in the environment's colour scheme, which the terminal sets to its
/// own palette's. iOS only (excluded from the Mac target).
struct KeyBar: View {
    static let height: CGFloat = 50
    /// Every cap is at least this wide, the smallest comfortable touch target. The row scrolls.
    static let minCapWidth: CGFloat = 44

    /// The conversation's tool; nil (a plain terminal) hides Approve.
    let tool: String?
    let approveEnabled: Bool
    @Binding var ctrlArmed: Bool
    let keyboardVisible: Bool
    let send: ([UInt8]) -> Void
    let toggleKeyboard: () -> Void
    let paste: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .caption) private var checkmarkSize: CGFloat = 12

    init(
        tool: String?,
        approveEnabled: Bool,
        ctrlArmed: Binding<Bool>,
        keyboardVisible: Bool,
        send: @escaping ([UInt8]) -> Void,
        toggleKeyboard: @escaping () -> Void,
        paste: @escaping () -> Void
    ) {
        self.tool = tool
        self.approveEnabled = approveEnabled
        _ctrlArmed = ctrlArmed
        self.keyboardVisible = keyboardVisible
        self.send = send
        self.toggleKeyboard = toggleKeyboard
        self.paste = paste
    }

    var body: some View {
        let colors = KeyBarColors(colorScheme)
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    key("esc", "Escape", .esc)
                    key("tab", "Tab", .tab)
                    KeyCap(cap: "ctrl", armed: ctrlArmed) {
                        PlatformSupport.keyTapFeedback()
                        ctrlArmed.toggle()
                    }
                    .accessibilityLabel("Control")
                    .accessibilityValue(ctrlArmed ? "On" : "Off")
                    key("←", "Left arrow", .left, repeats: true)
                    key("↑", "Up arrow", .up, repeats: true)
                    key("↓", "Down arrow", .down, repeats: true)
                    key("→", "Right arrow", .right, repeats: true)
                    key("⏎", "Return", .enter)
                    key("⇧⏎", "New line", .shiftEnter)
                    // The ⌨ glyph draws tiny in the monospaced font, so this cap is a symbol.
                    KeyCap(
                        cap: "⌨",
                        symbol: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                        hold: .longPress(longPressPaste)
                    ) {
                        PlatformSupport.keyTapFeedback()
                        toggleKeyboard()
                    }
                    .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
                    .accessibilityHint("Touch and hold to paste.")
                    .accessibilityAction(named: "Paste", longPressPaste)
                }
                .padding(.leading, DS.spacing.s)
                .padding(.trailing, tool == nil ? DS.spacing.s : DS.spacing.m)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // Keys that run under Approve fade out, hinting that the row scrolls.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    if tool != nil {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: DS.spacing.m)
                    }
                }
            }

            if let tool {
                approveButton(tool: tool)
                    .padding(.trailing, DS.spacing.s)
            }
        }
        .frame(height: Self.height)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(colors.bar.opacity(0.88))
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(colors.separator)
                .frame(height: 1 / displayScale)
        }
        // Labels grow with the text size, up to what still fits a cap in the fixed-height bar.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
    }

    private func key(_ cap: String, _ label: String, _ key: TerminalKey, repeats: Bool = false) -> some View {
        KeyCap(cap: cap, hold: repeats ? .repeating { press(key, haptic: false) } : .none) {
            press(key)
        }
        .accessibilityLabel(label)
    }

    private func approveButton(tool: String) -> some View {
        Button {
            PlatformSupport.approveFeedback()
            ctrlArmed = false
            send(TerminalKey.approve.bytes(tool: tool))
        } label: {
            HStack(spacing: DS.spacing.xs) {
                Image(systemName: "checkmark")
                    .font(.system(size: checkmarkSize, weight: .bold))
                Text("Approve")
            }
        }
        // Codex reports no status, so its Approve is always on and stays neutral.
        .buttonStyle(ApproveKeyStyle(filled: approveEnabled && tool != "codex"))
        .disabled(!approveEnabled)
        .accessibilityLabel("Approve")
        .accessibilityHint(tool == "codex" ? "Answers yes to the prompt." : "Chooses option 1 at the permission prompt.")
    }

    /// A bar key: clears a pending Ctrl (it applied to nothing SwiftTerm sends) and sends the key.
    private func press(_ key: TerminalKey, haptic: Bool = true) {
        if haptic { PlatformSupport.keyTapFeedback() }
        ctrlArmed = false
        send(key.bytes(tool: tool ?? "claude"))
    }

    private func longPressPaste() {
        PlatformSupport.keyTapFeedback()
        paste()
    }
}

/// The key bar's colours for the terminal's light or dark palette.
private struct KeyBarColors {
    let bar: Color
    let separator: Color
    let key: Color
    let keyPressed: Color
    let keyLabel: Color
    let keyShadow: Color
    /// `DS.accent` (it resolves in the terminal's scheme, which the bar's environment carries),
    /// and the label that keeps its contrast on it (like `AccentButtonStyle`).
    let accent: Color
    let accentLabel: Color

    init(_ scheme: ColorScheme) {
        func hex(_ value: UInt32) -> Color { Color(PlatformNativeColor(hex: value)) }
        if scheme == .dark {
            bar = hex(0x232325)
            separator = hex(0x38383B)
            key = hex(0x3A3A3D)
            keyPressed = hex(0x4C4C50)
            keyLabel = hex(0xF2F2F4)
            keyShadow = hex(0x0E0E0F)
            accent = DS.accent
            accentLabel = hex(0x1C1C1E)
        } else {
            bar = hex(0xF7F6F3)
            separator = hex(0xE2E0DC)
            key = hex(0xFFFFFF)
            keyPressed = hex(0xDEDCD7)
            keyLabel = hex(0x1D1D1F)
            keyShadow = hex(0xC9C7C2)
            accent = DS.accent
            accentLabel = .white
        }
    }
}

/// One key cap. A tap runs `action`; holding it can repeat it or do something else instead.
private struct KeyCap: View {
    enum Hold {
        case none
        /// Held past 0.4 s: `action` runs, then this every 0.08 s until released.
        case repeating(() -> Void)
        /// Held past 0.5 s: this runs once, instead of `action`.
        case longPress(() -> Void)
    }

    let cap: String
    /// An SF Symbol drawn instead of `cap`.
    var symbol: String?
    var armed = false
    var hold: Hold = .none
    let action: () -> Void

    @State private var holdTask: Task<Void, Never>?
    /// The hold already acted, so the release must not also tap.
    @State private var held = false
    @ScaledMetric(relativeTo: .caption) private var symbolSize: CGFloat = 14

    var body: some View {
        Button {
            if held {
                held = false
            } else {
                action()
            }
        } label: {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .medium))
            } else {
                Text(cap)
            }
        }
        .buttonStyle(KeyCapStyle(armed: armed, onPressChange: pressChanged))
        .onDisappear { holdTask?.cancel() }
    }

    private func pressChanged(_ pressed: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard pressed else { return }
        // A press that turned into a scroll never reaches the action, so reset here.
        held = false
        switch hold {
        case .none:
            return
        case let .repeating(repeatAction):
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                held = true
                action()
                while true {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard !Task.isCancelled else { return }
                    repeatAction()
                }
            }
        case let .longPress(longAction):
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                held = true
                longAction()
            }
        }
    }
}

private struct KeyCapStyle: ButtonStyle {
    let armed: Bool
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        KeyCapBody(configuration: configuration, armed: armed, onPressChange: onPressChange)
    }
}

private struct KeyCapBody: View {
    let configuration: ButtonStyleConfiguration
    let armed: Bool
    let onPressChange: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

    var body: some View {
        let colors = KeyBarColors(colorScheme)
        let fill = armed ? colors.accent : (configuration.isPressed ? colors.keyPressed : colors.key)
        configuration.label
            .font(.system(size: labelSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(armed ? colors.accentLabel : colors.keyLabel)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minWidth: KeyBar.minCapWidth, minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
                    .shadow(color: colors.keyShadow, radius: 0, x: 0, y: 1)
            }
            .opacity(armed && configuration.isPressed ? 0.75 : 1)
            // The whole bar height is the touch target.
            .padding(.vertical, (KeyBar.height - 34) / 2)
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, pressed in onPressChange(pressed) }
    }
}

private struct ApproveKeyStyle: ButtonStyle {
    let filled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .callout) private var labelSize: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let colors = KeyBarColors(colorScheme)
        let fill = filled ? colors.accent : (configuration.isPressed ? colors.keyPressed : colors.key)
        configuration.label
            .font(.system(size: labelSize, weight: .semibold))
            .foregroundStyle(filled ? colors.accentLabel : colors.keyLabel)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
                    .shadow(color: filled ? .clear : colors.keyShadow, radius: 0, x: 0, y: 1)
            }
            .opacity(isEnabled ? (filled && configuration.isPressed ? 0.75 : 1) : 0.4)
            .padding(.vertical, (KeyBar.height - 34) / 2)
            .contentShape(Rectangle())
    }
}
