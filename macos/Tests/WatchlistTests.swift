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
        let exactData = Data(#"{"sh600108":{"costPrice":10.123,"quantity":500,"totalCostYuan":5062.08,"upperPrice":13,"upperTriggered":true,"lowerTriggered":false,"armedAt":100}}"#.utf8)
        defaults.set(exactData, forKey: "stockTracking")
        let exactStore = QuoteStore(defaults: defaults, preview: nil)
        exactStore.suspend()
        let exactProfit = exactStore.tracking[primary.id]?.profit(at: 12)
        check(exactProfit.map { Decimal(string: String(describing: $0.amount)) == Decimal(string: "937.92") } == true, "加载精确总成本后不再放大单股成本舍入误差")
        try exactStore.saveTracking(for: primary, cost: "", quantity: "500", upper: "13", lower: "", totalCost: "5063.10")
        let savedExact = QuoteStore(defaults: defaults, preview: nil)
        savedExact.suspend()
        check(savedExact.tracking[primary.id]?.totalCostYuan == Decimal(string: "5063.10"), "总成本保存重启后保留到分")
        check(savedExact.tracking[primary.id]?.upperTriggered == true && savedExact.tracking[primary.id]?.armedAt == exactStore.tracking[primary.id]?.armedAt, "修改总成本不重置已触发的未变阈值")
        check(savedExact.tracking[primary.id]?.profit(at: 12)?.amountText == "+936.90", "新总成本直接用于盈亏并补足两位小数")
        let beforeBadTotal = exactStore.tracking[primary.id]
        rejects({ try exactStore.saveTracking(for: primary, cost: "", quantity: "500", upper: "13", lower: "", totalCost: "5063.101") }, "总成本超过两位小数不能保存")
        check(exactStore.tracking[primary.id] == beforeBadTotal, "无效总成本不能破坏已有持仓与提醒")
        try exactStore.saveTracking(for: primary, cost: "", quantity: "", upper: "13", lower: "", totalCost: "")
        check(exactStore.tracking[primary.id]?.hasPosition == false && exactStore.tracking[primary.id]?.upperTriggered == true, "清空总成本和股数可关闭持仓并保留提醒")
        try exactStore.savePosition(for: primary, amount: "40000", quantity: "4000", upper: "13", lower: "",
                                    estimateFees: true, commissionRate: "2.5")
        check(exactStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40010.40") && exactStore.tracking[primary.id]?.purchaseAmountYuan == 40000, "沪市成交金额自动加预估佣金和过户费，并保存原金额")
        check(exactStore.tracking[primary.id]?.profit(at: 10)?.amountText == "-10.40", "自动买入费用实际计入持仓盈亏")
        check(exactStore.tracking[primary.id]?.upperTriggered == true, "估算费用不重置未改阈值的已提醒状态")
        let reloadedFeeStore = QuoteStore(defaults: defaults, preview: nil)
        reloadedFeeStore.suspend()
        check(reloadedFeeStore.tracking[primary.id] == exactStore.tracking[primary.id] && reloadedFeeStore.buyCommissionRate == "2.5", "费用口径及一次设置的佣金率可恢复")
        try reloadedFeeStore.savePosition(for: primary, amount: "40000", quantity: "4000", upper: "13", lower: "",
                                          estimateFees: true, commissionRate: "2.5")
        check(reloadedFeeStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40010.40"), "用保存的原成交金额再保存不会重复加手续费")
        try exactStore.savePosition(for: secondary, amount: "10000", quantity: "1000", upper: "", lower: "",
                                    estimateFees: true, commissionRate: "2.5")
        check(exactStore.tracking[secondary.id]?.totalCostYuan == 10005 && exactStore.tracking[secondary.id]?.purchaseAmountYuan == 10000, "深圳按公示及预估口径收最低佣金")
        let beforeFeeError = exactStore.tracking[primary.id]
        rejects({ try exactStore.savePosition(for: primary, amount: "40000", quantity: "4000", upper: "13", lower: "", estimateFees: true, commissionRate: "abc") }, "无效佣金率不能保存")
        check(exactStore.tracking[primary.id] == beforeFeeError && exactStore.buyCommissionRate == "2.5", "无效费率保留原持仓和设置")
        try exactStore.savePosition(for: primary, amount: "40000", quantity: "4000", upper: "13", lower: "",
                                    estimateFees: true, commissionRate: "1.8")
        check(exactStore.buyCommissionRate == "1.8" && exactStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40007.60"), "修改账户佣金率后按新费率估算并记住")
        let feeRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(exactStore.tracking[primary.id]!)) as! [String: Any]
        check((feeRecord["purchaseCommissionRate"] as? NSNumber)?.decimalValue == Decimal(string: "1.8"), "每笔持仓保存采用的费率，不能仅依赖后来变化的全局费率")
        try exactStore.savePosition(for: secondary, amount: "10000", quantity: "1000", upper: "", lower: "",
                                    estimateFees: true, commissionRate: "3")
        let historicalStore = QuoteStore(defaults: defaults, preview: nil)
        historicalStore.suspend()
        let historicalPosition = historicalStore.tracking[primary.id]!
        check(historicalStore.buyCommissionRate == "3" && historicalPosition.purchaseCommissionRate == Decimal(string: "1.8"), "新持仓改变全局费率不能改变旧持仓所用费率")
        try historicalStore.savePosition(for: primary,
                                          amount: NSDecimalNumber(decimal: historicalPosition.purchaseAmountYuan!).stringValue,
                                          quantity: "4000", upper: "13", lower: "", estimateFees: true,
                                          commissionRate: NSDecimalNumber(decimal: historicalPosition.purchaseCommissionRate!).stringValue)
        check(historicalStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40007.60"), "重开旧持仓使用该笔费率，仅编辑提醒不重算为全局新费率")
        check(historicalStore.buyCommissionRate == "3", "重存旧持仓未修改费率时不把全局新费率改回旧值")
        try exactStore.savePosition(for: primary, amount: "40007.59", quantity: "4000", upper: "13", lower: "",
                                    estimateFees: false, commissionRate: "abc")
        check(exactStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40007.59") && exactStore.tracking[primary.id]?.purchaseAmountYuan == nil, "实际含费总成本不再扣费，也不再标记预估")
        check(exactStore.buyCommissionRate == "3" && exactStore.tracking[primary.id]?.upperTriggered == true && exactStore.tracking[primary.id]?.purchaseCommissionRate == nil, "按实核对保留佣金设置及已提醒状态，并清除预估费率")
        let actualBeforeAlertEdit = exactStore.tracking[primary.id]!
        var alertEditError: Error?
        do {
            try exactStore.savePosition(for: primary, amount: " \n ", quantity: " 4000 ", upper: "13", lower: "9",
                                        estimateFees: true, commissionRate: "abc", now: Date(timeIntervalSince1970: 2000))
        } catch { alertEditError = error }
        check(alertEditError == nil, "实际持仓普通编辑未填成交金额且股数不变时，保存提醒应保留已有成本")
        let actualAfterAlertEdit = exactStore.tracking[primary.id]!
        check(actualAfterAlertEdit.totalCostYuan == actualBeforeAlertEdit.totalCostYuan && actualAfterAlertEdit.costPrice == actualBeforeAlertEdit.costPrice
              && actualAfterAlertEdit.quantity == actualBeforeAlertEdit.quantity && actualAfterAlertEdit.purchaseAmountYuan == nil && actualAfterAlertEdit.purchaseCommissionRate == nil,
              "仅编辑提醒不能把实际总成本改为空或转为费用预估")
        check(actualAfterAlertEdit.lowerPrice == 9 && actualAfterAlertEdit.upperTriggered && actualAfterAlertEdit.armedAt == Date(timeIntervalSince1970: 2000),
              "保留持仓时仍保存新的提醒，并保留未变阈值的触发标记")
        check(exactStore.buyCommissionRate == "3", "仅保存提醒不校验或改写账户费率")
        let actualAlertReloaded = QuoteStore(defaults: defaults, preview: nil)
        actualAlertReloaded.suspend()
        check(actualAlertReloaded.tracking[primary.id] == actualAfterAlertEdit, "提醒编辑后重启仍保留实际总成本")
        try exactStore.savePosition(for: primary, amount: "40000", quantity: "4000", upper: "13", lower: "9",
                                    estimateFees: true, commissionRate: "2.5")
        check(exactStore.tracking[primary.id]?.totalCostYuan == Decimal(string: "40010.40") && exactStore.tracking[primary.id]?.purchaseAmountYuan == 40000,
              "已有实际持仓填写新的成交金额时仍自动计入费用")
        let estimatedBeforeBlank = exactStore.tracking[primary.id]
        rejects({ try exactStore.savePosition(for: primary, amount: "", quantity: "4000", upper: "13", lower: "9", estimateFees: true, commissionRate: "2.5") },
                "已有原成交金额的预估持仓不能用空金额覆盖")
        check(exactStore.tracking[primary.id] == estimatedBeforeBlank, "拒绝空成交金额后预估持仓保持不变")
        try exactStore.savePosition(for: primary, amount: "1005", quantity: "100", upper: "13", lower: "9",
                                    estimateFees: false, commissionRate: "2.5")
        let actualBeforeBadQuantity = exactStore.tracking[primary.id]
        rejects({ try exactStore.savePosition(for: primary, amount: "", quantity: "101", upper: "13", lower: "9", estimateFees: true, commissionRate: "2.5") },
                "成交金额空而股数变化时仍要求配对输入")
        rejects({ try exactStore.savePosition(for: primary, amount: "", quantity: "0100", upper: "13", lower: "9", estimateFees: true, commissionRate: "2.5") },
                "股数需在去除首尾空白后与原文本完全相同才保留持仓")
        check(exactStore.tracking[primary.id] == actualBeforeBadQuantity, "配对输入拒绝不会改写原持仓")
        try exactStore.savePosition(for: primary, amount: "", quantity: "", upper: "13", lower: "9", estimateFees: true, commissionRate: "2.5")
        check(exactStore.tracking[primary.id]?.hasPosition == false && exactStore.tracking[primary.id]?.upperPrice == 13,
              "成交金额和股数同时清空仍可删除持仓并保留提醒")
        try exactStore.saveTracking(for: primary, cost: "10.123", quantity: "500", upper: "13", lower: "9")
        let legacyBeforeAlertEdit = exactStore.tracking[primary.id]!
        try exactStore.savePosition(for: primary, amount: "", quantity: "500", upper: "14", lower: "9",
                                    estimateFees: true, commissionRate: "abc")
        check(exactStore.tracking[primary.id]?.costPrice == legacyBeforeAlertEdit.costPrice && exactStore.tracking[primary.id]?.quantity == 500
              && exactStore.tracking[primary.id]?.totalCostYuan == nil && exactStore.tracking[primary.id]?.purchaseAmountYuan == nil,
              "旧均价持仓仅改提醒时保持旧存储口径，不升级为估算总成本")
        let legacyAlertReloaded = QuoteStore(defaults: defaults, preview: nil)
        legacyAlertReloaded.suspend()
        check(legacyAlertReloaded.tracking[primary.id]?.totalCostYuan == nil && legacyAlertReloaded.tracking[primary.id]?.profit(at: 12)?.amountText == "+938.50",
              "旧均价持仓保存提醒重启后仍按原成本计算")
        defaults.set(try JSONEncoder().encode([primary.id: malformed]), forKey: "stockTracking")
        let invalidAlertStore = QuoteStore(defaults: defaults, preview: nil)
        invalidAlertStore.suspend()
        rejects({ try invalidAlertStore.savePosition(for: primary, amount: "", quantity: "100", upper: "13", lower: "9", estimateFees: true, commissionRate: "2.5") },
                "异常旧配置不能借空成交金额保存进入保留持仓分支")
        check(invalidAlertStore.tracking[primary.id] == nil && invalidAlertStore.invalidTracking[primary.id] == malformed,
              "异常配置需要明确修正，原数据仍保留")
        let undecodableRecord: [String: Any] = ["costPrice": 10, "quantity": "broken", "totalCostYuan": NSDecimalNumber(string: "5062.08"), "upperPrice": 11,
                                              "upperTriggered": true, "lowerTriggered": false, "armedAt": 100]
        let validRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        let partiallyDamagedData = try JSONSerialization.data(withJSONObject: [primary.id: undecodableRecord, secondary.id: validRecord])
        defaults.set("600108,002580", forKey: "symbols")
        defaults.set(partiallyDamagedData, forKey: "stockTracking")
        let partiallyDamagedStore = QuoteStore(defaults: defaults, preview: nil)
        partiallyDamagedStore.suspend()
        check(partiallyDamagedStore.tracking[secondary.id] == valid, "单条类型损坏不能丢弃其他合法持仓及已提醒状态")
        check(partiallyDamagedStore.tracking[primary.id] == nil && partiallyDamagedStore.invalidTracking[primary.id] == nil,
              "不能解码的原始条目不能用于盈亏或提醒")
        check(partiallyDamagedStore.trackingStorageNotice != nil, "单条无法解码时提供持续的配置提示")
        var damagedAlerts = 0
        partiallyDamagedStore.onPriceAlert = { _ in damagedAlerts += 1 }
        partiallyDamagedStore.evaluateAlerts([primary.id: marketQuote(primary, 12, 1100)], now: Date(timeIntervalSince1970: 1100))
        check(damagedAlerts == 0, "不能解码的配置不能消耗提醒机会")
        try partiallyDamagedStore.saveTracking(for: secondary, cost: "20.5", quantity: "200", upper: "21", lower: "")
        try partiallyDamagedStore.addSymbols("600519")
        let partiallySaved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "stockTracking")!) as! [String: Any]
        check((partiallySaved[primary.id] as? NSDictionary)?.isEqual(to: undecodableRecord) == true,
              "保存另一只及增加股票必须保留无法解码条目的原始字段")
        let partiallyReloaded = QuoteStore(defaults: defaults, preview: nil)
        partiallyReloaded.suspend()
        check(partiallyReloaded.tracking[secondary.id]?.costPrice == 20.5 && partiallyReloaded.tracking[secondary.id]?.upperTriggered == true,
              "损坏条目并存时正常保存可重启恢复且不重置未改阈值")
        try partiallyReloaded.saveTracking(for: primary, cost: "10", quantity: "100", upper: "12", lower: "9")
        let correctedRecords = try JSONDecoder().decode([String: StockTracking].self, from: defaults.data(forKey: "stockTracking")!)
        check(correctedRecords[primary.id]?.quantity == 100 && correctedRecords[secondary.id]?.costPrice == 20.5,
              "主动修正对应股票替换原始坏条目且保留其他配置")
        check(partiallyReloaded.trackingStorageNotice == nil, "主动修正最后一个坏条目后清理配置提示")
        defaults.set(partiallyDamagedData, forKey: "stockTracking")
        let rawRemovalStore = QuoteStore(defaults: defaults, preview: nil)
        rawRemovalStore.suspend()
        rawRemovalStore.removeSymbol(primary)
        let remainingRecords = try JSONDecoder().decode([String: StockTracking].self, from: defaults.data(forKey: "stockTracking")!)
        check(remainingRecords[primary.id] == nil && remainingRecords[secondary.id] == valid,
              "主动删除对应股票清理原始坏条目，不影响其他持仓")
        check(rawRemovalStore.trackingStorageNotice == nil, "主动删除最后一个坏条目后清理配置提示")
        for brokenData in [Data("not JSON".utf8), Data("[]".utf8), Data("null".utf8)] {
            defaults.set("600108,002580", forKey: "symbols")
            defaults.set(brokenData, forKey: "stockTracking")
            let brokenStore = QuoteStore(defaults: defaults, preview: nil)
            brokenStore.suspend()
            check(defaults.data(forKey: "stockTrackingCorruptBackup") == brokenData,
                  "整个配置不是JSON字典时必须备份原始字节")
            check(brokenStore.tracking.isEmpty && brokenStore.invalidTracking.isEmpty,
                  "整个存储损坏时不能恢复任何持仓或提醒")
            check(brokenStore.trackingStorageNotice != nil, "整个配置损坏和备份结果必须提供可见提示")
            try brokenStore.saveTracking(for: secondary, cost: "20", quantity: "200", upper: "21", lower: "")
            check(defaults.data(forKey: "stockTrackingCorruptBackup") == brokenData,
                  "重新录入合法配置不能覆盖损坏原始备份")
            let recoveredStore = QuoteStore(defaults: defaults, preview: nil)
            recoveredStore.suspend()
            check(recoveredStore.tracking[secondary.id]?.quantity == 200,
                  "备份后主动重新录入的配置可正常恢复")
            check(defaults.data(forKey: "stockTrackingCorruptBackup") == brokenData,
                  "正常重启不能改动原始备份")
        }
        for extreme in ["1e300", "1e-300"] {
            var wideRecord = try StockTracking.parse(cost: extreme, quantity: "1", upper: extreme, lower: "")
            wideRecord.upperTriggered = true
            wideRecord.armedAt = Date(timeIntervalSince1970: 100)
            let preciseRecord = StockTracking(quantity: 500, upperPrice: 13, upperTriggered: true,
                                               armedAt: Date(timeIntervalSince1970: 100), totalCostYuan: Decimal(string: "5062.08"))
            defaults.set("600108,002580", forKey: "symbols")
            defaults.set(try JSONEncoder().encode([primary.id: wideRecord, secondary.id: preciseRecord]), forKey: "stockTracking")
            let wideStore = QuoteStore(defaults: defaults, preview: nil)
            wideStore.suspend()
            check(wideStore.tracking[primary.id] == wideRecord && wideStore.trackingStorageNotice == nil,
                  "超出Decimal范围的有限Double旧成本与提醒仍可恢复")
            check(wideStore.tracking[secondary.id]?.totalCostYuan == Decimal(string: "5062.08")
                  && wideStore.tracking[secondary.id]?.profit(at: 12)?.amountText == "+937.92",
                  "有限Double旧记录不能影响其他持仓的Decimal精度")
            try wideStore.saveTracking(for: secondary, cost: "", quantity: "500", upper: "13", lower: "", totalCost: "5063.10")
            let savedWideRecords = try JSONDecoder().decode([String: StockTracking].self, from: defaults.data(forKey: "stockTracking")!)
            check(savedWideRecords[primary.id] == wideRecord && savedWideRecords[secondary.id]?.totalCostYuan == Decimal(string: "5063.10"),
                  "保存精确成本仍保留超Decimal范围的另一只股票字段")
            try wideStore.saveTracking(for: primary, cost: extreme, quantity: "2", upper: extreme, lower: "")
            let wideReloaded = QuoteStore(defaults: defaults, preview: nil)
            wideReloaded.suspend()
            check(wideReloaded.tracking[primary.id]?.quantity == 2 && wideReloaded.tracking[primary.id]?.upperPrice == Double(extreme),
                  "有限Double新保存必须真正落盘并在重启后恢复")
            check(wideReloaded.tracking[primary.id]?.upperTriggered == true
                  && wideReloaded.tracking[primary.id]?.armedAt == wideRecord.armedAt,
                  "仅修改持仓不能重置超Decimal范围的旧提醒状态")
        }
        print("PASS: \(count) watchlist assertions")
        print("PASS: \(try runTotalProfitTests()) total-profit assertions")
    }
}
