import AppKit

private final class QuietPanel: NSPanel {
    private var recordedVisible = false
    override var isVisible: Bool { recordedVisible }
    override func orderFrontRegardless() { recordedVisible = true }
    override func orderOut(_ sender: Any?) { recordedVisible = false }
}

@MainActor
private final class DockingDelegate: NSObject, NSWindowDelegate {
    weak var controller: EdgeDockController?
    func windowDidMove(_ notification: Notification) { controller?.userMovedWindow() }
}

@main
struct EdgeDockingTests {
    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let visible = NSScreen.screens.first?.visibleFrame else {
            print("SKIP: native animation tests require a macOS screen session")
            return
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        for scenario in ["disable", "hide-show", "hide", "resize"] {
            let domain = "cn.local.AShareDesktop.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            let y = NSEvent.mouseLocation.y > visible.midY ? visible.minY : visible.maxY - 280
            let initial = NSRect(x: visible.maxX - 370, y: y, width: 370, height: 280)
            let panel = QuietPanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let handle = QuietPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            let delegate = DockingDelegate()
            var keepVisible = false
            let controller = EdgeDockController(panel: panel, surface: DesktopHoverView(), defaults: defaults,
                                                enabled: true, handlePanel: handle,
                                                pointerLocation: { NSPoint(x: visible.minX + 1, y: visible.minY + 1) },
                                                keepVisible: { keepVisible })
            delegate.controller = controller
            panel.delegate = delegate
            panel.orderFrontRegardless()
            controller.restore()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            keepVisible = true
            switch scenario {
            case "disable": controller.setEnabled(false)
            case "hide-show": controller.hide(); controller.show()
            case "resize": controller.resize(to: NSSize(width: 370, height: 320))
            default: controller.hide()
            }
            let immediate = panel.frame
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            check(panel.frame == immediate, "\(scenario)：已取消的动画不能继续修改窗口位置")
            if scenario == "disable" || scenario == "hide-show" {
                check(panel.frame == initial, "\(scenario)：窗口必须停留在展开位置")
                check(panel.isVisible && !handle.isVisible, "\(scenario)：仅显示完整浮窗")
            } else if scenario == "hide" {
                check(!panel.isVisible && !handle.isVisible, "手动隐藏不能被旧动画重新展开")
            } else {
                check(panel.frame.size == NSSize(width: 370, height: 320), "动画中改变列表高度保留新尺寸")
                check(!panel.isVisible && handle.isVisible, "收起状态改变尺寸后仍只显示提示条")
            }
            controller.stop()
            panel.orderOut(nil)
            panel.close()
            handle.close()
            defaults.removePersistentDomain(forName: domain)
        }
        for scenario in ["editing", "pending-dock", "disabled", "manually-hidden"] {
            let domain = "cn.local.AShareDesktop.focus-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            let y = NSEvent.mouseLocation.y > visible.midY ? visible.minY : visible.maxY - 280
            let initial = NSRect(x: visible.midX - 185, y: y, width: 370, height: 280)
            let panel = QuietPanel(contentRect: initial, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            let handle = QuietPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            var focused = true
            let controller = EdgeDockController(panel: panel, surface: DesktopHoverView(), defaults: defaults,
                                                enabled: scenario != "disabled", handlePanel: handle,
                                                pointerLocation: { NSPoint(x: visible.minX + 1, y: visible.minY + 1) },
                                                keepVisible: { focused })
            panel.orderFrontRegardless()
            controller.restore()
            if scenario == "editing" { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            if scenario == "manually-hidden" { controller.hide() }
            let beforeLoss = panel.frame
            focused = false
            controller.focusLost()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if scenario == "disabled" {
                check(panel.isVisible && !handle.isVisible && panel.frame == beforeLoss,
                      "关闭自动吸附时失焦保持普通浮窗")
            } else if scenario == "manually-hidden" {
                check(!panel.isVisible && !handle.isVisible && panel.frame == beforeLoss,
                      "手动隐藏后失焦不能重新显示提示条或移动窗口")
            } else {
                check(!panel.isVisible && handle.isVisible, "\(scenario)：编辑失焦后收起为提示条")
                check(defaults.double(forKey: "positionX") == visible.maxX - 370,
                      "\(scenario)：失焦时自动停靠屏幕右侧")
                (handle.contentView as? DesktopHoverView)?.onEnter?()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                check(!panel.isVisible && handle.isVisible, "\(scenario)：原地鼠标事件不能立即反弹展开")
                focused = true
                check(handle.contentView?.accessibilityPerformPress() == true,
                      "\(scenario)：提示条可以显式激活")
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                check(panel.isVisible && !handle.isVisible, "\(scenario)：鼠标原地时显式激活提示条仍可继续编辑")
            }
            controller.stop()
            panel.orderOut(nil); panel.close(); handle.close()
            defaults.removePersistentDomain(forName: domain)
        }
        print("PASS: \(checks) native docking assertions")
    }
}
