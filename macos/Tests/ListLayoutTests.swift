import AppKit
import SwiftUI

private struct ListLayoutFailure: Error, CustomStringConvertible {
    let description: String
}

// A SwiftUI layout loop blocks the main run loop, so its timeout must run elsewhere.
private final class ListLayoutWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "starting"
    private var deadline = Date().addingTimeInterval(4)
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init() {
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let failedStage = Date() > self.deadline ? self.stage : nil
            self.lock.unlock()
            if let failedStage {
                FileHandle.standardError.write(Data("FAIL: main-thread layout exceeded 4 seconds: \(failedStage)\n".utf8))
                exit(124)
            }
        }
        timer.resume()
    }

    func begin(_ stage: String) {
        lock.lock()
        self.stage = stage
        deadline = Date().addingTimeInterval(4)
        lock.unlock()
    }

    func stop() { timer.cancel() }
}

@MainActor
func runListLayoutTests() throws -> Int {
    _ = NSApplication.shared
    let watchdog = ListLayoutWatchdog()
    defer { watchdog.stop() }
    var checks = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ListLayoutFailure(description: message) }
        checks += 1
    }
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    for count in [8, 20] {
        let domain = "cn.local.AShareDesktop.list-layout-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let codes = (0..<count).map { String(format: "sh%06d", 600000 + $0) }.joined(separator: ",")
        let store = QuoteStore(defaults: defaults, preview: codes)
        // Do not start polling; suspension also blocks refreshes caused by tab switches.
        store.suspend()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 370,
                                                   height: 82 + MarketOverviewView.height + store.listHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WidgetView(store: store, transparency: {}, add: {},
                                                       pin: {}, autoHide: {}, hide: {},
                                                       configure: { store.expandedSymbolID = $0.id },
                                                       intraday: { store.toggleIntraday(for: $0) },
                                                       dailyKLine: { store.toggleDailyKLine(for: $0) }))
        window.contentView = host
        defer {
            store.stop()
            window.orderOut(nil)
            window.close()
            defaults.removePersistentDomain(forName: domain)
        }

        func settle(_ label: String, duration: TimeInterval = 0.18) throws {
            watchdog.begin("\(count) rows: \(label)")
            window.setContentSize(NSSize(width: 370, height: 82 + MarketOverviewView.height + store.listHeight))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
            try check(host.bounds.width == 370 && host.bounds.height.isFinite,
                      "\(label): hosting view must retain finite panel geometry")
            try check(!store.isRefreshing && !store.isIntradayRefreshing && !store.isDailyKLineRefreshing,
                      "\(label): isolated layout test must not fetch quotes or charts")
        }

        func scrollToEdge(bottom: Bool) throws {
            watchdog.begin("\(count) rows: scroll \(bottom ? "bottom" : "top")")
            guard let scroll = scrollView(in: host), let document = scroll.documentView else {
                throw ListLayoutFailure(description: "real WidgetView must mount an NSScrollView")
            }
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom ? maximum : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try settle("scroll \(bottom ? "bottom" : "top")", duration: 0.03)
            try check(scroll.contentView.bounds.origin.y.isFinite,
                      "scroll offset must remain finite")
            if bottom && store.selectedList == .holdings && store.expandedChartSymbolID == nil
                && (!store.isCompactMode || maximum > 0) {
                try check(scroll.contentView.bounds.origin.y > 0, "long holdings list must actually scroll")
            }
        }

        window.orderFront(nil)
        try settle("mount")
        for cycle in 0..<3 {
            for symbol in [store.symbols.last!, store.symbols.first!, store.symbols[count / 2]] {
                try scrollToEdge(bottom: true)
                store.toggleIntraday(for: symbol)
                try settle("cycle \(cycle), expand \(symbol.id) intraday")
                try check(store.expandedChartSymbolID == symbol.id, "intraday selection must remain expanded")
                store.toggleDailyKLine(for: symbol)
                try settle("cycle \(cycle), switch \(symbol.id) daily")
                try check(store.chartKind == .dailyKLine, "same-row chart switch must show daily chart")
                store.closeIntraday()
                try settle("cycle \(cycle), close chart")
                store.expandedSymbolID = symbol.id
                try settle("cycle \(cycle), expand holdings editor")
                store.expandedSymbolID = nil
                try settle("cycle \(cycle), close holdings editor")
            }

            store.toggleCompactMode()
            try settle("cycle \(cycle), compact mode")
            try check(store.isCompactMode && store.expandedCompactSymbolIDs.isEmpty,
                      "entering compact mode must show collapsed single-line rows")
            try scrollToEdge(bottom: true)
            let edgeSymbols = [store.symbols.first!, store.symbols.last!]
            for symbol in edgeSymbols { store.toggleCompactRow(for: symbol) }
            try settle("cycle \(cycle), expand first and last compact rows")
            try check(store.expandedCompactSymbolIDs == Set(edgeSymbols.map(\.id)),
                      "compact rows must expand independently")
            for symbol in edgeSymbols {
                try scrollToEdge(bottom: true)
                store.toggleIntraday(for: symbol)
                try settle("cycle \(cycle), compact row \(symbol.id) intraday")
                store.toggleDailyKLine(for: symbol)
                store.expandedSymbolID = symbol.id
                try settle("cycle \(cycle), compact row \(symbol.id) daily chart and editor")
                store.toggleCompactRow(for: symbol)
                try settle("cycle \(cycle), collapse compact row \(symbol.id)")
                try check(!store.expandedCompactSymbolIDs.contains(symbol.id)
                          && store.expandedChartSymbolID == nil && store.expandedSymbolID == nil,
                          "collapsing a compact row must close its chart and holdings editor")
            }
            try scrollToEdge(bottom: false)

            store.toggleCompactRow(for: edgeSymbols[0])
            store.toggleIntraday(for: edgeSymbols[0])
            store.expandedSymbolID = edgeSymbols[0].id
            try settle("cycle \(cycle), compact row before mode switch")
            store.toggleCompactMode()
            try settle("cycle \(cycle), return to rich mode")
            try check(!store.isCompactMode && store.expandedCompactSymbolIDs.isEmpty
                      && store.expandedChartSymbolID == nil && store.expandedSymbolID == nil,
                      "mode switch must clear compact expansions and nested content")
            store.toggleCompactMode()
            for symbol in edgeSymbols { store.toggleCompactRow(for: symbol) }
            try settle("cycle \(cycle), compact rows before tab switch")
            store.selectList(.indices)
            try settle("cycle \(cycle), indices tab")
            try check(store.expandedCompactSymbolIDs.isEmpty,
                      "tab switch must clear compact row expansions")
            for index in [DashboardIndex.all.last!, DashboardIndex.all.first!] {
                store.toggleCompactRow(for: index.symbol)
                try settle("cycle \(cycle), expand index compact row \(index.id)")
                try scrollToEdge(bottom: true)
                store.toggleIntraday(for: index.symbol)
                try settle("cycle \(cycle), expand index \(index.id)")
                store.toggleDailyKLine(for: index.symbol)
                try settle("cycle \(cycle), index daily chart")
                store.toggleCompactRow(for: index.symbol)
                try settle("cycle \(cycle), collapse index compact row and chart")
                try check(store.expandedChartSymbolID == nil && !store.expandedCompactSymbolIDs.contains(index.id),
                          "collapsing a compact index row must close its chart")
            }
            store.toggleCompactMode()
            try settle("cycle \(cycle), index rich mode")
            try check(store.listHeight == IndexDashboardView.height, "index rich mode retains the two-column viewport")
            store.toggleCompactMode()
            try settle("cycle \(cycle), index compact mode again")
            store.selectList(.holdings)
            try settle("cycle \(cycle), holdings tab")
            try check(store.visibleSymbols.count == count && store.expandedChartSymbolID == nil,
                      "tab round trip must retain all holdings and close the index chart")
            try check(store.isCompactMode && store.expandedCompactSymbolIDs.isEmpty,
                      "tab round trip must retain compact mode with all rows collapsed")
            try scrollToEdge(bottom: false)
            store.toggleCompactMode()
            try settle("cycle \(cycle), restore rich mode after tab round trip")
        }
        print("PASS: native layout interactions with \(count) holdings")
    }
    return checks
}

#if LIST_LAYOUT_TEST_MAIN
@main
private enum ListLayoutTestMain {
    @MainActor
    static func main() throws {
        print("PASS: \(try runListLayoutTests()) native list-layout assertions")
    }
}
#endif
