import AppKit
import QuartzCore

class DesktopHoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

private final class EdgeHandleView: DesktopHoverView {
    var edge = DesktopEdge.right { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("行情提示条，鼠标移入展开")
        setAccessibilityIdentifier("edge-reveal-handle")
        toolTip = "鼠标移入展开行情；菜单栏可关闭右侧自动吸附隐藏"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        if edge == .left || edge == .right {
            for (index, character) in ["行", "情"].enumerated() {
                let text = character as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                      y: bounds.midY + (index == 0 ? 1 : -11)), withAttributes: attributes)
            }
        } else {
            let text = "行情" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }

    override func accessibilityPerformPress() -> Bool { onEnter?(); return true }
}

@MainActor
final class EdgeDockController {
    private enum Presentation { case shown, collapsed, manuallyHidden }
    private let panel: NSPanel
    private let defaults: UserDefaults
    private let keepVisible: () -> Bool
    private let handlePanel: NSPanel
    private let handleView: EdgeHandleView
    private var edge: DesktopEdge?
    private var expanded: NSRect?
    private var presentation = Presentation.shown
    private var timer: Timer?
    private var changingFrame = false
    private var animating = false
    private var animationGeneration = 0
    private var enabled: Bool

    init(panel: NSPanel, surface: DesktopHoverView, defaults: UserDefaults, enabled: Bool, keepVisible: @escaping () -> Bool) {
        self.panel = panel
        self.defaults = defaults
        self.keepVisible = keepVisible
        self.enabled = enabled
        handleView = EdgeHandleView(frame: .zero)
        handlePanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        handlePanel.title = "行情提示条"
        handlePanel.isReleasedWhenClosed = false
        handlePanel.isOpaque = false
        handlePanel.backgroundColor = .clear
        handlePanel.ignoresMouseEvents = false
        handlePanel.hasShadow = false
        handlePanel.hidesOnDeactivate = false
        handlePanel.level = .floating
        handlePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        handlePanel.contentView = handleView
        surface.onEnter = { [weak self] in
            guard let self, self.edge != nil else { return }
            self.cancelTimer()
        }
        surface.onExit = { [weak self] in self?.scheduleCollapse() }
        handleView.onEnter = { [weak self] in self?.reveal() }
        handleView.onExit = { [weak self] in self?.scheduleCollapse() }
    }

