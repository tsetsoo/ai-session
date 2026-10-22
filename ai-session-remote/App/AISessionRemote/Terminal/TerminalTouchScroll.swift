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

/// Where wheel events are sent: the cell where the drag began, kept off the first and last rows
/// so a tmux status line (top or bottom) never takes them. The whole drag and its glide scroll
/// the pane the finger first touched.
struct TerminalWheelAnchor: Equatable {
    let col: Int
    let row: Int

    init(point: CGPoint, size: CGSize, cols: Int, rows: Int) {
        let cellWidth = cols > 0 ? size.width / CGFloat(cols) : 0
        let cellHeight = rows > 0 ? size.height / CGFloat(rows) : 0
        let col = cellWidth > 0 ? Int(point.x / cellWidth) : 0
        let row = cellHeight > 0 ? Int(point.y / cellHeight) : 0
        self.col = min(max(col, 0), max(cols - 1, 0))
        let lowest = rows > 2 ? 1 : 0
        let highest = rows > 2 ? rows - 2 : max(rows - 1, 0)
        self.row = min(max(row, lowest), highest)
    }
}

#if os(iOS)
/// A terminal that scrolls a tmux conversation with the finger.
///
/// With tmux mouse mode on, SwiftTerm turns a drag into a held mouse button, so tmux starts a
/// selection and nothing scrolls. Here a vertical finger drag sends wheel events instead, one
/// line per line of travel, and keeps gliding after a flick. They carry the Meta bit, which the
/// host's `tmux.conf` binds to scroll one line at a time (the plain wheel moves five).
/// A trackpad or mouse on iPad keeps SwiftTerm's drag, so it still selects in tmux.
/// Without mouse reporting the view scrolls its own buffer as usual.
final class TouchScrollTerminalView: TerminalView {
    private lazy var scrollPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        return pan
    }()
    private var scroll = TerminalTouchScroll(lineHeight: 0)
    private var anchor: TerminalWheelAnchor?
    private var momentum: TerminalScrollMomentum?
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    /// The touch that caught a glide only stops it, as in any scroll view: no click.
    private var touchStoppedGlide = false

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

    /// SwiftTerm adds a pan here that reports a drag as a held button. A finger scrolls with
    /// `scrollPan` instead, so that pan is left to the pointer.
    override func mouseModeChanged(source: Terminal) {
        let before = Set((gestureRecognizers ?? []).map(ObjectIdentifier.init))
        super.mouseModeChanged(source: source)
        if let added = gestureRecognizers?.first(where: {
            $0 is UIPanGestureRecognizer && !before.contains(ObjectIdentifier($0))
        }) {
            added.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStoppedGlide = displayLink != nil
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    /// Leaving the window or the front (another conversation is shown) ends a glide, so it can't
    /// scroll a session this view no longer shows.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopMomentum() }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { stopMomentum() } }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if touchStoppedGlide, gestureRecognizer is UITapGestureRecognizer { return false }
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
            let terminal = getTerminal()
            // The touch point less the translation is where the finger first came down.
            let translation = pan.translation(in: self)
            let location = pan.location(in: self)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y - bounds.minY)
            anchor = TerminalWheelAnchor(point: start, size: bounds.size, cols: terminal.cols, rows: terminal.rows)
            scroll = TerminalTouchScroll(lineHeight: lineHeight * CGFloat(linesPerEvent))
        case .changed:
            let dy = pan.translation(in: self).y
            pan.setTranslation(.zero, in: self)
            sendWheel(steps: scroll.steps(forDrag: dy))
        case .ended:
            startMomentum(velocity: pan.velocity(in: self).y)
        default:
            scroll.reset()
        }
    }

    private var lineHeight: CGFloat {
        let rows = getTerminal().rows
        return rows > 0 ? bounds.height / CGFloat(rows) : 0
    }

    /// Lines one event scrolls: one with Meta, five for the plain wheel when the mouse mode
    /// can't carry Meta.
    private var linesPerEvent: Int {
        getTerminal().mouseMode.sendsModifiers() ? 1 : 5
    }

    private func startMomentum(velocity: CGFloat) {
        displayLink?.invalidate()
        momentum = TerminalScrollMomentum(velocity: velocity)
        lastFrame = CACurrentMediaTime()
        // The link holds its target; the proxy keeps it from holding this view.
        let link = CADisplayLink(target: WeakDisplayLinkTarget(self), selector: #selector(WeakDisplayLinkTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func glide(_ link: CADisplayLink) {
        let now = link.timestamp
        let seconds = CGFloat(max(0, now - lastFrame))
        lastFrame = now
        guard let distance = momentum?.advance(by: seconds) else {
            stopMomentum()
            return
        }
        sendWheel(steps: scroll.steps(forDrag: distance))
    }

    private func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        momentum = nil
        scroll.reset()
    }

    /// Wheel up for positive steps, down for negative, at the drag's anchor cell.
    private func sendWheel(steps: Int) {
        guard steps != 0, let anchor else { return }
        let terminal = getTerminal()
        guard terminal.mouseMode != .off else { return }
        let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false, shift: false, meta: true, control: false)
        for _ in 0..<abs(steps) {
            terminal.sendEvent(buttonFlags: flags, x: anchor.col, y: anchor.row)
        }
    }
}

/// Forwards display-link ticks without keeping the view alive.
private final class WeakDisplayLinkTarget {
    weak var view: TouchScrollTerminalView?

    init(_ view: TouchScrollTerminalView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.glide(link)
    }
}
#endif
