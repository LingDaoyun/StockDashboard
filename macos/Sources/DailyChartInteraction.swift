import AppKit
import SwiftUI

/// Mouse handling is confined to this chart's view; no application-wide event monitor.
struct DailyChartInteraction: NSViewRepresentable {
    let isBrowsing: Bool
    let tooltip: String
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint) -> Void
    let onDragStart: () -> Void
    let onPan: (CGFloat) -> Void
    let onZoom: (Double, CGPoint) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MouseView {
        MouseView()
    }

    func updateNSView(_ view: MouseView, context: Context) {
        let changedTool = view.handlers?.isBrowsing != isBrowsing
        view.handlers = self
        if view.toolTip != tooltip { view.toolTip = tooltip }
        if changedTool { view.window?.invalidateCursorRects(for: view) }
    }

    final class MouseView: NSView {
        var handlers: DailyChartInteraction?
        private var tracking: NSTrackingArea?
        private var mouseDownPoint: CGPoint?
        private var previousDragPoint: CGPoint?
        private var dragged = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: handlers?.isBrowsing == true ? .openHand : .crosshair)
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

        override func mouseMoved(with event: NSEvent) {
            handlers?.onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) { handlers?.onHover(nil) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            mouseDownPoint = point
            previousDragPoint = point
            dragged = false
            handlers?.onDragStart()
        }

        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let start = mouseDownPoint, hypot(point.x - start.x, point.y - start.y) > 3 {
                dragged = true
            }
            if handlers?.isBrowsing == true, let previousDragPoint {
                handlers?.onPan(point.x - previousDragPoint.x)
                NSCursor.closedHand.set()
            }
            previousDragPoint = point
            handlers?.onHover(point)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if !dragged { handlers?.onClick(point) }
            mouseDownPoint = nil
            previousDragPoint = nil
            (handlers?.isBrowsing == true ? NSCursor.openHand : NSCursor.crosshair).set()
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.scrollingDeltaY != 0 else { return }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.12
            let factor = exp(-Double(event.scrollingDeltaY) * sensitivity)
            handlers?.onZoom(min(2, max(0.5, factor)), convert(event.locationInWindow, from: nil))
        }

        override func magnify(with event: NSEvent) {
            handlers?.onZoom(exp(-Double(event.magnification)), convert(event.locationInWindow, from: nil))
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { handlers?.onCancel() }
            else { super.keyDown(with: event) }
        }

        override func cancelOperation(_ sender: Any?) { handlers?.onCancel() }
    }
}
