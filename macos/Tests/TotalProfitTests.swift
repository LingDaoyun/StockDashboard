import Foundation

@MainActor
func runTotalProfitTests() throws -> Int {
    let domain = "cn.local.AShareDesktop.total-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let fixtureTime = Date(timeIntervalSince1970: 101)
    let store = QuoteStore(defaults: defaults, preview: nil, clock: { fixtureTime })
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
    let damaged = QuoteStore(defaults: defaults, preview: nil, clock: { fixtureTime })
    damaged.suspend()
    damaged.receive([second.id: quote(second, price: 12)], requested: damaged.symbols, at: Date(timeIntervalSince1970: 101))
    check(damaged.totalPositionProfit == nil, "未能读取的配置不得被静默漏算为完整合计")
    try damaged.saveTracking(for: first, cost: "", quantity: "", upper: "", lower: "")
    check(damaged.totalPositionProfit == 195, "明确清除损坏配置后恢复正确合计")
    defaults.set(try JSONEncoder().encode([first.id: StockTracking(costPrice: 10, quantity: -100)]), forKey: "stockTracking")
    let invalid = QuoteStore(defaults: defaults, preview: nil, clock: { fixtureTime })
    invalid.suspend()
    check(invalid.totalPositionProfit == nil, "非法持仓不得产生误导性的零合计")
    for partial in [StockTracking(costPrice: 10), StockTracking(quantity: 100),
                    StockTracking(totalCostYuan: 1005), StockTracking(purchaseAmountYuan: 1000)] {
        defaults.set(try JSONEncoder().encode([first.id: partial]), forKey: "stockTracking")
        let partialStore = QuoteStore(defaults: defaults, preview: nil, clock: { fixtureTime })
        partialStore.suspend()
        check(partialStore.totalPositionProfit == nil, "持仓字段缺失配对也不能显示不完整合计")
    }
    defaults.set(try JSONEncoder().encode([first.id: StockTracking(upperPrice: 5, lowerPrice: 10)]), forKey: "stockTracking")
    let alertOnlyInvalid = QuoteStore(defaults: defaults, preview: nil, clock: { fixtureTime })
    alertOnlyInvalid.suspend()
    check(alertOnlyInvalid.totalPositionProfit == 0, "只设提醒的配置错误不产生持仓也不影响合计")

    for time in ["09:20:00", "14:58:00"] {
        let auctionDomain = "cn.local.AShareDesktop.auction-total-tests.\(UUID().uuidString)"
        let auctionDefaults = UserDefaults(suiteName: auctionDomain)!
        defer { auctionDefaults.removePersistentDomain(forName: auctionDomain) }
        auctionDefaults.set("600108,002580,002491", forKey: "symbols")
        let at = ISO8601DateFormatter().date(from: "2026-10-12T\(time)+08:00")!
        let auction = QuoteStore(defaults: auctionDefaults, preview: nil, clock: { at })
        auction.suspend()
        check(auction.isAuction, "09:20和14:58均按竞价盘口估值")
        check(auction.valuationPrice(for: auction.symbols[0]) == nil, "无报价不伪造竞价估值")
        let heldFirst = auction.symbols[0], heldSecond = auction.symbols[1], watchOnly = auction.symbols[2]
        try auction.saveTracking(for: heldFirst, cost: "", quantity: "100", upper: "", lower: "",
                                 totalCost: "1005.08", now: at)
        try auction.saveTracking(for: heldSecond, cost: "", quantity: "200", upper: "", lower: "",
                                 totalCost: "2205", now: at)
        let savedCosts = auction.tracking.mapValues(\.totalCostYuan)
        let savedQuantities = auction.tracking.mapValues(\.quantity)
        let sourceTime = at.addingTimeInterval(-1)
        func book(_ symbol: StockSymbol, price: Double, bid: Double? = nil, ask: Double? = nil) -> Quote {
            Quote(symbol: symbol, name: "synthetic", price: price, previousClose: price,
                  change: 0, changePercent: 0, volumeLots: 100, amountYuan: 1000,
                  timestamp: sourceTime, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil,
                  bidPrice: bid, askPrice: ask)
        }
        let secondAsk = book(heldSecond, price: 10, ask: 10.11)
        let noPosition = book(watchOnly, price: 999)
        auction.receive([heldFirst.id: book(heldFirst, price: 12), heldSecond.id: secondAsk, watchOnly.id: noPosition],
                        requested: auction.symbols, at: at)
        check(auction.valuationPrice(for: heldFirst) == nil && auction.totalPositionProfit == nil,
              "竞价两侧无价时保留成交参考价，已持仓总盈亏不可显示完整数值")
        auction.receive([heldFirst.id: book(heldFirst, price: 12, bid: 12.34, ask: 12.56)],
                        requested: auction.symbols, at: at)
        check(auction.valuationPrice(for: heldFirst) == 12.34, "竞价买一优先于卖一和旧成交价")
        check(auction.valuationPrice(for: heldSecond) == 10.11, "竞价没有买一时以卖一估值")
        check(auction.valuationPrice(for: watchOnly) == nil && auction.totalPositionProfit == Decimal(string: "45.92"),
              "竞价合计按盘口价精确到分，未持仓股票缺盘口不参与")
        check(auction.quotes[heldFirst.id]?.price == 12 && auction.quotes[heldSecond.id]?.price == 10,
              "竞价估值不改写报价源的成交价")
        let updated = [heldFirst.id: book(heldFirst, price: 12, bid: 12.35, ask: 12.56),
                       heldSecond.id: book(heldSecond, price: 10, ask: 10.12)]
        auction.receive(updated, requested: auction.symbols, at: at)
        check(auction.totalPositionProfit == Decimal(string: "48.92")
              && auction.quotes[heldFirst.id]?.timestamp == sourceTime && auction.quotes[heldSecond.id]?.timestamp == sourceTime,
              "同源时间的盘口变化立即更新合计，不要求成交时间前进")
        auction.receive([heldFirst.id: book(heldFirst, price: 12, ask: 12.36)], requested: auction.symbols, at: at)
        check(auction.valuationPrice(for: heldFirst) == 12.36 && auction.totalPositionProfit == Decimal(string: "49.92"),
              "买一消失后立即使用卖一，持仓费用不重复扣除")
        auction.receive([heldFirst.id: book(heldFirst, price: 12)], requested: auction.symbols, at: at)
        check(auction.valuationPrice(for: heldFirst) == nil && auction.totalPositionProfit == nil
              && auction.quotes[heldFirst.id]?.price == 12, "盘口两侧消失后不沿用已失效竞价或旧成交价估值")
        let endTime = time == "09:20:00" ? "09:25:00" : "15:00:00"
        let auctionEnd = ISO8601DateFormatter().date(from: "2026-10-12T\(endTime)+08:00")!
        auction.receive(updated, requested: auction.symbols, at: auctionEnd)
        check(!auction.isAuction && auction.valuationPrice(for: heldFirst) == 12
              && auction.valuationPrice(for: heldSecond) == 10 && auction.totalPositionProfit == Decimal(string: "-10.08"),
              "竞价结束后统一恢复成交价及其持仓合计")
        if time == "09:20:00" {
            let continuous = ISO8601DateFormatter().date(from: "2026-10-12T09:30:00+08:00")!
            auction.receive(updated, requested: auction.symbols, at: continuous)
            check(auction.marketSession.phase == .trading && !auction.isAuction
                  && auction.valuationPrice(for: heldFirst) == 12 && auction.totalPositionProfit == Decimal(string: "-10.08"),
                  "09:30连续交易仍按成交价计算，不沿用竞价盘口")
        }
        check(auction.tracking.mapValues(\.totalCostYuan) == savedCosts && auction.tracking.mapValues(\.quantity) == savedQuantities,
              "盘口变化和竞价结束均不修改含费成本或持仓数量")
    }
    for (time, end) in [("09:20:00", "09:30:00"), ("14:58:00", "15:00:00")] {
        let alertDomain = "cn.local.AShareDesktop.auction-alert-tests.\(UUID().uuidString)"
        let alertDefaults = UserDefaults(suiteName: alertDomain)!
        defer { alertDefaults.removePersistentDomain(forName: alertDomain) }
        alertDefaults.set("600108", forKey: "symbols")
        let at = ISO8601DateFormatter().date(from: "2026-10-12T\(time)+08:00")!
        let alertStore = QuoteStore(defaults: alertDefaults, preview: nil, clock: { at })
        alertStore.suspend()
        let symbol = alertStore.symbols[0]
        try alertStore.saveTracking(for: symbol, cost: "", quantity: "", upper: "", lower: "10.20",
                                    now: at.addingTimeInterval(-5))
        var alerts = 0
        alertStore.onPriceAlert = { _ in alerts += 1 }
        func alertQuote(at date: Date) -> Quote {
            Quote(symbol: symbol, name: "synthetic", price: 10, previousClose: 10,
                  change: 0, changePercent: 0, volumeLots: 100, amountYuan: 1000,
                  timestamp: date, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil,
                  bidPrice: 11, askPrice: 11)
        }
        alertStore.receive([symbol.id: alertQuote(at: at)], requested: alertStore.symbols, at: at)
        check(alerts == 0 && alertStore.tracking[symbol.id]?.lowerTriggered == false,
              "竞价盘口刷新时旧成交价不得触发提醒或消耗机会")
        let boundaryTime = time == "09:20:00" ? "09:25:00" : "15:00:00"
        let boundary = ISO8601DateFormatter().date(from: "2026-10-12T\(boundaryTime)+08:00")!
        alertStore.receive([symbol.id: alertQuote(at: boundary.addingTimeInterval(-1))],
                           requested: alertStore.symbols, at: boundary)
        check(alerts == 0 && alertStore.tracking[symbol.id]?.lowerTriggered == false,
              "跨竞价结束边界晚到的竞价包也不触发成交价提醒")
        let after = ISO8601DateFormatter().date(from: "2026-10-12T\(end)+08:00")!
        alertStore.receive([symbol.id: alertQuote(at: after)], requested: alertStore.symbols, at: after)
        check(alerts == 1 && alertStore.tracking[symbol.id]?.lowerTriggered == true,
              "竞价结束后新成交报价仍按原阈值触发一次提醒")
    }
    return count
}
