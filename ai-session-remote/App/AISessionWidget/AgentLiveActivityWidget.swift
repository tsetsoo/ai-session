#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import AISessionCore
import SwiftUI
import WidgetKit

public struct AgentLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentSessionAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .widgetURL(context.attributes.conversationURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: Self.toolIcon(context.attributes.tool))
                            .font(.headline)
                            .foregroundStyle(context.state.isWaiting ? .orange : .blue)
                        Text(context.attributes.tool.capitalized)
                            .font(.headline.weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.status == "idle" {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                    } else if context.state.status != "closed" {
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.todoTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        if context.state.isWaiting {
                            Text(context.state.promptQuestion ?? "Waiting for your input")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            PermissionButtons(context: context)
                        } else if let step = context.state.finishedMessage ?? context.state.currentStep, !step.isEmpty {
                            Text(step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: Self.toolIcon(context.attributes.tool))
                    .foregroundStyle(context.state.isWaiting ? .orange : .blue)
            } compactTrailing: {
                if context.state.isWaiting {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if context.state.status == "idle" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if context.state.status != "closed" {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                        .frame(minWidth: 32)
                }
            } minimal: {
                Image(systemName: Self.toolIcon(context.attributes.tool))
                    .foregroundStyle(context.state.isWaiting ? .orange : .blue)
            }
            .widgetURL(context.attributes.conversationURL)
        }
    }

    fileprivate static func toolIcon(_ tool: String) -> String {
        switch tool {
        case "claude": return "cpu"
        case "codex": return "terminal"
        case "cursor": return "cursorarrow.rays"
        default: return "terminal.fill"
        }
    }
}

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<AgentSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: AgentLiveActivityWidget.toolIcon(context.attributes.tool))
                        .foregroundStyle(context.state.isWaiting ? .orange : .blue)
                    Text(context.attributes.tool.capitalized)
                        .font(.subheadline.weight(.semibold))
                    if let model = context.attributes.model, !model.isEmpty {
                        Text("(\(model))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.state.status == "idle" {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else if context.state.status != "closed" {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(context.attributes.todoTitle)
                .font(.headline)
                .lineLimit(1)
            if !context.attributes.projectName.isEmpty {
                Text(context.attributes.projectName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if context.state.isWaiting {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(context.state.canDecide == true ? "Needs Permission" : "Needs You")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                    if let prompt = context.state.promptQuestion, !prompt.isEmpty {
                        Text(prompt)
                            .font(.caption.monospaced())
                            .padding(6)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    PermissionButtons(context: context)
                }
            } else if let step = context.state.finishedMessage ?? context.state.currentStep, !step.isEmpty {
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
    }
}
private struct PermissionButtons: View {
    let context: ActivityViewContext<AgentSessionAttributes>

    var body: some View {
        if context.state.canDecide == true, let revision = context.state.statusRevision {
            HStack {
                Button(intent: decision(revision: revision, reject: true)) { Text("Reject") }
                    .buttonStyle(.bordered)
                Button(intent: decision(revision: revision, reject: false)) {
                    Label("Allow", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func decision(revision: Int, reject: Bool) -> ApprovePromptIntent {
        ApprovePromptIntent(conversationId: context.attributes.conversationId, statusRevision: revision, reject: reject)
    }

}
#endif
