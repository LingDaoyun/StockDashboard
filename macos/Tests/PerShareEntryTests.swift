import Foundation

@MainActor
func runPerShareEntryTests() throws -> Int {
    let domain = "cn.local.AShareDesktop.per-share-entry-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = QuoteStore(defaults: defaults, preview: nil)
    store.suspend()
    try store.addSymbols("600108")
    let symbol = store.symbols[0]
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }

    for total in ["18763.07", "0.00", "-123.45"] {
        try store.savePosition(for: symbol, amount: total, quantity: "4500", upper: "", lower: "",
                               estimateFees: false, commissionRate: "unused")
        let original = store.tracking[symbol.id]!
        try store.savePerSharePosition(for: symbol, perShareCost: original.perShareCostInputText,
                                       quantity: "4500", upper: "10", lower: "")
        let edited = store.tracking[symbol.id]!
        check(edited.totalCostYuan == original.totalCostYuan && edited.perShareCostYuan == nil
              && edited.costPrice == original.costPrice && edited.upperPrice == 10,
              "旧总成本带入新单价界面，仅修改提醒不能用舍入后的单价改写原成本")
        check(edited.profit(at: 5)?.amount == original.profit(at: 5)?.amount && edited.profit(at: 5)?.percent == original.profit(at: 5)?.percent, "仅改提醒保持盈亏和盈亏率")
    }

    try store.savePosition(for: symbol, amount: "40000", quantity: "4000", upper: "", lower: "",
                           estimateFees: true, commissionRate: "1.2")
    let purchase = store.tracking[symbol.id]!
    try store.savePerSharePosition(for: symbol, perShareCost: purchase.perShareCostInputText,
                                   quantity: "4000", upper: "14", lower: "9")
    let preserved = store.tracking[symbol.id]!
    check(preserved.totalCostYuan == purchase.totalCostYuan && preserved.purchaseAmountYuan == purchase.purchaseAmountYuan
          && preserved.purchaseCommissionRate == purchase.purchaseCommissionRate,
          "旧买入预估来源和历史费率保持不变，不重新加费")

    try store.savePerSharePosition(for: symbol, perShareCost: "10.12345678", quantity: "500", upper: "14", lower: "9")
    check(store.tracking[symbol.id]?.perShareCostYuan == Decimal(string: "10.12345678")
          && store.tracking[symbol.id]?.totalCostYuan == nil && store.tracking[symbol.id]?.purchaseAmountYuan == nil,
          "修改成本或股数后按完整每股成本保存，清理旧金额来源")
    for cost in ["0", "-0.12345678"] {
        try store.savePerSharePosition(for: symbol, perShareCost: cost, quantity: "500", upper: "14", lower: "9")
        check(store.tracking[symbol.id]?.perShareCostYuan == Decimal(string: cost), "零与负每股成本仍支持")
    }
    let beforeInvalid = store.tracking[symbol.id]
    do {
        try store.savePerSharePosition(for: symbol, perShareCost: "1", quantity: "", upper: "", lower: "")
        preconditionFailure("成本与股数不能只填一项")
    } catch { checks += 1 }
    check(store.tracking[symbol.id] == beforeInvalid, "无效输入不修改已存持仓")
    try store.savePerSharePosition(for: symbol, perShareCost: "", quantity: "", upper: "14", lower: "9")
    check(store.tracking[symbol.id]?.hasPosition == false && store.tracking[symbol.id]?.hasAlerts == true,
          "同时留空清除持仓，独立提醒保留")

    try store.addSymbols("002580")
    let other = store.symbols[1]
    let now = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00+08:00")!
    try store.savePerSharePosition(for: other, perShareCost: "20", quantity: "100", upper: "26", lower: "18", now: now)
    try store.savePosition(for: symbol, amount: "1000", quantity: "100", upper: "12", lower: "8",
                           estimateFees: true, commissionRate: "2.5", now: now)
    func quote(_ stock: StockSymbol, price: Double) -> Quote {
        Quote(symbol: stock, name: "synthetic", price: price, previousClose: price,
              change: 0, changePercent: 0, volumeLots: 100, amountYuan: 1000,
              timestamp: now, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
    }
    store.receive([symbol.id: quote(symbol, price: 7)], requested: [symbol], at: now)
    store.receive([symbol.id: quote(symbol, price: 13), other.id: quote(other, price: 21)],
                  requested: store.symbols, at: now)
    let position = store.tracking[symbol.id]!
    check(position.upperTriggered && position.lowerTriggered && store.priceAlerts[symbol.id] != nil,
          "清仓测试先建立两个方向已触发的独立提醒")
    check(store.totalPositionProfit == position.profit(at: 13)!.amount + 100,
          "清仓前总盈亏包含两只股票")
    let symbolsBeforeClear = store.symbols
    let quotesBeforeClear = store.quotes
    let alertsBeforeClear = store.priceAlerts
    let otherBeforeClear = store.tracking[other.id]
    let alertsOnly = StockTracking(upperPrice: 12, lowerPrice: 8, upperTriggered: true,
                                   lowerTriggered: true, armedAt: position.armedAt)
    store.expandedSymbolID = symbol.id
    store.clearPosition(for: symbol)
    check(store.tracking[symbol.id] == alertsOnly,
          "直接清仓清除成本、股数、旧总成本和买入预估字段，保留提醒阈值、触发状态与armedAt")
    check(store.symbols == symbolsBeforeClear && store.quotes.mapValues(\.price) == quotesBeforeClear.mapValues(\.price)
          && store.quotes.mapValues(\.timestamp) == quotesBeforeClear.mapValues(\.timestamp)
          && store.priceAlerts == alertsBeforeClear, "清仓不删除股票、报价或已显示提醒")
    check(store.tracking[other.id] == otherBeforeClear && store.totalPositionProfit == 100,
          "清仓不修改其他股票，总盈亏立即只计算剩余持仓")
    check(store.expandedSymbolID == nil, "清仓关闭该股编辑器，避免旧草稿回填")
    let trackingAfterClear = store.tracking
    store.clearPosition(for: symbol)
    check(store.tracking == trackingAfterClear && store.priceAlerts == alertsBeforeClear
          && store.symbols == symbolsBeforeClear && store.totalPositionProfit == 100,
          "没有持仓时重复清仓不改变提醒、股票或剩余持仓")
    let restored = QuoteStore(defaults: defaults, preview: nil)
    restored.suspend()
    check(restored.tracking[symbol.id] == alertsOnly && restored.tracking[other.id] == otherBeforeClear
          && restored.symbols == symbolsBeforeClear, "重启不恢复已清持仓，提醒状态及其他股票仍保留")

    try store.savePerSharePosition(for: symbol, perShareCost: "10.12345678", quantity: "100", upper: "", lower: "")
    store.clearPosition(for: symbol)
    check(store.tracking[symbol.id] == nil && store.totalPositionProfit == 100,
          "精确每股成本同样可清除，没有独立提醒时不残留持仓记录")
    let restoredPerShare = QuoteStore(defaults: defaults, preview: nil)
    restoredPerShare.suspend()
    check(restoredPerShare.tracking[symbol.id] == nil && restoredPerShare.tracking[other.id] == otherBeforeClear,
          "重启不恢复精确每股成本，其他股票配置不变")
    return checks
}
