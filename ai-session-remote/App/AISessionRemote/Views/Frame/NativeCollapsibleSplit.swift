#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns the divider and pane frames, including dragging out of the collapsed header.
struct NativeCollapsibleSplit<Top: View, Bottom: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    var isVisible: Bool
    var onVisibilityChange: (Bool) -> Void
    var isVertical = false
    var collapsedSize: CGFloat = 30
    var minimumExpandedSize: CGFloat = 130
    var initialExpandedSize: CGFloat = 270
    var minimumLeadingSize: CGFloat = 100
    var top: Top
    var bottom: Bottom

    func makeNSView(context: Context) -> SplitView {
        let view = SplitView()
        view.isVertical = isVertical
        view.collapsedSize = collapsedSize
        view.minimumExpandedSize = minimumExpandedSize
        view.expandedSize = initialExpandedSize
        view.minimumLeadingSize = minimumLeadingSize
        view.dividerStyle = .thin
        view.delegate = view
        let topHost = NSHostingView(rootView: AnyView(top.environment(\.self, environment)))
        let bottomHost = NSHostingView(rootView: AnyView(bottom.environment(\.self, environment)))
        topHost.sizingOptions = []
        bottomHost.sizingOptions = []
        view.addArrangedSubview(topHost)
        view.addArrangedSubview(bottomHost)
        view.visible = isVisible
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ view: SplitView, context: Context) {
        (view.arrangedSubviews[0] as? NSHostingView<AnyView>)?.rootView = AnyView(top.environment(\.self, environment))
        (view.arrangedSubviews[1] as? NSHostingView<AnyView>)?.rootView = AnyView(bottom.environment(\.self, environment))
        view.onVisibilityChange = onVisibilityChange
        if view.visible != isVisible {
            view.visible = isVisible
            view.placePanes()
        }
    }

    final class SplitView: NSSplitView, NSSplitViewDelegate {
        var visible = false
        var onVisibilityChange: ((Bool) -> Void)?
        var expandedSize: CGFloat = 270
        var collapsedSize: CGFloat = 30
        var minimumExpandedSize: CGFloat = 130
        var minimumLeadingSize: CGFloat = 100
        private var length: CGFloat { isVertical ? bounds.width : bounds.height }
        private var placing = false
        override var isFlipped: Bool { true }

        func placePanes() {
            guard arrangedSubviews.count == 2 else { return }
            placing = true
            let available = max(0, length - dividerThickness)
            let trailing = min(visible ? max(minimumExpandedSize, expandedSize) : collapsedSize,
                               max(collapsedSize, available - minimumLeadingSize))
            let leading = max(0, available - trailing)
            if isVertical {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: leading, height: bounds.height)
                arrangedSubviews[1].frame = NSRect(x: leading + dividerThickness, y: 0,
                                                 width: trailing, height: bounds.height)
            } else {
                arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: leading)
                arrangedSubviews[1].frame = NSRect(x: 0, y: leading + dividerThickness,
                                                 width: bounds.width, height: trailing)
            }
            placing = false
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            placePanes()
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat { min(minimumLeadingSize, max(0, length - collapsedSize - dividerThickness)) }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat { max(0, length - collapsedSize - dividerThickness) }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !placing, arrangedSubviews.count == 2 else { return }
            let size = isVertical ? arrangedSubviews[1].frame.width : arrangedSubviews[1].frame.height
            let next = size > 40
            if next { expandedSize = size }
            guard next != visible else { return }
            visible = next
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible == next else { return }
                if !next, self.collapsedSize == 0 { self.placePanes() }
                self.onVisibilityChange?(next)
            }
        }
    }
}
#endif
