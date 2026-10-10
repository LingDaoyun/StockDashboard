import Foundation

@MainActor
func runTotalProfitTests() throws -> Int {
    let domain = "cn.local.AShareDesktop.total-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = QuoteStore(defaults: defaults, preview: nil)
    store.suspend()
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        count += 1
    }
    func quote(_ symbol: StockSymbol, price: Double, time: TimeInterval = 100) -> Quote {
        Quote(symbol: symbol, name: "synthetic", price: price, previousClose: price,
              change: 0, changePercent: 0, volumeLots: 100, amountYuan: 1000,
              timestamp: Date(timeIntervalSince1970: time), turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
    }
    check(store.totalPositionProfit == 0, "空列表总盈亏为零")
    try store.addSymbols("600108,002580,002491")
    let first = store.symbols[0], second = store.symbols[1], unowned = store.symbols[2]
    check(store.totalPositionProfit == 0, "没有买入的自选股不要求报价")
    try store.saveTracking(for: unowned, cost: "", quantity: "", upper: "100", lower: "")
    check(store.totalPositionProfit == 0, "只有提醒的股票不参与持仓合计")
    try store.saveTracking(for: first, cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005.08")
    check(store.totalPositionProfit == nil, "已买入股票缺报价时不可显示不完整合计")
    store.receive([first.id: quote(first, price: 12)], requested: store.symbols, at: Date(timeIntervalSince1970: 101))
    check(store.totalPositionProfit == Decimal(string: "194.92"), "含费成本直接参与合计且不重复加费")
    try store.saveTracking(for: second, cost: "", quantity: "200", upper: "", lower: "", totalCost: "2205")
    check(store.totalPositionProfit == nil, "第二只持仓缺报价时不能只显示第一只的盈利")
    store.receive([first.id: quote(first, price: 12), second.id: quote(second, price: 10)],
                  requested: store.symbols, at: Date(timeIntervalSince1970: 101))
    check(store.totalPositionProfit == Decimal(string: "-10.08"), "盈利与亏损按分精确相加")
    check(store.unavailable.contains(unowned.id), "未买入自选股可处于无报价状态")
    check(store.totalPositionProfit == Decimal(string: "-10.08"), "未买入股票缺报价不影响合计")
    store.receive([first.id: quote(first, price: 12.01, time: 102), second.id: quote(second, price: 10, time: 102),
                   unowned.id: quote(unowned, price: 999, time: 102)],
                  requested: store.symbols, at: Date(timeIntervalSince1970: 103))
    check(store.totalPositionProfit == Decimal(string: "-9.08"), "价格刷新立即更新总盈亏且忽略无持仓价格")
    try store.saveTracking(for: second, cost: "", quantity: "", upper: "", lower: "")
    check(store.totalPositionProfit == Decimal(string: "195.92"), "清空持仓后立即移除贡献")
    try store.savePosition(for: second, amount: "1000", quantity: "100", upper: "", lower: "", estimateFees: true, commissionRate: "2.5")
    check(store.totalPositionProfit == Decimal(string: "190.92"), "自动最低佣金仅计入一次")
    store.receive([first.id: quote(first, price: 12.01, time: 104)], requested: store.symbols, at: Date(timeIntervalSince1970: 105))
    check(store.unavailable.contains(second.id) && store.totalPositionProfit == Decimal(string: "190.92"),
          "暂时缺报价沿用与持仓卡一致的已缓存价格")
    store.removeSymbol(first)
    check(store.totalPositionProfit == -5, "删除股票立即移除其盈亏")
    store.removeSymbol(second)
    check(store.totalPositionProfit == 0, "最后一只持仓删除后合计归零")
    check(yuanText(Decimal(string: "190.92")!, showSign: true) == "+190.92", "正总额保留两位小数与加号")
    check(yuanText(Decimal(string: "-9.08")!, showSign: true) == "-9.08", "负总额保留分的精度")
    check(yuanText(0, showSign: false) == "0.00", "无持仓总额格式为0.00")

    defaults.set("600108,002580", forKey: "symbols")
    defaults.set(Data(#"{"sh600108":{"quantity":"bad"},"sz002580":{"totalCostYuan":1005,"quantity":100,"upperTriggered":false,"lowerTriggered":false}}"#.utf8), forKey: "stockTracking")
    let damaged = QuoteStore(defaults: defaults, preview: nil)
    damaged.suspend()
    damaged.receive([second.id: quote(second, price: 12)], requested: damaged.symbols, at: Date(timeIntervalSince1970: 101))
    check(damaged.totalPositionProfit == nil, "未能读取的配置不得被静默漏算为完整合计")
    try damaged.saveTracking(for: first, cost: "", quantity: "", upper: "", lower: "")
    check(damaged.totalPositionProfit == 195, "明确清除损坏配置后恢复正确合计")
    defaults.set(try JSONEncoder().encode([first.id: StockTracking(costPrice: 10, quantity: -100)]), forKey: "stockTracking")
    let invalid = QuoteStore(defaults: defaults, preview: nil)
    invalid.suspend()
    check(invalid.totalPositionProfit == nil, "非法持仓不得产生误导性的零合计")
    for partial in [StockTracking(costPrice: 10), StockTracking(quantity: 100),
                    StockTracking(totalCostYuan: 1005), StockTracking(purchaseAmountYuan: 1000)] {
        defaults.set(try JSONEncoder().encode([first.id: partial]), forKey: "stockTracking")
        let partialStore = QuoteStore(defaults: defaults, preview: nil)
        partialStore.suspend()
        check(partialStore.totalPositionProfit == nil, "持仓字段缺失配对也不能显示不完整合计")
    }
    defaults.set(try JSONEncoder().encode([first.id: StockTracking(upperPrice: 5, lowerPrice: 10)]), forKey: "stockTracking")
    let alertOnlyInvalid = QuoteStore(defaults: defaults, preview: nil)
    alertOnlyInvalid.suspend()
    check(alertOnlyInvalid.totalPositionProfit == 0, "只设提醒的配置错误不产生持仓也不影响合计")
    return count
}
