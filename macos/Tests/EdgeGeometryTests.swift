import AppKit

@main
struct EdgeGeometryTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        let visible = NSRect(x: 0, y: 48, width: 1440, height: 828)
        let size = NSSize(width: 360, height: 280)
        let middle = NSRect(origin: NSPoint(x: 500, y: 300), size: size)
        check(EdgeGeometry.nearestEdge(to: middle, in: visible) == nil, "远离四边时不收起")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 12, y: 200, width: 360, height: 280), in: visible) == .left, "12点内吸附左边")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 13, y: 200, width: 360, height: 280), in: visible) == nil, "超过阈值不吸附")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 1071, y: 200, width: 360, height: 280), in: visible) == .right, "右边距离按窗口右沿计算")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 400, y: 590, width: 360, height: 280), in: visible) == .top, "AppKit上沿取maxY")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 400, y: 54, width: 360, height: 280), in: visible) == .bottom, "下沿取minY")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: -20, y: 300, width: 360, height: 280), in: visible) == .left, "越过左边但仍可见时能吸附")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 1200, y: 300, width: 360, height: 280), in: visible) == .right, "越过右边距离按0")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 5, y: 588, width: 360, height: 280), in: visible) == .left, "角落选择更近的边")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 7, y: 593, width: 360, height: 280), in: visible) == .top, "角落上沿距离更小时选择上沿")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: 5, y: 591, width: 360, height: 280), in: visible) == .left, "角落同距选择稳定")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: -500, y: 300, width: 360, height: 280), in: visible) == nil, "完全离开该屏幕不能吸附")
        check(EdgeGeometry.nearestEdge(to: NSRect(x: -360, y: 300, width: 360, height: 280), in: visible) == nil, "仅接触屏幕边界不算相交")

        for edge in DesktopEdge.allCases {
            let expanded = EdgeGeometry.expandedFrame(middle, at: edge, in: visible)
            check(expanded.size == size, "展开保留窗口尺寸")
            check(visible.contains(expanded), "正常窗口展开完全可见")
            let collapsed = EdgeGeometry.collapsedFrame(from: expanded, at: edge)
            let intersection = collapsed.intersection(visible)
            switch edge {
            case .left:
                check(expanded.minX == visible.minX, "展开贴左边")
                check(collapsed.maxX == visible.minX + 10, "左边滑出仅剩10点")
                check(intersection.width == 10 && intersection.height == size.height, "左边动画终点可见条正确")
            case .right:
                check(expanded.maxX == visible.maxX, "展开贴右边")
                check(collapsed.minX == visible.maxX - 10, "右边滑出仅剩10点")
                check(intersection.width == 10 && intersection.height == size.height, "右边动画终点可见条正确")
            case .top:
                check(expanded.maxY == visible.maxY, "展开贴上边")
                check(collapsed.minY == visible.maxY - 10, "上边向正Y方向滑出")
                check(intersection.height == 10 && intersection.width == size.width, "上边动画终点可见条正确")
            case .bottom:
                check(expanded.minY == visible.minY, "展开贴下边")
                check(collapsed.maxY == visible.minY + 10, "下边向负Y方向滑出")
                check(intersection.height == 10 && intersection.width == size.width, "下边动画终点可见条正确")
            }
            let handle = EdgeGeometry.handleFrame(for: expanded, at: edge, in: visible)
            check(visible.contains(handle), "提示条位于visibleFrame内避开菜单栏和Dock")
            switch edge {
            case .left, .right:
                check(handle.size == NSSize(width: 10, height: 74), "左右提示条为竖条")
                check(handle.midY == expanded.midY, "左右提示条在窗口中间")
                check(edge == .left ? handle.minX == visible.minX : handle.maxX == visible.maxX, "左右提示条贴可见边缘")
            case .top, .bottom:
                check(handle.size == NSSize(width: 74, height: 10), "上下提示条为横条")
                check(handle.midX == expanded.midX, "上下提示条在窗口中间")
                check(edge == .top ? handle.maxY == visible.maxY : handle.minY == visible.minY, "上下提示条贴可见边缘")
            }
        }

        let secondary = NSRect(x: -1920, y: -120, width: 1920, height: 1080)
        let secondaryStock = NSRect(x: -1908, y: 400, width: 360, height: 280)
        check(EdgeGeometry.nearestEdge(to: secondaryStock, in: secondary) == .left, "负原点副屏边缘检测")
        let secondaryExpanded = EdgeGeometry.expandedFrame(secondaryStock, at: .right, in: secondary)
        check(secondaryExpanded.maxX == 0, "负原点副屏右沿为0")
        check(EdgeGeometry.collapsedFrame(from: secondaryExpanded, at: .right).minX == -10, "副屏滑出正确")
        check(secondary.contains(EdgeGeometry.handleFrame(for: secondaryExpanded, at: .right, in: secondary)), "副屏提示条仍在该屏内")
        check(EdgeGeometry.clamp(NSRect(x: -2500, y: 1300, width: 360, height: 280), in: secondary) == NSRect(x: -1920, y: 680, width: 360, height: 280), "跨屏窗口夹回目标副屏")
        let outside = NSRect(x: 1300, y: 900, width: 360, height: 280)
        check(EdgeGeometry.expandedFrame(outside, at: .left, in: visible) == NSRect(x: 0, y: 596, width: 360, height: 280), "吸附时垂直方向不越界")
        check(EdgeGeometry.expandedFrame(outside, at: .bottom, in: visible) == NSRect(x: 1080, y: 48, width: 360, height: 280), "吸附时水平方向不越界")
        let oversized = NSRect(x: -500, y: -500, width: 1600, height: 1000)
        let clampedOversized = EdgeGeometry.clamp(oversized, in: visible)
        check(clampedOversized.size == oversized.size, "超大窗口保持尺寸")
        check(clampedOversized.origin == visible.origin, "超大窗口露出最大可见区域")
        check(clampedOversized.intersection(visible) == visible, "超大窗口覆盖整个可见桌面")
        let smallVisible = NSRect(x: -100, y: 20, width: 40, height: 30)
        for edge in DesktopEdge.allCases {
            let handle = EdgeGeometry.handleFrame(for: oversized, at: edge, in: smallVisible)
            check(smallVisible.contains(handle), "提示条自动缩短以适应小可见区域")
        }
        check(EdgeGeometry.collapsedFrame(from: middle, at: .left, strip: 500) == middle, "过大保留条不能反向移动窗口")
        print("PASS: \(count) edge geometry assertions")
    }
}
