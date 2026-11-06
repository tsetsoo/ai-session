import AISessionCore
import SwiftUI

/// The conversation's pull request (GitHub) or merge request (GitLab): "PR #123 · merged".
/// Opens it in the browser. The runner on the conversation's computer finds it once the branch
/// is pushed (`gh` / `glab`), so it can trail a push by up to ten minutes.
struct PullRequestChip: View {
    var pullRequest: PullRequestLink
    /// The phone's toolbar is narrow: "#123" with the state's glyph only.
    var compact = false

    var body: some View {
        if let link = pullRequest.link {
            Link(destination: link) {
                HStack(spacing: DS.spacing.xs) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                    Text(compact ? (pullRequest.number.map { "#\($0)" } ?? kindName) : pullRequest.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, DS.spacing.xs)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help("Open \(pullRequest.title) in the browser")
            #endif
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens it in the browser")
        }
    }

    private var kindName: String { pullRequest.isMergeRequest ? "MR" : "PR" }

    private var symbol: String {
        switch pullRequest.state {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark.circle"
        default: return "arrow.triangle.pull"
        }
    }

    private var tint: Color {
        switch pullRequest.state {
        case "merged": return .purple
        case "closed": return .secondary
        default: return .green
        }
    }

    private var accessibilityText: String {
        let kind = pullRequest.isMergeRequest ? "Merge request" : "Pull request"
        return [kind, pullRequest.number.map { "\($0)" }, pullRequest.state].compactMap { $0 }.joined(separator: " ")
    }
}
