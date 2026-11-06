import AppKit

private struct ExpandedChartWindowFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func runExpandedChartWindowTests() throws -> Int {
    _ = NSApplication.shared
    guard let screen = NSScreen.main else {
        throw ExpandedChartWindowFailure(description: "大图原生窗口测试需要可用屏幕")
    }
    let domain = "cn.local.AShareDesktop.expanded-chart-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    let store = QuoteStore(defaults: defaults, preview: "600108,002580")
    store.suspend()
    let controller = ExpandedChartWindow(store: store)
    defer {
        controller.window?.orderOut(nil)
        controller.close()
        store.stop()
        defaults.removePersistentDomain(forName: domain)
    }
    guard let window = controller.window as? NSPanel else {
        throw ExpandedChartWindowFailure(description: "大图窗口必须创建真实NSPanel")
    }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ExpandedChartWindowFailure(description: message) }
        checks += 1
    }
    func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline && !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    let first = store.symbols[0], second = store.symbols[1]
    store.toggleIntraday(for: first)
    controller.show(on: screen)
    try check(window.isVisible, "双击回调打开的大图窗口可见")
    let visible = screen.visibleFrame
    try check(abs(window.frame.midX - visible.midX) <= 1 && abs(window.frame.midY - visible.midY) <= 1,
              "大图按指定屏幕可用区域居中")
    let content = window.contentRect(forFrameRect: window.frame)
    try check(abs(content.width - min(900, visible.width - 48)) <= 1
              && abs(content.height - min(540, visible.height - 80)) <= 1,
              "大图默认内容900×540并适应较小屏幕")
    try check(window.styleMask.contains(.closable) && window.styleMask.contains(.resizable)
              && window.isFloatingPanel && window.level == .floating, "大图可关闭、可调整大小且为浮窗")
    try check(window.title.contains(first.id.uppercased()) && window.title.hasSuffix("· 分时"),
              "首次展示标题对应当前证券和分时")

    controller.close()
    try check(!window.isVisible && store.expandedChartSymbolID == first.id && store.chartKind == .intraday,
              "关闭大图保留原小图选择")
    controller.show(on: screen)
    try check(window.isVisible, "关闭后的同一个大图窗口可再次打开")
    store.toggleDailyKLine(for: first)
    spin(until: { window.title.hasSuffix("· 日K") })
    try check(window.isVisible && window.title.contains(first.id.uppercased()) && window.title.hasSuffix("· 日K"),
              "同证券切换日K更新大图，Published中间空值不能误关闭窗口")
    store.toggleDailyKLine(for: second)
    spin(until: { window.title.contains(second.id.uppercased()) })
    try check(window.isVisible && window.title.contains(second.id.uppercased()) && window.title.hasSuffix("· 日K"),
              "切换证券后已打开的大图同步标题并保持可见")
    store.closeIntraday()
    spin(until: { !window.isVisible })
    try check(!window.isVisible && store.expandedChartSymbolID == nil, "收起小图同时关闭大图")

    store.selectList(.indices)
    let index = DashboardIndex.all[0]
    store.toggleDailyKLine(for: index.symbol)
    controller.show(on: screen)
    try check(window.isVisible && window.title.contains(index.title) && window.title.hasSuffix("· 日K"),
              "综合指数日K可复用同一大图窗口")
    store.selectList(.holdings)
    spin(until: { !window.isVisible })
    try check(!window.isVisible && store.expandedChartSymbolID == nil, "离开指数页关闭大图")
    try check(store.quotes.isEmpty && store.intradaySnapshot == nil && store.dailyKLineSnapshot == nil
              && !store.isRefreshing && !store.isIntradayRefreshing && !store.isDailyKLineRefreshing,
              "隔离暂停的原生窗口测试不启动行情请求")
    return checks
}
