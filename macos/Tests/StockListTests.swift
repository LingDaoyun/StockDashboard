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
            fields[33] = "13"; fields[34] = "9"
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
    let index = StockSymbol(code: "980017", market: "sz")
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
    func store(_ defaults: UserDefaults, at date: Date? = nil) -> QuoteStore {
        let client = QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [StockListProtocol.self]
            return URLSession(configuration: configuration)
        })
        let value = QuoteStore(defaults: defaults, preview: nil, client: client, clock: { date ?? now })
        value.suspend()
        stores.append(value)
        return value
    }
    func quote(_ symbol: StockSymbol, price: Double = 12, at date: Date? = nil) -> Quote {
        Quote(symbol: symbol, name: "offline-list", price: price, previousClose: 10,
              change: price - 10, changePercent: (price - 10) * 10, volumeLots: 100, amountYuan: 1000,
              timestamp: date ?? now, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
    }
    func spin(_ seconds: TimeInterval = 1, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    func records(_ defaults: UserDefaults) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: defaults.data(forKey: "stockTracking")!) as! [String: Any]
    }

    let indexIDs = DashboardIndex.symbols.map(\.id)
    try check(indexIDs.count == 8 && Set(indexIDs).count == indexIDs.count,
              "综合指数固定目录包含8个独立指数")
    try check(Set(["sz980017", "sh000688", "sz399006"]).isSubset(of: Set(indexIDs)),
              "目录包含已核实的国证芯片、科创50、创业板指代码")
    try check(StockList.allCases == [.holdings, .indices] && StockList.indices.title == "综合指数",
              "自选页签由综合指数替代")

    // Upgrade preserves old costs and undecodable records without activating the retired list.
    let legacyDefaults = defaults(holdings: "600108", watchlist: "002580,002491")
    legacyDefaults.set(0.42, forKey: "backgroundTransparency")
    legacyDefaults.set(true, forKey: "pinned")
    legacyDefaults.set(false, forKey: "autoHideEnabled")
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
    try check(legacy.selectedList == .holdings && legacy.visibleSymbols == [first]
              && legacy.allSymbols == [first], "升级默认显示持仓且不请求旧自选列表")
    try check(legacy.legacyWatchlistSymbols == [second, third] && legacy.tracking[first.id] == precise,
              "旧自选成员和精确持仓成本完整保留")
    try check(legacy.backgroundTransparency == 0.42 && legacy.isPinned && !legacy.autoHideEnabled,
              "替换页签不改已有外观设置")
    try legacy.addSymbols("600519")
    legacy.removeSymbol(StockSymbol(code: "600519", market: "sh"))
    try check(legacyDefaults.string(forKey: "watchlistSymbols") == "002580,002491",
              "持仓增删不覆盖旧自选列表存储")
    try check((try records(legacyDefaults)[third.id] as? NSDictionary)?.isEqual(to: raw) == true,
              "持仓保存不改写旧自选无法解码的原始字段")
    let reloaded = store(legacyDefaults)
    try check(reloaded.symbols == [first] && reloaded.tracking[first.id] == precise
              && reloaded.invalidTracking[second.id] == invalid,
              "升级保存并重启后仍恢复持仓及旧异常配置")

    let board = store(defaults(holdings: "600108"))
    try board.saveTracking(for: first, cost: "10", quantity: "100", upper: "", lower: "")
    board.receive([first.id: quote(first)], requested: [first], at: now)
    board.toggleIntraday(for: first)
    board.expandedSymbolID = first.id
    board.isAddingStock = true
    board.selectList(.indices)
    try check(board.visibleSymbols == DashboardIndex.symbols && board.listHeight == IndexDashboardView.height,
              "指数页固定展示目录并使用看板高度")
    try check(board.expandedChartSymbolID == nil && board.expandedSymbolID == nil && !board.isAddingStock,
              "切到指数页收起持仓编辑、分时图和添加输入")
    try check(board.totalPositionProfit == 200 && board.symbols == [first], "指数页不改变持仓总盈亏")
    try rejects({ try board.addSymbols("002580") }, "指数页不允许追加股票")
    try rejects({ try board.saveSymbols("") }, "指数页不允许清空固定目录")
    board.removeSymbol(index)
    try check(board.visibleSymbols == DashboardIndex.symbols && board.symbols == [first],
              "删除操作不能改动固定指数或持仓列表")
    try rejects({ try board.saveTracking(for: index, cost: "10", quantity: "100", upper: "13", lower: "") },
                "固定指数不能保存持仓或价格提醒")
    board.toggleIntraday(for: index)
    try check(board.expandedChartSymbolID == index.id && board.listHeight == IndexDashboardView.expandedHeight,
              "点击指数展开分时并增加看板视口高度")
    let otherIndex = DashboardIndex.symbols.first { $0 != index }!
    board.toggleIntraday(for: otherIndex)
    try check(board.expandedChartSymbolID == otherIndex.id && board.intradaySnapshot == nil,
              "切换指数只展开新图并清理前图")
    board.toggleIntraday(for: otherIndex)
    try check(board.expandedChartSymbolID == nil && board.listHeight == IndexDashboardView.height,
              "再次点击当前指数收起分时并恢复看板高度")
    board.receive([index.id: quote(index)], requested: DashboardIndex.symbols, at: now)
    try check(board.quotes[index.id]?.price == 12
              && board.unavailable == Set(indexIDs).subtracting([index.id]),
              "部分指数响应保留可用点位并标记其余缺失指数")
    board.selectList(.holdings)
    try check(board.visibleSymbols == [first] && board.allSymbols == [first]
              && board.totalPositionProfit == 200, "返回持仓页停止请求指数且保留持仓报价")

    let liveDefaults = defaults(holdings: "600108", watchlist: "002580")
    var oldAlert = try StockTracking.parse(cost: "10", quantity: "100", upper: "11", lower: "")
    oldAlert.armedAt = now.addingTimeInterval(-60)
    liveDefaults.set(try JSONEncoder().encode([second.id: oldAlert]), forKey: "stockTracking")
    let live = store(liveDefaults)
    try live.saveTracking(for: first, cost: "10", quantity: "100", upper: "11", lower: "",
                          now: now.addingTimeInterval(-60))
    var alerts: [String] = []
    live.onPriceAlert = { alerts.append($0.symbolID) }
    live.selectList(.indices)
    live.start()
    spin(until: { live.quotes.count == 9 && !live.isRefreshing })
    try check(live.quotes.count == 9 && live.errorMessage == nil
              && StockListProtocol.requests.last == live.allSymbols.map(\.id),
              "指数页批量刷新8个指数和隐藏持仓，沿用真实解析及隔离传输")
    try check(live.quotes[first.id]?.price == 12 && live.totalPositionProfit == 200,
              "查看指数时持仓行情和总盈亏继续更新")
    try check(alerts == [first.id] && live.quotes[second.id] == nil,
              "只触发持仓提醒，旧自选不请求也不提醒")
    live.evaluateAlerts([second.id: quote(second)], now: now)
    try check(alerts == [first.id] && live.tracking[second.id]?.upperTriggered == false,
              "即使收到旧自选报价也不消耗旧提醒状态")
    live.stop()

    let deduplicated = store(defaults(holdings: "sz980017,600108"))
    deduplicated.selectList(.indices)
    try check(deduplicated.allSymbols.count == 9
              && deduplicated.allSymbols.filter({ $0 == index }).count == 1,
              "历史持仓包含同一指数时批量请求去重")
    let empty = store(defaults())
    empty.selectList(.indices)
    empty.start()
    spin(until: { empty.quotes.count == 8 && !empty.isRefreshing })
    try check(empty.quotes.count == 8 && empty.totalPositionProfit == 0,
              "没有持仓也能独立加载指数看板")
    empty.stop()

    let auctionTime = ISO8601DateFormatter().date(from: "2026-10-26T09:20:00+08:00")!
    let auction = store(defaults(holdings: "600108"), at: auctionTime)
    auction.selectList(.indices)
    auction.receive([index.id: quote(index, at: auctionTime), first.id: quote(first, at: auctionTime)],
                    requested: auction.allSymbols, at: auctionTime)
    try check(auction.isAuction && auction.valuationPrice(for: index) == 12 && !auction.missingAuctionPrice,
              "集合竞价指数直接显示点位，不要求不存在的买卖盘口")
    auction.selectList(.holdings)
    try check(auction.valuationPrice(for: first) == nil && auction.missingAuctionPrice,
              "指数显示方式不改变个股竞价估值规则")
    return checks
}
