import AppKit

private struct DailyChartInteractionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
enum DailyChartInteractionTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DailyChartInteractionTestFailure(description: message) }
        checks += 1
    }

    static func main() throws {
        _ = NSApplication.shared
        // Keep the test window hidden; events are delivered directly to the view, never posted.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let view = DailyChartInteraction.MouseView(frame: NSRect(x: 20, y: 40, width: 300, height: 200))
        window.contentView = root
        root.addSubview(view)

        var hovers: [CGPoint?] = []
        var clicks: [CGPoint] = []
        var starts = 0
        var pans: [CGFloat] = []
        var zooms: [(Double, CGPoint)] = []
        var cancellations = 0
        func handlers(browsing: Bool) -> DailyChartInteraction {
            DailyChartInteraction(isBrowsing: browsing, tooltip: "测试图表",
                onHover: { hovers.append($0) }, onClick: { clicks.append($0) },
                onDragStart: { starts += 1 }, onPan: { pans.append($0) },
                onZoom: { zooms.append(($0, $1)) }, onCancel: { cancellations += 1 })
        }
        view.handlers = handlers(browsing: true)
        func mouse(_ type: NSEvent.EventType, x: CGFloat = 70, y: CGFloat = 180,
                   clicks: Int = 1) -> NSEvent {
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     eventNumber: 0, clickCount: clicks, pressure: 0)!
        }

        try check(!window.isVisible, "事件桥测试窗口始终隐藏")
        try check(view.isFlipped && view.acceptsFirstResponder && view.acceptsFirstMouse(for: nil),
                  "图表使用左上坐标并接受首次点击和键盘焦点")
        view.mouseMoved(with: mouse(.mouseMoved))
        try check(hovers.last! == CGPoint(x: 50, y: 60), "窗口坐标转换为图表左上原点坐标")
        view.mouseExited(with: mouse(.mouseExited))
        try check(hovers.last! == nil, "鼠标离开清空悬停位置")
        view.mouseEntered(with: mouse(.mouseEntered, x: 80, y: 160))
        try check(hovers.last! == CGPoint(x: 60, y: 80), "鼠标进入同步转换后的坐标")

        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseUp(with: mouse(.leftMouseUp))
        try check(starts == 1 && clicks == [CGPoint(x: 50, y: 60)] && pans.isEmpty,
                  "单击只触发一次起始和点击回调")
        try check(window.firstResponder === view, "点击后图表取得键盘焦点以接收Esc")
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 90))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 95))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 75))
        view.mouseUp(with: mouse(.leftMouseUp, x: 75))
        try check(pans == [20, 5, -20] && pans.reduce(0, +) == 5,
                  "拖动按相邻事件增量累加，右移为正，左移为负，不重复累计起点距离")
        try check(clicks.count == 1 && starts == 2, "超过阈值的拖动不会再添加单击标记")
        view.handlers = handlers(browsing: false)
        clicks.removeAll()
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseUp(with: mouse(.leftMouseUp))
        view.mouseDown(with: mouse(.leftMouseDown, x: 95, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, x: 95, clicks: 2))
        try check(clicks == [CGPoint(x: 50, y: 60), CGPoint(x: 75, y: 60)],
                  "快速两点画线的clickCount1和2均回调，保留起点和终点")
        let panCount = pans.count
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 100))
        view.mouseUp(with: mouse(.leftMouseUp, x: 100))
        try check(pans.count == panCount && clicks.count == 2,
                  "画图工具不平移，明显拖动也不误当作点选标注")
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 72))
        view.mouseUp(with: mouse(.leftMouseUp, x: 72))
        try check(clicks.last == CGPoint(x: 52, y: 60) && clicks.count == 3,
                  "小于点击阈值的手抖仍可点选标注")

        for delta in [Int32(1), -1, 100, -100, 0] {
            let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0)!
            cgEvent.location = CGPoint(x: 70, y: 180)
            let event = NSEvent(cgEvent: cgEvent)!
            let count = zooms.count
            view.scrollWheel(with: event)
            if delta == 0 {
                try check(zooms.count == count, "零垂直滚动不触发缩放")
            } else {
                try check(zooms.count == count + 1, "每次有效滚轮事件触发一次缩放")
                let zoom = zooms.last!
                try check(delta > 0 ? zoom.0 < 1 : zoom.0 > 1,
                          "向上滚动减少可见根数以放大，向下滚动增加根数以缩小")
                try check((0.5...2).contains(zoom.0), "极大滚轮位移的单步缩放比例保持有界")
                try check(zoom.1 == view.convert(event.locationInWindow, from: nil),
                          "缩放锚点使用同一个图表局部坐标系")
            }
        }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        try check(cancellations == 1, "Esc取消正在绘制的标注")
        view.cancelOperation(nil)
        try check(cancellations == 2, "AppKit取消操作也传递到图表")
        try check(!window.isVisible, "完整事件测试没有显示窗口或驱动用户应用")
        print("PASS: \(checks) daily chart interaction assertions")
    }
}
