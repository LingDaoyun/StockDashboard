import Foundation

@main
struct WatchlistTests {
    @MainActor
    static func main() throws {
        let domain = "cn.local.AShareDesktop.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = QuoteStore(defaults: defaults, preview: nil)
        store.suspend()
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        func rejects(_ action: () throws -> Void, _ message: String) {
            do { try action(); preconditionFailure(message) }
            catch { count += 1 }
        }
        check(store.symbols.isEmpty, "首次启动必须为空")
        check(store.backgroundTransparency == 0.3, "首次启动背景透明度默认为30%")
        try store.addSymbols("600108,002580")
        check(store.symbols.map(\.id) == ["sh600108", "sz002580"], "追加输入的股票")
        try store.addSymbols("002491")
        check(store.symbols.map(\.id) == ["sh600108", "sz002580", "sz002491"], "增量添加保留原列表")
        try store.addSymbols("002491,600519")
        check(store.symbols.map(\.id) == ["sh600108", "sz002580", "sz002491", "sh600519"], "去重且按顺序追加")
        let beforeInvalid = store.symbols
        rejects({ try store.addSymbols("123") }, "错误输入必须拒绝")
        check(store.symbols == beforeInvalid, "错误输入保留列表")
        store.removeSymbol(store.symbols[1])
        check(store.symbols.map(\.id) == ["sh600108", "sz002491", "sh600519"], "只删除指定股票")
        let reloaded = QuoteStore(defaults: defaults, preview: nil)
        reloaded.suspend()
        check(reloaded.symbols == store.symbols, "增删后的列表可恢复")
        store.backgroundTransparency = 1
        check(QuoteStore(defaults: defaults, preview: nil).backgroundTransparency == 1, "全透明设置可恢复")
        store.backgroundTransparency = 0.35
        check(QuoteStore(defaults: defaults, preview: nil).backgroundTransparency == 0.35, "透明度滑条设置可恢复")
        let holdingSymbol = store.symbols[0]
        try store.saveTracking(for: holdingSymbol, cost: "4.10", quantity: "1200", upper: "4.50", lower: "3.80", now: Date(timeIntervalSince1970: 100))
        check(store.tracking[holdingSymbol.id]?.quantity == 1200, "持仓股数保存")
        check(QuoteStore(defaults: defaults, preview: nil).tracking[holdingSymbol.id]?.costPrice == 4.10, "持仓成本重启恢复")
        let trackingBeforeInvalid = store.tracking[holdingSymbol.id]
        rejects({ try store.saveTracking(for: holdingSymbol, cost: "4.10", quantity: "1.5", upper: "4.50", lower: "3.80") }, "股数非整数不能保存")
        check(store.tracking[holdingSymbol.id] == trackingBeforeInvalid, "非法输入不改变已保存配置")
        func snapshot(_ price: Double, _ time: TimeInterval) -> Quote {
            Quote(symbol: holdingSymbol, name: "测试", price: price, previousClose: 4, change: price - 4,
                  changePercent: (price / 4 - 1) * 100, volumeLots: 100, amountYuan: 40_000,
                  timestamp: Date(timeIntervalSince1970: time), turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
        }
        var emitted = 0
        store.onPriceAlert = { _ in emitted += 1 }
        store.evaluateAlerts([holdingSymbol.id: snapshot(4.60, 101)], now: Date(timeIntervalSince1970: 102))
        check(emitted == 1, "报价触达连接到提醒回调")
        store.evaluateAlerts([holdingSymbol.id: snapshot(4.60, 101)], now: Date(timeIntervalSince1970: 102))
        check(emitted == 1, "同一快照不重复发出提醒")
        check(QuoteStore(defaults: defaults, preview: nil).tracking[holdingSymbol.id]?.upperTriggered == true, "重启保留已经触达状态")
        try store.saveTracking(for: holdingSymbol, cost: "4.20", quantity: "1000", upper: "4.50", lower: "3.80", now: Date(timeIntervalSince1970: 103))
        check(store.tracking[holdingSymbol.id]?.upperTriggered == true, "只修改持仓不重置提醒")
        try store.saveTracking(for: holdingSymbol, cost: "4.20", quantity: "1000", upper: "4.80", lower: "3.80", now: Date(timeIntervalSince1970: 104))
        check(store.tracking[holdingSymbol.id]?.upperTriggered == false, "修改阈值重新启用")
        store.rearmAlerts(for: holdingSymbol, now: Date(timeIntervalSince1970: 105))
        check(store.tracking[holdingSymbol.id]?.armedAt == Date(timeIntervalSince1970: 105), "手动重新启用等待新报价")
        store.removeSymbol(holdingSymbol)
        check(store.tracking[holdingSymbol.id] == nil, "删除股票清理持仓提醒")
        check(QuoteStore(defaults: defaults, preview: nil).tracking[holdingSymbol.id] == nil, "删除后持仓配置不恢复")
        let twenty = (0..<20).map { String(format: "600%03d", $0) }.joined(separator: ",")
        try store.saveSymbols(twenty)
        rejects({ try store.addSymbols("002580") }, "追加后仍限制20只")
        check(store.symbols.count == 20, "超限不修改原列表")
        try store.saveSymbols("")
        check(store.symbols.isEmpty, "清空移除全部股票")
        check(QuoteStore(defaults: defaults, preview: nil).symbols.isEmpty, "重启仍为空，无默认回填")
        print("PASS: \(count) watchlist assertions")
    }
}
