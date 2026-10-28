import Foundation

private struct StockListTestFailure: Error { let message: String }

private final class StockListProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requested: [[String]] = []
    static let quoteTime = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00+08:00")!

    static var requests: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let ids = request.url!.absoluteString.components(separatedBy: "q=").last!
            .split(separator: ",").map(String.init)
        Self.lock.lock(); Self.requested.append(ids); Self.lock.unlock()
        let text = ids.map { id -> String in
            var fields = Array(repeating: "", count: 58)
            fields[1] = "offline-stock-list"; fields[2] = String(id.dropFirst(2))
            fields[3] = "12"; fields[4] = "10"; fields[30] = "20261026100000"
            fields[31] = "2"; fields[32] = "20"; fields[36] = "100"; fields[37] = "1"
            return "v_\(id)=\"\(fields.joined(separator: "~"))\";"
        }.joined(separator: "\n")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func runStockListTests() throws -> Int {
    var domains: [String] = []
    var stores: [QuoteStore] = []
    defer {
        stores.forEach { $0.stop() }
        domains.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    }
    let now = StockListProtocol.quoteTime
    let first = StockSymbol(code: "600108", market: "sh")
    let second = StockSymbol(code: "002580", market: "sz")
    let third = StockSymbol(code: "002491", market: "sz")
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw StockListTestFailure(message: message) }
        checks += 1
    }
    func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() }
        catch { checks += 1; return }
        throw StockListTestFailure(message: message)
    }
    func defaults(holdings: String = "", watchlist: String? = nil) -> UserDefaults {
        let domain = "cn.local.AShareDesktop.stock-list-tests.\(UUID().uuidString)"
        domains.append(domain)
        let result = UserDefaults(suiteName: domain)!
        result.set(holdings, forKey: "symbols")
        if let watchlist { result.set(watchlist, forKey: "watchlistSymbols") }
        return result
    }
    func store(_ defaults: UserDefaults) -> QuoteStore {
        let client = QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [StockListProtocol.self]
            return URLSession(configuration: configuration)
        })
        let value = QuoteStore(defaults: defaults, preview: nil, client: client, clock: { now })
        value.suspend()
        stores.append(value)
        return value
    }
    func quote(_ symbol: StockSymbol, price: Double = 12) -> Quote {
        Quote(symbol: symbol, name: "offline-list", price: price, previousClose: 10,
              change: price - 10, changePercent: (price - 10) * 10, volumeLots: 100, amountYuan: 1000,
              timestamp: now, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
    }
    func spin(_ seconds: TimeInterval = 0.5, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    func records(_ defaults: UserDefaults) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: defaults.data(forKey: "stockTracking")!) as! [String: Any]
    }

    // Existing storage is the complete holdings list, including entries without a valid position.
    let legacyDefaults = defaults(holdings: "600108,002580,002491")
    legacyDefaults.set(0.42, forKey: "backgroundTransparency")
    legacyDefaults.set(true, forKey: "pinned")
    legacyDefaults.set(false, forKey: "autoHideEnabled")
    legacyDefaults.set("1.2", forKey: "buyCommissionRate")
    var precise = try StockTracking.parse(cost: "", quantity: "500", upper: "13", lower: "9",
                                         perShareCost: "10.12345678")
    precise.upperTriggered = true
    precise.armedAt = now.addingTimeInterval(-60)
    let invalid = StockTracking(costPrice: 10, quantity: -100, upperPrice: 11, upperTriggered: true)
    let raw: [String: Any] = ["quantity": "broken", "totalCostYuan": NSDecimalNumber(string: "5062.08"),
                              "upperPrice": 11, "upperTriggered": true, "lowerTriggered": false]
    legacyDefaults.set(try JSONSerialization.data(withJSONObject: [
        first.id: JSONSerialization.jsonObject(with: JSONEncoder().encode(precise)),
        second.id: JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)), third.id: raw
    ]), forKey: "stockTracking")
    let legacy = store(legacyDefaults)
    try check(legacy.selectedList == .holdings && legacy.symbols == [first, second, third],
              "旧列表默认完整归入持仓页，不按持仓字段重新分组")
    try check(legacy.watchlistSymbols.isEmpty && legacy.visibleSymbols == legacy.symbols,
              "旧用户自选页初始为空，默认可见旧列表")
    try check(legacy.tracking[first.id] == precise && legacy.invalidTracking[second.id] == invalid,
              "升级保留精确成本、提醒触达状态和非法配置原字段")
    try check(legacy.backgroundTransparency == 0.42 && legacy.isPinned && !legacy.autoHideEnabled
              && legacy.buyCommissionRate == "1.2", "双页签不更改已有外观与佣金设置")
    legacy.selectList(.watchlist)
    try legacy.addSymbols("600519")
    try check((try records(legacyDefaults)[third.id] as? NSDictionary)?.isEqual(to: raw) == true,
              "添加自选股票不能丢弃持仓页无法解码的原始记录")
    let legacyReloaded = store(legacyDefaults)
    try check(legacyReloaded.selectedList == .holdings && legacyReloaded.symbols == [first, second, third]
              && legacyReloaded.watchlistSymbols.map(\.id) == ["sh600519"],
              "两页独立恢复，重启始终默认持仓页")
    try check(legacyReloaded.tracking[first.id] == precise && legacyReloaded.invalidTracking[second.id] == invalid,
              "自选页保存后重启仍保留旧精确配置与异常值")

    let membershipDefaults = defaults(holdings: "600108")
    let membership = store(membershipDefaults)
    try membership.saveTracking(for: first, cost: "10", quantity: "100", upper: "11", lower: "",
                                now: now.addingTimeInterval(-60))
    membership.receive([first.id: quote(first)], requested: [first], at: now)
    let triggered = membership.tracking[first.id]
    membership.selectList(.watchlist)
    try membership.addSymbols("600108,002580,002580")
    try check(membership.symbols == [first] && membership.watchlistSymbols == [first, second]
              && membership.allSymbols == [first, second], "自选增量添加只改当前页，并集按股票去重")
    try check(membership.visibleSymbols == [first, second], "自选页显示自身顺序")
    membership.removeSymbol(first)
    try check(membership.symbols == [first] && membership.watchlistSymbols == [second]
              && membership.tracking[first.id] == triggered && membership.quotes[first.id] != nil,
              "从自选移除同股时保留持仓页、行情、成本和已触达提醒")
    try membership.addSymbols("600108")
    membership.selectList(.holdings)
    membership.removeSymbol(first)
    try check(membership.symbols.isEmpty && membership.watchlistSymbols == [second, first]
              && membership.tracking[first.id] == triggered && membership.priceAlerts[first.id] != nil,
              "从持仓移除同股时保留自选页配置和提醒显示")
    try check(membership.totalPositionProfit == 0, "股票仅留自选后不再计入持仓总盈亏")
    let membershipReloaded = store(membershipDefaults)
    try check(membershipReloaded.symbols.isEmpty && membershipReloaded.watchlistSymbols == [second, first]
              && membershipReloaded.tracking[first.id] == triggered,
              "仅在自选的股票重启仍恢复精确配置和触达状态")
    membership.selectList(.watchlist)
    membership.removeSymbol(first)
    try check(membership.tracking[first.id] == nil && membership.quotes[first.id] == nil
              && membership.priceAlerts[first.id] == nil, "最后一个页签删除后清理共享配置、行情和提醒")
    try check(try records(membershipDefaults)[first.id] == nil, "最后删除的配置不会在持久化中残留")
    try membership.addSymbols("600108")
    try check(membership.tracking[first.id] == nil && membership.quotes[first.id] == nil,
              "最后删除后重新添加不会复活旧配置或报价")
    try membership.saveSymbols("")
    try check(membership.watchlistSymbols.isEmpty && membership.symbols.isEmpty,
              "清空当前页可以持久化为空，不回填旧股票")

    // Invalid and undecodable records obey the same cross-list membership lifetime.
    legacy.selectList(.watchlist)
    try legacy.addSymbols("002580,002491")
    legacy.selectList(.holdings)
    legacy.removeSymbol(second)
    legacy.removeSymbol(third)
    try check(legacy.invalidTracking[second.id] == invalid
              && (try records(legacyDefaults)[third.id] as? NSDictionary)?.isEqual(to: raw) == true,
              "异常与无法解码配置只剩自选成员时仍保留原字段")
    legacy.selectList(.watchlist)
    legacy.removeSymbol(second)
    legacy.removeSymbol(third)
    let cleaned = try records(legacyDefaults)
    try check(legacy.invalidTracking[second.id] == nil && cleaned[second.id] == nil && cleaned[third.id] == nil,
              "最后删除同时清理非法和无法解码记录")
    try check(legacy.trackingStorageNotice == nil, "删除最后一条无法解码记录后解除存储提示")

    let capacity = store(defaults())
    let holdingCodes = (0..<20).map { String(format: "600%03d", $0) }.joined(separator: ",")
    let watchingCodes = (20..<40).map { String(format: "600%03d", $0) }.joined(separator: ",")
    try capacity.saveSymbols(holdingCodes)
    capacity.selectList(.watchlist)
    try capacity.saveSymbols(watchingCodes)
    try check(capacity.symbols.count == 20 && capacity.watchlistSymbols.count == 20 && capacity.allSymbols.count == 40,
              "两个页签各支持20只独立股票")
    try rejects({ try capacity.addSymbols("002580") }, "自选第21只应拒绝")
    capacity.selectList(.holdings)
    try rejects({ try capacity.addSymbols("002580") }, "持仓第21只应拒绝")
    try check(capacity.symbols.count == 20 && capacity.watchlistSymbols.count == 20,
              "任一页超限失败不能影响另一页或原列表")
    capacity.start()
    spin(until: { capacity.quotes.count == 40 || capacity.errorMessage != nil })
    try check(capacity.quotes.count == 40 && capacity.errorMessage == nil,
              "40只并集通过真实QuoteClient加隔离传输完成批量解析")
    try check(StockListProtocol.requests.last == capacity.allSymbols.map(\.id),
              "批量报价请求覆盖两页去重并集")
    capacity.stop()

    let live = store(defaults(holdings: "600108", watchlist: "002580"))
    try live.saveTracking(for: first, cost: "10", quantity: "100", upper: "11", lower: "",
                          now: now.addingTimeInterval(-60))
    live.selectList(.watchlist)
    try live.saveTracking(for: second, cost: "9", quantity: "100", upper: "11", lower: "",
                          now: now.addingTimeInterval(-60))
    var alerts: [String] = []
    live.onPriceAlert = { alerts.append($0.symbolID) }
    live.start()
    spin(until: { live.quotes.count == 2 && !live.isRefreshing })
    try check(live.quotes[first.id]?.price == 12 && live.quotes[second.id]?.price == 12,
              "停留自选页时隐藏持仓页仍更新行情")
    try check(Set(alerts) == Set([first.id, second.id]) && alerts.count == 2,
              "隐藏页和可见页提醒都正常触发一次")
    try check(live.totalPositionProfit == 200, "自选卡片虽能填成本，持仓总盈亏仍只计算持仓页")
    live.selectList(.holdings)
    try check(live.totalPositionProfit == 200, "切页不改变持仓总盈亏含义")
    live.rearmAlerts(for: second, now: now.addingTimeInterval(-1))
    live.refresh()
    spin(until: { alerts.count == 3 && !live.isRefreshing })
    try check(alerts.filter { $0 == first.id }.count == 1 && alerts.filter { $0 == second.id }.count == 2,
              "切回持仓后隐藏自选仍提醒，另一只已触达状态不重置")
    try live.saveSymbols("")
    spin(until: { !live.isRefreshing && live.quotes.count == 1 })
    try check(live.visibleSymbols.isEmpty && live.quotes[second.id]?.price == 12
              && live.totalPositionProfit == 0, "清空可见持仓页仍保留隐藏自选行情")
    let requestsBeforeTick = StockListProtocol.requests.count
    spin(1.3, until: { StockListProtocol.requests.count > requestsBeforeTick })
    try check(StockListProtocol.requests.count > requestsBeforeTick && StockListProtocol.requests.last == [second.id],
              "当前页为空时，隐藏自选仍保持行情轮询")
    live.stop()

    for bad in [raw, try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid)) as! [String: Any]] {
        let damagedDefaults = defaults(holdings: "600108", watchlist: "002580")
        let held = try StockTracking.parse(cost: "10", quantity: "100", upper: "", lower: "")
        damagedDefaults.set(try JSONSerialization.data(withJSONObject: [
            first.id: JSONSerialization.jsonObject(with: JSONEncoder().encode(held)), second.id: bad
        ]), forKey: "stockTracking")
        let damaged = store(damagedDefaults)
        damaged.receive([first.id: quote(first)], requested: damaged.allSymbols, at: now)
        try check(damaged.totalPositionProfit == 200, "仅自选的非法或无法解码成本不能阻断持仓合计")
        damaged.selectList(.watchlist)
        try check(damaged.totalPositionProfit == 200, "自选异常配置不会在切页后改变持仓合计")
        damaged.selectList(.holdings)
        try damaged.addSymbols("002580")
        try check(damaged.totalPositionProfit == nil, "同一坏配置加入持仓后必须阻断不完整合计")
    }

    let layout = store(defaults(holdings: "600108,002580"))
    layout.receive([first.id: quote(first), second.id: quote(second)], requested: layout.allSymbols, at: now)
    layout.toggleIntraday(for: first)
    layout.expandedSymbolID = first.id
    layout.isAddingStock = true
    try check(layout.expandedChartSymbolID == first.id, "切页测试先建立展开图表状态")
    layout.selectList(.watchlist)
    try check(layout.expandedChartSymbolID == nil && layout.expandedSymbolID == nil && !layout.isAddingStock,
              "切页收起分时、持仓编辑和添加输入")
    try check(layout.visibleSymbols.isEmpty && layout.listHeight == 198,
              "自选空页使用空态高度，不沿用持仓列表高度")
    try check(layout.quotes.count == 2 && layout.symbols == [first, second],
              "切页不会清除隐藏页列表及已有行情")
    try layout.addSymbols("002491")
    try check(layout.visibleSymbols == [third] && layout.listHeight == 96,
              "自选添加后高度仅由当前页卡片计算")
    layout.selectList(.holdings)
    try check(layout.visibleSymbols == [first, second] && layout.listHeight == 193,
              "返回持仓页恢复其两张卡片高度")
    return checks
}
