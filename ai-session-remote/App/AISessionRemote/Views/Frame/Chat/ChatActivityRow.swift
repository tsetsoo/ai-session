#if os(iOS)
import AISessionCore
import SwiftUI

/// The agent's steps between two messages, collapsed to one summary line. Tap to list each
/// step. The newest row stays open while the agent is working, under "Working…".
struct ChatActivityRow: View {
    let steps: [ConversationMessage]
    let summary: String
    /// The agent is busy and this is the latest row.
    let isLive: Bool
    @State private var expanded = false

    private var isOpen: Bool { expanded || isLive }

    static func line(for step: ConversationMessage) -> (icon: String, verb: String, target: String) {
        let target = step.target ?? ""
        switch step.kind ?? .other {
        case .read: return ("doc.text", "Read", target)
        case .edit: return ("pencil", "Edited", target)
        case .run: return ("terminal", "Ran", target)
        case .search: return ("magnifyingglass", "Searched for", target)
        case .other: return ("gearshape", "", target)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(summary).font(.footnote.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLive)
            .accessibilityHint(isOpen ? "Hides the steps" : "Shows each step")

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        let line = Self.line(for: step)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: line.icon).frame(width: 16)
                            if !line.verb.isEmpty { Text(line.verb) }
                            Text(line.target).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DS.chipFill, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Today 14:02", "Yesterday 09:10", or a date for older messages.
struct ChatTimestamp: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private var label: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// "Working…" with a pulsing dot, under the live activity row.
struct ChatWorkingLine: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(DS.accentSolid).frame(width: 7, height: 7).opacity(pulse ? 1 : 0.3)
            Text("Working…").font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keeps the newest text in view while the user is at the bottom, and offers ↓ when they
/// aren't. iOS 18 reads the real scroll position; iOS 17 falls back to the end marker.
struct ChatFollowBottom: ViewModifier {
    @Binding var follow: ChatFollow
    let proxy: ScrollViewProxy
    /// Changes whenever the content does.
    let contentVersion: Int

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            // Start at the end only. The one-argument form also anchors size changes, which
            // would slide text the user scrolled up to read.
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .modifier(ChatFollowBottomGeometry(follow: $follow))
        } else {
            content
                .defaultScrollAnchor(.bottom)
                .onChange(of: contentVersion) { _, _ in
                    if follow.followsNewContent { proxy.scrollTo(ChatFollowBottom.endID, anchor: .bottom) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    if follow.followsNewContent { proxy.scrollTo(ChatFollowBottom.endID, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if follow.showsJumpButton {
                        ChatJumpButton {
                            follow.jumpToLatest()
                            withAnimation { proxy.scrollTo(ChatFollowBottom.endID, anchor: .bottom) }
                        }
                    }
                }
        }
    }

    static let endID = "chat-end"
    static var usesGeometry: Bool {
        if #available(iOS 18, *) { return true }
        return false
    }
}

@available(iOS 18, *)
private struct ChatFollowBottomGeometry: ViewModifier {
    @Binding var follow: ChatFollow
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var userScrolling = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Double.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.bottom
                    - (geometry.contentOffset.y + geometry.containerSize.height)
            } action: { _, distance in
                if userScrolling { follow.userScrolled(distanceFromBottom: distance) }
            }
            .onScrollGeometryChange(for: Double.self) { $0.contentSize.height } action: { _, _ in
                // Lazy rows are measured as they appear, so keep going to the end while pinned.
                if follow.followsNewContent, !userScrolling { position.scrollTo(edge: .bottom) }
            }
            .onScrollGeometryChange(for: Double.self) { $0.containerSize.height } action: { _, _ in
                // The keyboard shrank or grew the view: keep the newest message in sight.
                if follow.followsNewContent, !userScrolling { position.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if follow.showsJumpButton {
                    ChatJumpButton {
                        follow.jumpToLatest()
                        withAnimation { position.scrollTo(edge: .bottom) }
                    }
                }
            }
    }
}

private struct ChatJumpButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .accessibilityLabel("Latest message")
        .padding(12)
    }
}
#endif
