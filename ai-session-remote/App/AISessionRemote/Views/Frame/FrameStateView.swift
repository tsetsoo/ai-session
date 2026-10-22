import AISessionCore
import SwiftUI

/// A button in a frame state block.
struct FrameStateButton {
    let title: String
    let action: () -> Void
}

/// The block the frame draws in the terminal area when there is no live terminal: icon,
/// headline, explanation, an optional copyable command, one primary action (Return) and at
/// most one secondary. Transparent: the frame puts it on the terminal background.
struct FrameStateBlock: View {
    var systemImage: String?
    var iconTint: Color = .secondary
    var showsProgress = false
    let title: String
    var message: String?
    var code: String?
    var primary: FrameStateButton?
    var secondary: FrameStateButton?

    var body: some View {
        VStack(spacing: DS.spacing.m) {
            if showsProgress {
                ProgressView()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(iconTint)
                    .padding(.bottom, DS.spacing.xs)
            }
            Text(title)
                .font(showsProgress ? .callout : .title3.weight(.semibold))
                .foregroundStyle(showsProgress ? .secondary : .primary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let code {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.spacing.m)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if primary != nil || secondary != nil {
                HStack(spacing: DS.spacing.m) {
                    if let primary {
                        Button(primary.title, action: primary.action)
                            .buttonStyle(.borderedProminent)
                            .tint(DS.accent)
                            .keyboardShortcut(.defaultAction)
                    }
                    if let secondary {
                        Button(secondary.title, action: secondary.action)
                            .buttonStyle(.bordered)
                            .tint(DS.accent)
                    }
                }
                .padding(.top, DS.spacing.xs)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
        .padding(DS.spacing.xl)
    }
}

/// Fills the terminal area with the terminal's background, in the terminal's own light/dark
/// scheme so system text colours stay legible whatever the app's appearance.
struct OnTerminalBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("terminal.theme") private var themeRaw = TerminalTheme.system.rawValue

    func body(content: Content) -> some View {
        let palette = TerminalAppearance.palette(theme: TerminalTheme(rawValue: themeRaw) ?? .system,
                                                 colorScheme: colorScheme)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(palette.background))
            .environment(\.colorScheme, palette == .dark ? .dark : .light)
    }
}

/// The frame's progress state before there is a todo to frame (a pop-out window restored before
/// the first sync).
struct FrameLoadingView: View {
    let title: String

    var body: some View {
        FrameStateBlock(showsProgress: true, title: title)
            .modifier(OnTerminalBackground())
    }
}

/// A `FrameProblem` as an in-frame state (spec §6): what's wrong and the action that fixes it.
struct FrameStateView: View {
    let problem: FrameProblem
    let actions: FrameActions
    /// The conversation's tool ("claude" / "codex"), for "Claude isn't installed".
    var tool: String?
    /// Offered as a secondary action when the conversation is gone.
    var resumeCommand: String?

    init(problem: FrameProblem, actions: FrameActions, tool: String? = nil, resumeCommand: String? = nil) {
        self.problem = problem
        self.actions = actions
        self.tool = tool
        self.resumeCommand = resumeCommand
    }

    var body: some View {
        switch problem {
        case let .noComputer(section):
            FrameStateBlock(
                systemImage: "desktopcomputer",
                title: "No computer runs \(section.rawValue) conversations yet",
                message: "Choose which computer and folder \(section.rawValue) conversations start on.",
                primary: FrameStateButton(title: "Choose Computer") { actions.openSettings(.sections(section)) }
            )
        case let .needsAccess(computer):
            FrameStateBlock(
                systemImage: "lock",
                title: "This device can't open conversations on \(computer.name) yet",
                message: "Set up access to \(computer.name) on this device, then try again.",
                primary: FrameStateButton(title: "Set Up Access") { actions.setUpAccess(computer) }
            )
        case let .keyMissing(name):
            FrameStateBlock(
                systemImage: "key",
                title: "The key for \(name) is missing on this device",
                message: "The key this device signs in to \(name) with is gone or can't be read. Add it again in Settings.",
                primary: FrameStateButton(title: "Fix in Settings") { actions.openSettings(.access) }
            )
        case let .unreachable(name):
            FrameStateBlock(
                systemImage: "wifi.exclamationmark",
                title: "Can't reach \(name)",
                message: "Check it's awake and on Tailscale.",
                primary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .signInFailed(name):
            FrameStateBlock(
                systemImage: "lock",
                title: "This device couldn't sign in to \(name).",
                message: "Check this device's access to \(name) in Settings.",
                primary: FrameStateButton(title: "Fix in Settings") { actions.openSettings(.access) },
                secondary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .hostKeyChanged(name):
            FrameStateBlock(
                systemImage: "exclamationmark.shield",
                iconTint: DS.accent,
                title: "\(name)'s identity changed since this device last connected.",
                message: "If \(name) was reinstalled or replaced, review its access and choose Forget Host Key, then try again. If not, don't connect.",
                primary: FrameStateButton(title: "Review \(name)") { actions.editAccess(name) }
            )
        case let .terminalFailed(name):
            FrameStateBlock(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't open a terminal on \(name)",
                primary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .helpersMissing(name):
            let command = ResumeCommand.install(hubURL: TodoHubSettings.baseURLString)
            FrameStateBlock(
                systemImage: "exclamationmark.triangle",
                iconTint: DS.accent,
                title: "\(name) needs the AI Session helpers",
                message: "Run this on \(name), from a checkout of ai-session-remote, then try again:",
                // Shown on two lines like a shell continuation; copied as one.
                code: command.replacingOccurrences(of: " --token", with: " \\\n  --token"),
                primary: FrameStateButton(title: "Copy Command") { actions.copy(command) },
                secondary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .toolMissing(name):
            let toolName = RemoteConversationPicker.toolName(tool ?? "claude")
            FrameStateBlock(
                systemImage: "exclamationmark.triangle",
                iconTint: DS.accent,
                title: "\(toolName) isn't installed on \(name)",
                message: "Install it on \(name), then try again.",
                primary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .folderMissing(name, folder):
            FrameStateBlock(
                systemImage: "folder.badge.questionmark",
                title: "The folder \(folder) doesn't exist on \(name)",
                message: "Conversations for this todo start in that folder. Pick another one, or create it on \(name) and try again.",
                primary: FrameStateButton(title: "Change Folder") { actions.openSettings(.sections(nil)) },
                secondary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        case let .conversationNotFound(name):
            FrameStateBlock(
                systemImage: "questionmark.bubble",
                title: "This conversation no longer exists on \(name)",
                primary: FrameStateButton(title: "Unlink", action: actions.unlink),
                secondary: resumeCommand.map { command in
                    FrameStateButton(title: "Copy Resume Command") { actions.copy(command) }
                }
            )
        case .tokenRejected:
            FrameStateBlock(
                systemImage: "key",
                title: "The server didn't accept the API token",
                message: "Check the token in Settings, then try again.",
                primary: FrameStateButton(title: "Open Settings") { actions.openSettings(.server) }
            )
        case let .hub(message):
            FrameStateBlock(
                systemImage: "exclamationmark.icloud",
                title: "Couldn't open the conversation",
                message: message,
                primary: FrameStateButton(title: "Try Again", action: actions.retry)
            )
        }
    }
}