    func restore() { scheduleDock() }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        cancelTimer()
        cancelAnimation()
        if value { scheduleDock() }
        else {
            let reference = expanded ?? panel.frame
            let frame = EdgeGeometry.clamp(reference, in: visibleFrame(for: reference))
            edge = nil
            expanded = nil
            changeFrame(frame)
            handlePanel.orderOut(nil)
            if presentation != .manuallyHidden {
                presentation = .shown
                panel.orderFrontRegardless()
            }
            savePosition(frame)
        }
    }

    func userMovedWindow() {
        guard !changingFrame, !animating else { return }
        cancelTimer()
        edge = nil
        expanded = nil
        presentation = .shown
        handlePanel.orderOut(nil)
        savePosition(panel.frame)
        scheduleDock()
    }

    func resize(to size: NSSize) {
        guard (expanded ?? panel.frame).size != size else { return }
        cancelAnimation()
        var frame = expanded ?? panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        let visible = visibleFrame(for: frame)
        if let edge {
            frame = EdgeGeometry.expandedFrame(frame, at: edge, in: visible)
            expanded = frame
            updateHandle(frame, edge: edge, visible: visible)
        } else { frame = EdgeGeometry.clamp(frame, in: visible) }
        changeFrame(frame)
        if presentation != .shown { panel.orderOut(nil) }
        savePosition(frame)
        if presentation == .collapsed, handlePanel.frame.contains(NSEvent.mouseLocation) { reveal() }
        else if presentation == .shown, !pointerInside() { scheduleCollapse() }
    }

    func show() {
        cancelTimer()
        let wasCollapsed = presentation == .collapsed
        presentation = .shown
        let visible = visibleFrame(for: expanded ?? panel.frame)
        var target = EdgeGeometry.clamp(expanded ?? panel.frame, in: visible)
        if enabled {
            edge = .right
            target = EdgeGeometry.expandedFrame(target, at: .right, in: visible)
            expanded = target
            updateHandle(target, edge: .right, visible: visible)
        }
        cancelAnimation()
        if wasCollapsed, let edge { changeFrame(EdgeGeometry.collapsedFrame(from: target, at: edge, strip: 0)) }
        else { changeFrame(target) }
        panel.orderFrontRegardless()
        handlePanel.orderOut(nil)
        if wasCollapsed {
            animate(to: target) { [weak self] in
                guard let self else { return }
                if !self.pointerInside() { self.scheduleCollapse() }
            }
        } else if enabled, !pointerInside() { scheduleCollapse() }
        savePosition(target)
    }

    func hide() {
        cancelTimer()
        cancelAnimation()
        presentation = .manuallyHidden
        panel.orderOut(nil)
        handlePanel.orderOut(nil)
    }

    func stop() { cancelTimer(); cancelAnimation(); handlePanel.orderOut(nil) }

    private func scheduleDock() {
        guard enabled, presentation == .shown else { return }
        schedule(after: 0.2) { [weak self] in
            guard let self, self.enabled, self.presentation == .shown else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleDock(); return }
            let visible = self.visibleFrame(for: self.panel.frame)
            let edge = DesktopEdge.right
            let target = EdgeGeometry.expandedFrame(self.panel.frame, at: edge, in: visible)
            self.edge = edge
            self.expanded = target
            self.changeFrame(target)
            self.savePosition(target)
            self.updateHandle(target, edge: edge, visible: visible)
            self.collapse()
        }
    }

    private func reveal() {
        cancelTimer()
        guard enabled, presentation == .collapsed, !animating else { return }
        show()
    }

    private func scheduleCollapse() {
        guard enabled, edge != nil, presentation == .shown else { return }
        schedule(after: 0.6) { [weak self] in
            guard let self, self.enabled, self.presentation == .shown else { return }
            if self.keepVisible() || NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleCollapse(); return }
            if !self.pointerInside() { self.collapse() }
        }
    }

    private func collapse() {
        guard enabled, let edge, let expanded, presentation == .shown, !animating else { return }
        if keepVisible() { scheduleCollapse(); return }
        cancelTimer()
        presentation = .collapsed
        updateHandle(expanded, edge: edge, visible: visibleFrame(for: expanded))
        handlePanel.orderFrontRegardless()
        animate(to: EdgeGeometry.collapsedFrame(from: expanded, at: edge, strip: 0)) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            if self.handlePanel.frame.contains(NSEvent.mouseLocation) { self.reveal() }
        }
    }

    private func updateHandle(_ frame: NSRect, edge: DesktopEdge, visible: NSRect) {
        handleView.edge = edge
        handlePanel.setFrame(EdgeGeometry.handleFrame(for: frame, at: edge, in: visible), display: true)
    }

    private func pointerInside() -> Bool {
        let pointer = NSEvent.mouseLocation
        return (panel.isVisible && panel.frame.contains(pointer))
            || (handlePanel.isVisible && handlePanel.frame.contains(pointer))
    }

    private func changeFrame(_ frame: NSRect) {
        changingFrame = true
        panel.setFrame(frame, display: true)
        changingFrame = false
    }

    private func animate(to frame: NSRect, completion: @escaping () -> Void) {
        animationGeneration += 1
        let generation = animationGeneration
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation else { return }
                self.animating = false
                completion()
            }
        }
    }

    private func cancelAnimation() { animationGeneration += 1; animating = false }

    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        cancelTimer()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    private func cancelTimer() { timer?.invalidate(); timer = nil }

    private func savePosition(_ frame: NSRect) {
        defaults.set(frame.minX, forKey: "positionX")
        defaults.set(frame.minY, forKey: "positionY")
    }

    private func visibleFrame(for frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let nearest = screens.max { left, right in
            let a = left.visibleFrame.intersection(frame)
            let b = right.visibleFrame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
        if let nearest, nearest.visibleFrame.intersects(frame) { return nearest.visibleFrame }
        return NSScreen.main?.visibleFrame ?? screens.first?.visibleFrame ?? frame
    }
}
