import SwiftUI

/// A value shown for a moment and then cleared: the Copied, Muted and Added toasts. Showing
/// it again restarts the timer, so a newer toast is never cut short by an older one's.
@MainActor
@Observable
final class TransientValue<Value: Equatable> {
    private(set) var value: Value?
    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private var task: Task<Void, Never>?

    init(for duration: Duration) {
        self.duration = duration
    }

    func show(_ newValue: Value) {
        task?.cancel()
        withAnimation { value = newValue }
        let duration = duration
        task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation { self?.value = nil }
        }
    }

    func clear() {
        task?.cancel()
        withAnimation { value = nil }
    }
}

extension Duration {
    /// A toast that only confirms: long enough to read a word or two.
    static var toast: Duration { .seconds(2) }
    /// A toast with Undo: long enough to reach it.
    static var toastWithUndo: Duration { .seconds(4) }
}
