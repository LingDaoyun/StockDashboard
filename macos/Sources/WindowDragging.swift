import AppKit
import SwiftUI

struct WindowDraggingArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
