import CoreGraphics
import SwiftTerm
#if os(iOS)
import UIKit
#endif

/// Turns finger travel into whole wheel steps, one per line of the grid. Positive steps show
/// earlier text (the finger moved down), negative ones later text. What is left of a line
/// carries over to the next drag movement.
struct TerminalTouchScroll {
    var lineHeight: CGFloat
    private var carry: CGFloat = 0

    init(lineHeight: CGFloat) {
        self.lineHeight = lineHeight
    }

    mutating func steps(forDrag dy: CGFloat) -> Int {
        guard lineHeight > 0 else { return 0 }
        carry += dy
        let steps = Int(carry / lineHeight)
        carry -= CGFloat(steps) * lineHeight
        return steps
    }

    mutating func reset() {
        carry = 0
    }
}

/// The glide after a flick, in points: each frame returns how far the text moves, slowing like
/// a `UIScrollView` at its normal deceleration, and nil once it has stopped.
struct TerminalScrollMomentum {
    /// Below this speed (points per second) the glide ends.
    static let stopSpeed: CGFloat = 60
    /// Speed kept per millisecond, as `UIScrollView.DecelerationRate.normal`.
    static let decelerationRate: CGFloat = 0.998

    private(set) var velocity: CGFloat

    init(velocity: CGFloat) {
        self.velocity = velocity
    }

    mutating func advance(by seconds: CGFloat) -> CGFloat? {
        guard abs(velocity) >= Self.stopSpeed else { return nil }
        let distance = velocity * seconds
        velocity *= pow(Self.decelerationRate, seconds * 1000)
        return distance
    }
}

#if os(iOS)
/// A terminal that scrolls a tmux conversation with the finger.
///
/// With tmux mouse mode on, SwiftTerm turns a drag into a held mouse button, so tmux starts a
/// selection and nothing scrolls. Here a vertical drag sends wheel events instead, one line per
/// line of finger travel, and keeps gliding after a flick. They carry the Meta bit, which the
/// host's `tmux.conf` binds to scroll one line at a time (the plain wheel moves five).
/// Without mouse reporting the view scrolls its own buffer as usual.
final class TouchScrollTerminalView: TerminalView {
    private lazy var scrollPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        pan.maximumNumberOfTouches = 1
        return pan
    }()
    private var scroll = TerminalTouchScroll(lineHeight: 0)
    private var momentum: TerminalScrollMomentum?
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(scrollPan)
        // The buffer's own scrolling waits until a drag is known not to be a wheel scroll.
        panGestureRecognizer.require(toFail: scrollPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
    }

    /// SwiftTerm adds a pan here that reports a drag as a held button. The scroll pan replaces it.
    override func mouseModeChanged(source: Terminal) {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A touch catches a glide, as in any scroll view.
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    override func removeFromSuperview() {
        stopMomentum()
        super.removeFromSuperview()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === scrollPan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard allowMouseReporting, getTerminal().mouseMode != .off else { return false }
        let velocity = scrollPan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopMomentum()
            scroll = TerminalTouchScroll(lineHeight: lineHeight)
        case .changed:
            let dy = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            sendWheel(steps: scroll.steps(forDrag: dy), at: pan.location(in: self))
        case .ended:
            startMomentum(velocity: pan.velocity(in: self).y, at: pan.location(in: self))
        default:
            scroll.reset()
        }
    }

    private var lineHeight: CGFloat {
        let rows = getTerminal().rows
        return rows > 0 ? bounds.height / CGFloat(rows) : 0
    }

    private var momentumPoint: CGPoint = .zero
    private var lastFrame: CFTimeInterval = 0

    private func startMomentum(velocity: CGFloat, at point: CGPoint) {
        momentum = TerminalScrollMomentum(velocity: velocity)
        momentumPoint = point
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(glide))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func glide(_ link: CADisplayLink) {
        let now = link.timestamp
        let seconds = CGFloat(max(0, now - lastFrame))
        lastFrame = now
        guard let distance = momentum?.advance(by: seconds) else {
            stopMomentum()
            return
        }
        sendWheel(steps: scroll.steps(forDrag: distance), at: momentumPoint)
    }

    private func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        momentum = nil
        scroll.reset()
    }

    /// Wheel up for positive steps, down for negative, at the cell under `point`.
    private func sendWheel(steps: Int, at point: CGPoint) {
        guard steps != 0 else { return }
        let terminal = getTerminal()
        guard terminal.mouseMode != .off, terminal.cols > 0, terminal.rows > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let col = min(max(Int(point.x / (bounds.width / CGFloat(terminal.cols))), 0), terminal.cols - 1)
        let row = min(max(Int((point.y - contentOffset.y) / lineHeight), 0), terminal.rows - 1)
        let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false, shift: false, meta: true, control: false)
        for _ in 0..<abs(steps) {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
    }
}
#endif
