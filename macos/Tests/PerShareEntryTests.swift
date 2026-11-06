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
    return checks
}
