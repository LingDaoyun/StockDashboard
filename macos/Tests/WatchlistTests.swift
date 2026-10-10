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
        check(store.autoHideEnabled, "首次启动默认开启右侧自动吸附隐藏")
        store.autoHideEnabled = false
        check(!QuoteStore(defaults: defaults, preview: nil).autoHideEnabled, "关闭自动隐藏后重启保持关闭")
        store.autoHideEnabled = true
        check(QuoteStore(defaults: defaults, preview: nil).autoHideEnabled, "重新开启自动隐藏后重启保持开启")
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
        defaults.set("600108,002580", forKey: "symbols")
        let marketStore = QuoteStore(defaults: defaults, preview: nil)
        marketStore.suspend()
        let requested = marketStore.symbols
        let primary = requested[0]
        let secondary = requested[1]
        func marketQuote(_ symbol: StockSymbol, _ price: Double, _ time: TimeInterval) -> Quote {
            Quote(symbol: symbol, name: "synthetic", price: price, previousClose: 100,
                  change: price - 100, changePercent: price - 100, volumeLots: 100, amountYuan: 10_000,
                  timestamp: Date(timeIntervalSince1970: time), turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
        }
        try marketStore.saveTracking(for: primary, cost: "", quantity: "", upper: "", lower: "100",
                                     now: Date(timeIntervalSince1970: 1080))
        var marketAlerts = 0
        marketStore.onPriceAlert = { _ in marketAlerts += 1 }
        marketStore.receive([primary.id: marketQuote(primary, 101, 1095)], requested: requested, at: Date(timeIntervalSince1970: 1100))
        marketStore.receive([primary.id: marketQuote(primary, 99, 1090)], requested: requested, at: Date(timeIntervalSince1970: 1101))
        check(marketStore.quotes[primary.id]?.price == 101, "旧快照不能覆盖较新价格")
        check(marketAlerts == 0 && marketStore.tracking[primary.id]?.lowerTriggered == false, "被拒绝旧快照不消耗提醒机会")
        check(marketStore.unavailable.contains(primary.id), "源时间倒退需要标记上次数据")
        check(marketStore.lastReceipt == Date(timeIntervalSince1970: 1101), "接收时间不能冒充行情源时间")
        marketStore.receive([primary.id: marketQuote(primary, 102, 1095)], requested: requested, at: Date(timeIntervalSince1970: 1102))
        check(marketStore.quotes[primary.id]?.price == 102 && !marketStore.unavailable.contains(primary.id), "相同源时间允许更新有效字段，并解除异常标记")
        marketStore.receive([primary.id: marketQuote(primary, 99, 1200), secondary.id: marketQuote(secondary, 50, 1200)],
                            requested: requested, at: Date(timeIntervalSince1970: 1103))
        check(marketStore.quotes[primary.id]?.price == 102, "明显未来报价不能污染现有价格")
        check(marketStore.quotes[secondary.id] == nil, "首次收到未来时间也不能建立报价缓存")
        check(marketAlerts == 0 && marketStore.tracking[primary.id]?.lowerTriggered == false, "异常时间不触发或消耗提醒")
        marketStore.receive([primary.id: marketQuote(primary, 99, 1105), secondary.id: marketQuote(secondary, 50, 1110)],
                            requested: requested, at: Date(timeIntervalSince1970: 1105))
        check(marketStore.quotes[primary.id]?.price == 99 && marketAlerts == 1, "后续真正的新报价仍可触发提醒")
        check(marketStore.quotes[secondary.id]?.timestamp == Date(timeIntervalSince1970: 1110), "允许最多5秒的时钟偏差")
        check(marketStore.unavailable.isEmpty, "有效完整响应解除所有异常标记")
        marketStore.receive([primary.id: marketQuote(primary, 98, 1106)], requested: requested, at: Date(timeIntervalSince1970: 1106))
        check(marketAlerts == 1 && marketStore.unavailable == [secondary.id], "提醒仍只触发一次；部分响应明确标记缺失证券")
        let malformed = StockTracking(costPrice: 10, quantity: 100, upperPrice: 9, lowerPrice: 11)
        let valid = StockTracking(costPrice: 20, quantity: 200, upperPrice: 21, upperTriggered: true,
                                  armedAt: Date(timeIntervalSince1970: 100))
        defaults.set(try JSONEncoder().encode(["sh600108": malformed, "sz002580": valid]), forKey: "stockTracking")
        let restoredStore = QuoteStore(defaults: defaults, preview: nil)
        restoredStore.suspend()
        check(restoredStore.tracking["sh600108"] == nil, "异常保存配置不能恢复为可触发提醒")
        check(restoredStore.tracking["sz002580"] == valid, "另一只合法持仓和已提醒状态必须保留")
        check(restoredStore.invalidTracking["sh600108"] == malformed, "异常配置原字段保留用于提示和修正")
        restoredStore.evaluateAlerts(["sh600108": marketQuote(primary, 10, 1100)], now: Date(timeIntervalSince1970: 1100))
        check(restoredStore.priceAlerts.isEmpty, "不合法配置不能产生矛盾提醒")
        try restoredStore.saveTracking(for: secondary, cost: "20.5", quantity: "200", upper: "21", lower: "")
        let preserved = try JSONDecoder().decode([String: StockTracking].self, from: defaults.data(forKey: "stockTracking")!)
        check(preserved["sh600108"] == malformed, "修改另一只股票不能删除待修正配置的原数据")
        try restoredStore.saveTracking(for: primary, cost: "10", quantity: "100", upper: "11", lower: "9")
        check(restoredStore.invalidTracking.isEmpty && restoredStore.tracking[primary.id]?.upperPrice == 11, "修正并保存后解除配置异常")
        check(QuoteStore(defaults: defaults, preview: nil).invalidTracking.isEmpty, "修正结果可在重启后恢复")
        let invalidHolding = StockTracking(costPrice: 10, quantity: 0, upperPrice: 12, upperTriggered: true, lowerTriggered: true,
                                           armedAt: Date(timeIntervalSince1970: 100))
        defaults.set(try JSONEncoder().encode([primary.id: invalidHolding]), forKey: "stockTracking")
        let repairedStore = QuoteStore(defaults: defaults, preview: nil)
        repairedStore.suspend()
        var repairedAlerts = 0
        repairedStore.onPriceAlert = { _ in repairedAlerts += 1 }
        try repairedStore.saveTracking(for: primary, cost: "10", quantity: "100", upper: "12", lower: "",
                                       now: Date(timeIntervalSince1970: 1100))
        check(repairedStore.tracking[primary.id]?.upperTriggered == true, "只修正异常持仓仍保留未变更阈值的已提醒状态")
        check(repairedStore.tracking[primary.id]?.lowerTriggered == false, "修正时清除没有对应提醒价的孤立触达标记")
        check(repairedStore.tracking[primary.id]?.armedAt == invalidHolding.armedAt, "只修正异常持仓不重新启用提醒")
        repairedStore.evaluateAlerts([primary.id: marketQuote(primary, 12, 1101)], now: Date(timeIntervalSince1970: 1101))
        check(repairedAlerts == 0, "修正异常持仓后不重复提醒")
        try repairedStore.saveTracking(for: primary, cost: "10", quantity: "100", upper: "13", lower: "",
                                       now: Date(timeIntervalSince1970: 1102))
        check(repairedStore.tracking[primary.id]?.upperTriggered == false && repairedStore.tracking[primary.id]?.armedAt == Date(timeIntervalSince1970: 1102), "修正后改价仍可重新启用提醒")
        print("PASS: \(count) watchlist assertions")
    }
}
