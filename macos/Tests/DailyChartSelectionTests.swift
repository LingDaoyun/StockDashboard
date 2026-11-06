import AppKit
import SwiftUI

private struct DailyChartSelectionFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func runDailyChartSelectionTests() throws -> Int {
    _ = NSApplication.shared
    let domain = "cn.local.AShareDesktop.chart-selection-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    let store = DailyChartAnnotationStore(defaults: defaults)
    let symbol = try StockSymbol.parseList("sh000001")[0]
    let dates = (1...60).map { (index: Int) -> String in
        let month = (index - 1) / 28 + 1
        let day = (index - 1) % 28 + 1
        return String(format: "2026-%02d-%02d", month, day)
    }
    let snapshot = DailyKLineSnapshot(symbol: symbol, candles: dates.map {
        DailyCandle(date: $0, open: 9, close: 11, high: 12, low: 8, volumeLots: 100)
    }, adjustment: "不复权", timestamp: Date())
    let marker = DailyChartAnnotation(kind: .marker, start: DailyChartAnchor(date: dates[15], price: 11))
    let trend = DailyChartAnnotation(kind: .trendLine,
                                    start: DailyChartAnchor(date: dates[20], price: 9),
                                    end: DailyChartAnchor(date: dates[40], price: 11))
    let horizontal = DailyChartAnnotation(kind: .horizontalLine, start: DailyChartAnchor(date: dates[5], price: 8.5))
    store.save([marker, trend, horizontal], symbol: symbol.id, adjustment: snapshot.adjustment)
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 540),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
        window.orderOut(nil)
        window.close()
        defaults.removePersistentDomain(forName: domain)
    }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DailyChartSelectionFailure(description: message) }
        checks += 1
    }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    func findInput(in view: NSView) -> DailyChartInteraction.MouseView? {
        if let input = view as? DailyChartInteraction.MouseView { return input }
        return view.subviews.lazy.compactMap { findInput(in: $0) }.first
    }
    func findTools(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { findTools(in: $0) }.first
    }
    func mount() throws -> DailyChartInteraction.MouseView {
        let chart = DailyKLineChartView(snapshot: snapshot, error: nil, isRefreshing: false,
                                       chartHeight: 508, interactive: true, annotationStore: store)
        let host = NSHostingView(rootView: chart.padding(16).frame(width: 900, height: 540))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle()
        guard let input = findInput(in: host), input.handlers != nil else {
            throw DailyChartSelectionFailure(description: "真实日K视图未挂载鼠标事件层")
        }
        return input
    }
    func selectTool(_ segment: Int, input: DailyChartInteraction.MouseView) throws {
        guard let host = window.contentView, let control = findTools(in: host) else {
            throw DailyChartSelectionFailure(description: "真实日K视图未挂载绘图工具分段控件")
        }
        window.makeFirstResponder(control)
        control.selectedSegment = segment
        try check(control.sendAction(control.action, to: control.target), "工具控件动作传递到SwiftUI Binding")
        settle()
        try check(input.handlers?.isBrowsing == (segment == 0), "选择绘图工具后实际鼠标层进入对应模式")
    }
    func savedIDs() -> [UUID] { store.load(symbol: symbol.id, adjustment: snapshot.adjustment).map(\.id) }
    func point(index: Double, price: Double, input: NSView) -> CGPoint {
        // Fixture's 8...12 prices receive 8% padding, matching the displayed price scale.
        let plot = CGRect(x: 2, y: 8, width: input.bounds.width - 80, height: input.bounds.height - 115)
        return CGPoint(x: plot.minX + (index + 0.5) / 60 * plot.width,
                       y: plot.maxY - (price - 7.68) / (12.32 - 7.68) * plot.height)
    }
    func click(_ point: CGPoint, input: DailyChartInteraction.MouseView) {
        let location = input.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                              clickCount: 1, pressure: 0)!
        }
        input.mouseDown(with: event(.leftMouseDown))
        input.mouseUp(with: event(.leftMouseUp))
        settle()
    }
    func escape(_ input: DailyChartInteraction.MouseView) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        input.keyDown(with: event)
        settle()
    }

    var input = try mount()
    escape(input)
    try check(savedIDs() == [marker.id, trend.id, horizontal.id], "未选择标注时Esc不能删除任何已保存对象")
    click(point(index: 15, price: 11, input: input), input: input)
    try check(window.firstResponder === input, "选中旧标注时事件层重新获得Esc键盘焦点")
    escape(input)
    try check(savedIDs() == [trend.id, horizontal.id], "点击已保存价格标记后Esc只删除选中的标记")

    input = try mount()
    try check(savedIDs() == [trend.id, horizontal.id], "重建大图后已删除标记不会从持久化存储重新出现")
    click(point(index: 30, price: 10, input: input), input: input)
    click(point(index: 2, price: 11.7, input: input), input: input)
    escape(input)
    try check(savedIDs() == [trend.id, horizontal.id], "浏览中点击空白取消选择，Esc不能误删上一条线")
    click(point(index: 30, price: 10, input: input), input: input)
    escape(input)
    try check(savedIDs() == [horizontal.id], "点击两点线段中部后Esc只删除当前线，保留水平线")
    click(point(index: 50, price: 8.5, input: input), input: input)
    escape(input)
    try check(savedIDs().isEmpty, "水平线可在任意横向位置选中并用Esc删除")

    let originals = [marker, trend, horizontal]
    let originalIDs = originals.map(\.id)
    for (segment, index, price, selectedID) in [(1, 30.0, 10.0, trend.id),
                                               (2, 50.0, 8.5, horizontal.id),
                                               (3, 15.0, 11.0, marker.id)] {
        store.save(originals, symbol: symbol.id, adjustment: snapshot.adjustment)
        input = try mount()
        try selectTool(segment, input: input)
        click(point(index: index, price: price, input: input), input: input)
        try check(window.firstResponder === input && input.handlers?.isBrowsing == true,
                  "绘图模式点击旧标注后重新取得Esc焦点并回到浏览，等待onChange后保留选择")
        escape(input)
        try check(savedIDs() == originalIDs.filter { $0 != selectedID },
                  "从绘图工具切回浏览后Esc仅删除点击选中的旧对象，不新增标注或删除其他对象")
    }
    store.save([], symbol: symbol.id, adjustment: snapshot.adjustment)
    input = try mount()
    try selectTool(2, input: input)
    click(point(index: 10, price: 9.7, input: input), input: input)
    try check(savedIDs().isEmpty, "画线第一点只创建草稿不写入标注存储")
    escape(input)
    try check(savedIDs().isEmpty && input.handlers?.isBrowsing == true,
              "草稿状态Esc取消草稿并回到浏览，不写入或误删已保存对象")
    try selectTool(2, input: input)
    click(point(index: 35, price: 9.2, input: input), input: input)
    try check(savedIDs().isEmpty, "取消后重新画线的第一点不能与旧草稿端点连接")
    click(point(index: 45, price: 10.8, input: input), input: input)
    let newLines = store.load(symbol: symbol.id, adjustment: snapshot.adjustment)
    try check(newLines.count == 1 && newLines[0].kind == .trendLine
              && newLines[0].start.date == dates[35] && newLines[0].end?.date == dates[45]
              && abs(newLines[0].start.price - 9.2) < 0.000001
              && abs((newLines[0].end?.price ?? 0) - 10.8) < 0.000001,
              "取消草稿后完成的新线只保存重新选择的两个日期和价格端点")
    return checks
}
