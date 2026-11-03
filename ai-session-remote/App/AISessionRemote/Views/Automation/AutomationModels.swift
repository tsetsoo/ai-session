import AISessionCore
import SwiftUI

/// The window's two modes: working with conversations, or with jobs, ideas and activity.
enum AppMode: String, CaseIterable, Identifiable {
    case sessions, automation
    var id: String { rawValue }
    var title: String { self == .sessions ? "Sessions" : "Automation" }
}

/// Automation's sidebar.
enum AutomationItem: String, CaseIterable, Identifiable, Hashable {
    case jobs, ideas, watchers, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .jobs: "Jobs"
        case .ideas: "Ideas"
        case .watchers: "Watchers"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .jobs: "clock.arrow.circlepath"
        case .ideas: "lightbulb"
        case .watchers: "exclamationmark.triangle"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// What the big pane shows under Jobs.
enum JobsPaneTarget: Hashable {
    case limits
    case job(String)
    case new
    case edit(String)

    /// The list row this target highlights.
    var listSelection: String? {
        switch self {
        case .limits: "limits"
        case let .job(id), let .edit(id): id
        case .new: nil
        }
    }
}

/// What the big pane shows under Ideas.
enum IdeasPaneTarget: Hashable {
    case idea(String)
    case new
    case shape
}

/// A small coloured label for a run's state.
struct RunStateChip: View {
    let state: String
    var detail: String?

    var body: some View {
        Text(detail.map { "\(state) · \($0)" } ?? state)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case "done": .green
        case "failed", "missed": .red
        case "waiting", "running", "due": .orange
        default: .secondary
        }
    }
}

/// The mode switch: a segmented control, plus ⌃⌘1 / ⌃⌘2.
struct ModeSwitch: View {
    @Binding var mode: AppMode

    var body: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AppMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .background {
            Group {
                Button("Sessions") { mode = .sessions }.keyboardShortcut("1", modifiers: [.control, .command])
                Button("Automation") { mode = .automation }.keyboardShortcut("2", modifiers: [.control, .command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
