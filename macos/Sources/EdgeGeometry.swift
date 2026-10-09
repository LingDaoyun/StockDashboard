import AppKit

enum DesktopEdge: String, CaseIterable {
    case left, right, top, bottom
}

enum EdgeGeometry {
    static func nearestEdge(to frame: NSRect, in visible: NSRect, threshold: CGFloat = 12) -> DesktopEdge? {
        guard frame.intersects(visible) else { return nil }
        let distances: [(DesktopEdge, CGFloat)] = [
            (.left, max(0, frame.minX - visible.minX)),
            (.right, max(0, visible.maxX - frame.maxX)),
            (.top, max(0, visible.maxY - frame.maxY)),
            (.bottom, max(0, frame.minY - visible.minY))
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else { return nil }
        return nearest.0
    }

    static func expandedFrame(_ frame: NSRect, at edge: DesktopEdge, in visible: NSRect) -> NSRect {
        var result = clamp(frame, in: visible)
        switch edge {
        case .left: result.origin.x = visible.minX
        case .right: result.origin.x = visible.maxX - frame.width
        case .top: result.origin.y = visible.maxY - frame.height
        case .bottom: result.origin.y = visible.minY
        }
        return result
    }

    static func collapsedFrame(from expanded: NSRect, at edge: DesktopEdge, strip: CGFloat = 10) -> NSRect {
        var result = expanded
        switch edge {
        case .left: result.origin.x -= max(0, expanded.width - max(0, strip))
        case .right: result.origin.x += max(0, expanded.width - max(0, strip))
        case .top: result.origin.y += max(0, expanded.height - max(0, strip))
        case .bottom: result.origin.y -= max(0, expanded.height - max(0, strip))
        }
        return result
    }

    static func handleFrame(for expanded: NSRect, at edge: DesktopEdge, in visible: NSRect,
                            thickness: CGFloat = 10, length: CGFloat = 74) -> NSRect {
        let vertical = edge == .left || edge == .right
        let width = min(max(0, vertical ? thickness : length), visible.width)
        let height = min(max(0, vertical ? length : thickness), visible.height)
        var result = clamp(NSRect(x: expanded.midX - width / 2, y: expanded.midY - height / 2,
                                  width: width, height: height), in: visible)
        switch edge {
        case .left: result.origin.x = visible.minX
        case .right: result.origin.x = visible.maxX - width
        case .top: result.origin.y = visible.maxY - height
        case .bottom: result.origin.y = visible.minY
        }
        return result
    }

    static func clamp(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        result.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return result
    }
}
