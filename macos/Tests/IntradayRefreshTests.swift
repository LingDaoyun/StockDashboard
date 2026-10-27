import Foundation

private struct IntradayRefreshFailure: Error { let message: String }

private final class IntradayRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds)
    }
}

private final class IntradayRefreshFake: IntradayFetching, @unchecked Sendable {
    struct Action {
        let snapshot: IntradaySnapshot?
        let delay: TimeInterval
        init(_ snapshot: IntradaySnapshot?, delay: TimeInterval = 0.01) {
            self.snapshot = snapshot; self.delay = delay
        }
    }
    private let lock = NSLock()
    private var actions: [Action] = []
    private var requested: [StockSymbol] = []
    private let fallback: (StockSymbol) -> IntradaySnapshot
    init(fallback: @escaping (StockSymbol) -> IntradaySnapshot) { self.fallback = fallback }
    func append(_ action: Action) { lock.lock(); defer { lock.unlock() }; actions.append(action) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requested.count }
    var symbols: [StockSymbol] { lock.lock(); defer { lock.unlock() }; return requested }
    private func next(_ symbol: StockSymbol) -> Action {
        lock.lock(); defer { lock.unlock() }
        requested.append(symbol)
        return actions.isEmpty ? Action(fallback(symbol)) : actions.removeFirst()
    }
    func fetch(_ symbol: StockSymbol) async throws -> IntradaySnapshot {
        let action = next(symbol)
        // Ignore cancellation deliberately: a late callback must be rejected by the Store.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + action.delay) {
                if let snapshot = action.snapshot { continuation.resume(returning: snapshot) }
                else { continuation.resume(throwing: URLError(.networkConnectionLost)) }
            }
        }
    }
}

private final class IntradayRefreshMarketFake: MarketOverviewFetching, @unchecked Sendable {
    let clock: IntradayRefreshClock
    init(_ clock: IntradayRefreshClock) { self.clock = clock }
    func fetch() async throws -> MarketOverviewSnapshot {
        let at = clock.now()
        let index = Quote(symbol: StockSymbol(code: "000001", market: "sh"), name: "offline-index",
                          price: 4000, previousClose: 3900, change: 100, changePercent: 2.56,
                          volumeLots: 100, amountYuan: 1000, timestamp: at,
                          turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
        let market = AllAMarketQuote(timestamp: at, advancing: 3000, declining: 2000,
                                    total: 5500, turnoverYuan: 700_000_000_000)
        return MarketOverviewSnapshot(index: index, market: market, comparison: nil, comparisonNotice: nil)
    }
}

private final class IntradayRefreshStockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clock: IntradayRefreshClock?
    static func use(_ clock: IntradayRefreshClock) { lock.lock(); defer { lock.unlock() }; Self.clock = clock }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let at = Self.clock!.now(); Self.lock.unlock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let ids = request.url!.absoluteString.components(separatedBy: "q=").last!
            .split(separator: ",").map(String.init)
        let text = ids.map { id -> String in
            var fields = Array(repeating: "", count: 58)
            fields[1] = "offline-stock"; fields[2] = String(id.dropFirst(2))
            fields[3] = "12"; fields[4] = "10"; fields[30] = formatter.string(from: at)
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
func runIntradayRefreshTests() throws -> Int {
    var domains: [String] = []
    var stores: [QuoteStore] = []
    defer {
        stores.forEach { $0.stop() }
        domains.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    }
    func date(_ time: String = "10:00:00", day: String = "2026-10-26") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time)+08:00")!
    }
    func snapshot(_ symbol: StockSymbol, at: Date, price: Double = 11,
                  minute: Int = 600) -> IntradaySnapshot {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        return IntradaySnapshot(symbol: symbol, date: formatter.string(from: at), timestamp: at,
                                previousClose: 10, points: [
                                    IntradayPoint(minute: 570, price: 10, cumulativeVolumeLots: 100, volumeLots: 100),
                                    IntradayPoint(minute: minute, price: price, cumulativeVolumeLots: 150, volumeLots: nil)
                                ])
    }
    func fixture(symbols: String = "600108,002580", at: Date? = nil)
        -> (QuoteStore, IntradayRefreshFake, IntradayRefreshClock) {
        let domain = "cn.local.AShareDesktop.intraday-refresh-tests.\(UUID().uuidString)"
        domains.append(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(symbols, forKey: "symbols")
        defaults.set(0.42, forKey: "backgroundTransparency")
        defaults.set(true, forKey: "pinned")
        defaults.set(false, forKey: "autoHideEnabled")
        defaults.set("1.2", forKey: "buyCommissionRate")
        let clock = IntradayRefreshClock(at ?? date())
        let fake = IntradayRefreshFake { snapshot($0, at: clock.now()) }
        IntradayRefreshStockProtocol.use(clock)
        let client = QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [IntradayRefreshStockProtocol.self]
            return URLSession(configuration: configuration)
        })
        let store = QuoteStore(defaults: defaults, preview: nil, client: client,
                               marketClient: IntradayRefreshMarketFake(clock), intradayClient: fake,
                               clock: { clock.now() })
        stores.append(store)
        store.start()
        return (store, fake, clock)
    }
    func spin(_ seconds: TimeInterval = 0.35, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw IntradayRefreshFailure(message: message) }
        checks += 1
    }

    let (auction, auctionClient, auctionClock) = fixture(at: date("09:20:00"))
    spin(until: { auction.quotes.count == 2 })
    let auctionSymbol = auction.symbols[0]
    func auctionQuote(at: Date, bid: Double? = 10.2, ask: Double? = 10.3, trade: Double = 10) -> Quote {
        Quote(symbol: auctionSymbol, name: "offline-auction", price: trade, previousClose: 10,
              change: 0, changePercent: 0, volumeLots: 0, amountYuan: 0, timestamp: at,
              turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil, bidPrice: bid, askPrice: ask)
    }
    auction.receive([auctionSymbol.id: auctionQuote(at: auctionClock.now())],
                    requested: [auctionSymbol], at: auctionClock.now())
    auction.toggleIntraday(for: auctionSymbol)
    spin(0.03)
    try check(auction.intradaySnapshot?.points.first?.price == 10.2
              && auction.intradaySnapshot?.points.first?.minute == 560 && auctionClient.count == 0,
              "09:20竞价图必须从实时报价显示买一参考价，不能依赖09:30才有的分钟接口")
    try check(auction.intradaySnapshot?.isOpeningAuction == true
              && auction.intradaySnapshot?.points.allSatisfy({ $0.volumeLots == nil }) == true,
              "竞价只显示参考价采样，不伪造分钟量")
    auctionClock.advance(1)
    auction.receive([auctionSymbol.id: auctionQuote(at: auctionClock.now(), bid: nil, ask: 10.4)],
                    requested: [auctionSymbol], at: auctionClock.now())
    try check(auction.intradaySnapshot?.points.map(\.price) == [10.2, 10.4],
              "竞价图随已有每秒报价追加，缺买一时使用卖一")
    auction.closeIntraday()
    auctionClock.advance(1)
    auction.receive([auctionSymbol.id: auctionQuote(at: auctionClock.now(), bid: 10.5)],
                    requested: [auctionSymbol], at: auctionClock.now())
    auction.toggleIntraday(for: auctionSymbol)
    try check(auction.intradaySnapshot?.points.count == 3 && auctionClient.count == 0,
              "关闭再展开保留程序期间的竞价采样，不请求分钟接口")
    auctionClock.advance(298)
    auction.receive([auctionSymbol.id: auctionQuote(at: auctionClock.now(), bid: 20, trade: 10.6)],
                    requested: [auctionSymbol], at: auctionClock.now())
    try check(auction.intradaySnapshot?.points.last?.price == 10.6
              && auction.intradaySnapshot?.points.last?.minute == 565,
              "09:25后开盘准备期显示竞价成交价，不能沿用盘口价")
    auctionClock.advance(300)
    auction.refresh()
    spin(until: { auction.intradaySnapshot?.isOpeningAuction == false && auctionClient.count == 1 })
    try check(auction.intradaySnapshot?.isOpeningAuction == false && auctionClient.count == 1,
              "09:30自动切换普通分钟曲线并立即拉取")
    auction.stop()

    let (boundary, boundaryClient, boundaryClock) = fixture(at: date("09:14:59"))
    let boundarySymbol = boundary.symbols[0]
    boundaryClient.append(.init(snapshot(boundarySymbol, at: boundaryClock.now(), price: 99), delay: 0.15))
    boundary.toggleIntraday(for: boundarySymbol)
    spin(0.03, until: { boundaryClient.count == 1 })
    boundaryClock.advance(1)
    boundary.receive([boundarySymbol.id: auctionQuote(at: boundaryClock.now())],
                     requested: [boundarySymbol], at: boundaryClock.now())
    spin(0.2)
    try check(boundary.intradaySnapshot?.isOpeningAuction == true
              && boundary.intradaySnapshot?.points.last?.price == 10.2 && boundary.intradayError == nil,
              "跨09:15边界晚到的普通分钟请求不能覆盖竞价采样")
    boundary.stop()

    for fails in [false, true] {
        let (waiting, waitingClient, waitingClock) = fixture(at: date("09:14:59"))
        let symbol = waiting.symbols[0]
        waitingClient.append(.init(fails ? nil : snapshot(symbol, at: waitingClock.now(), price: 99), delay: 0.15))
        waiting.toggleIntraday(for: symbol)
        spin(0.03, until: { waitingClient.count == 1 })
        waitingClock.advance(1)
        spin(0.2)
        try check(waiting.intradaySnapshot == nil && waiting.intradayError == nil,
                  "竞价开始尚无盘口样本时，旧分钟请求无论成功或失败均不得回填")
        waiting.stop()
    }

    let (noAuction, noAuctionClient, noAuctionClock) = fixture(at: date("09:20:00"))
    spin(until: { noAuction.quotes.count == 2 })
    noAuction.toggleIntraday(for: noAuction.symbols[0])
    try check(noAuction.intradaySnapshot == nil && noAuction.intradayError == nil && noAuctionClient.count == 0,
              "没有有效盘口价时等待当日竞价报价，不显示昨图或将成交价冒充参考价")
    noAuctionClock.advance(1)
    let noSymbol = noAuction.symbols[0]
    noAuction.receive([noSymbol.id: auctionQuote(at: noAuctionClock.now())], requested: [noSymbol], at: noAuctionClock.now())
    try check(noAuction.intradaySnapshot?.points.last?.price == 10.2,
              "盘口恢复后图自动出现")
    noAuction.removeSymbol(noSymbol)
    try check(noAuction.intradaySnapshot == nil && noAuction.expandedChartSymbolID == nil,
              "删除股票清理所选竞价图")
    noAuction.stop()

    let (normal, normalClient, normalClock) = fixture()
    spin(until: { normal.quotes.count == 2 && normal.marketOverview != nil })
    normal.refresh(forceMarket: true)
    spin(0.03)
    try check(normalClient.count == 0 && normal.expandedChartSymbolID == nil
              && normal.intradaySnapshot == nil, "默认不开图且强制刷新也不请求分时")
    let primary = normal.symbols[0]
    try normal.saveTracking(for: primary, cost: "", quantity: "100", upper: "", lower: "", totalCost: "1000")
    let tracking = normal.tracking
    normal.expandedSymbolID = primary.id
    normal.toggleIntraday(for: primary)
    spin(until: { normal.intradaySnapshot != nil })
    try check(normalClient.count == 1 && normal.intradaySnapshot?.symbol == primary
              && normal.expandedChartSymbolID == primary.id, "开图立即获取当前股票分时")
    try check(normal.expandedSymbolID == nil && normal.tracking == tracking
              && normal.totalPositionProfit == 200, "开图收起持仓编辑而不改持仓或股票盈亏")
    try check(normal.backgroundTransparency == 0.42 && normal.isPinned && !normal.autoHideEnabled
              && normal.buyCommissionRate == "1.2", "分时不改原透明度置顶吸附与佣金设置")
    normal.refresh(); normal.refresh()
    normalClock.advance(2.9); normal.refresh()
    spin(0.03)
    try check(normalClient.count == 1, "交易中不足三秒不重复请求分时")
    normalClock.advance(0.11); normal.refresh()
    spin(until: { normalClient.count == 2 && !normal.isIntradayRefreshing })
    try check(normalClient.count == 2, "推进固定时钟超过三秒后分时可再次刷新")
    normal.refresh(forceMarket: true)
    spin(until: { normalClient.count == 3 && !normal.isIntradayRefreshing })
    try check(normalClient.count == 3, "forceMarket强制刷新也立即更新当前图")

    let cachedTime = normal.intradaySnapshot!.timestamp
    normalClient.append(.init(nil))
    normalClock.advance(3.1); normal.refresh()
    spin(until: { normal.intradayError != nil })
    try check(normal.intradayError != nil && !normal.isIntradayRefreshing
              && normal.intradaySnapshot?.timestamp == cachedTime, "分时断线保留缓存并结束刷新状态")
    try check(normal.errorMessage == nil && normal.marketError == nil && normal.quotes.count == 2
              && normal.marketOverview != nil && normal.totalPositionProfit == 200,
              "分时错误不污染股票大盘或持仓盈亏")
    normalClock.advance(3.1); normal.refresh()
    spin(until: { normal.intradayError == nil && !normal.isIntradayRefreshing })
    try check(normal.intradayError == nil && normal.intradaySnapshot!.timestamp > cachedTime,
              "下次有效分时恢复并解除错误")
    normal.stop()

    let (slow, slowClient, slowClock) = fixture()
    let a = slow.symbols[0], b = slow.symbols[1]
    slowClient.append(.init(snapshot(a, at: slowClock.now(), price: 21), delay: 0.25))
    slow.toggleIntraday(for: a)
    spin(0.1, until: { slowClient.count == 1 && slow.quotes.count == 2 && slow.marketOverview != nil })
    try check(slow.isIntradayRefreshing && slow.quotes.count == 2 && slow.marketOverview != nil,
              "慢分时不会阻塞独立股票与大盘刷新")
    slow.refresh(forceMarket: true); slow.refresh(forceMarket: true)
    spin(0.02)
    try check(slowClient.count == 1, "强制刷新也不会叠加在途分时请求")
    slow.removeSymbol(b)
    try slow.addSymbols("002491")
    try check(slow.isIntradayRefreshing && slowClient.count == 1 && slow.expandedChartSymbolID == a.id,
              "增删其他股票不取消或重启在途图")
    spin(until: { !slow.isIntradayRefreshing })
    try check(slow.intradaySnapshot?.points.last?.price == 21,
              "其他股票变化后原在途分时仍可接收")
    slowClient.append(.init(snapshot(a, at: slowClock.now(), price: 22), delay: 0.2))
    slow.refresh(forceMarket: true)
    spin(0.05, until: { slowClient.count == 2 })
    slow.closeIntraday()
    try check(slow.expandedChartSymbolID == nil && slow.intradaySnapshot == nil
              && slow.intradayError == nil && !slow.isIntradayRefreshing, "关闭立即清理图和刷新状态")
    spin(0.25)
    slow.refresh(forceMarket: true)
    spin(0.02)
    try check(slowClient.count == 2 && slow.intradaySnapshot == nil && slow.intradayError == nil,
              "关闭后的晚到成功包不能复活图或触发后台分时请求")
    slow.toggleIntraday(for: a)
    spin(until: { slowClient.count == 3 && !slow.isIntradayRefreshing })
    slowClient.append(.init(snapshot(a, at: slowClock.now(), price: 23), delay: 0.15))
    slow.refresh(forceMarket: true)
    spin(0.05, until: { slowClient.count == 4 })
    slow.removeSymbol(a)
    try check(slow.expandedChartSymbolID == nil && slow.intradaySnapshot == nil && !slow.isIntradayRefreshing,
              "删除当前股票关闭其分时")
    spin(0.18)
    try check(slow.intradaySnapshot == nil && slow.intradayError == nil,
              "删除当前股票后晚到分时不能回填已删除图")
    slow.stop()

    let (switched, switchClient, switchClock) = fixture()
    let first = switched.symbols[0], second = switched.symbols[1]
    switchClient.append(.init(snapshot(first, at: switchClock.now(), price: 41), delay: 0.22))
    switchClient.append(.init(snapshot(second, at: switchClock.now(), price: 42)))
    switched.toggleIntraday(for: first)
    spin(0.05, until: { switchClient.count == 1 })
    switched.toggleIntraday(for: second)
    try check(switched.expandedChartSymbolID == second.id && switched.intradaySnapshot == nil,
              "快速换股立即清前图，仅保留一个展开ID")
    spin(until: { switched.intradaySnapshot?.symbol == second })
    try check(switchClient.symbols == [first, second] && switched.intradaySnapshot?.points.last?.price == 42,
              "换股不受前图冷却限制，新图独立获取")
    spin(0.25)
    try check(switched.intradaySnapshot?.symbol == second && switched.intradaySnapshot?.points.last?.price == 42
              && !switched.isIntradayRefreshing, "旧股晚到包不覆盖新图及新请求状态")
    switched.toggleIntraday(for: second)
    try check(switched.expandedChartSymbolID == nil && switched.intradaySnapshot == nil,
              "再次点击当前股票收起分时")
    switched.stop()

    let (sleeping, sleepClient, sleepClock) = fixture()
    let held = sleeping.symbols[0]
    sleepClient.append(.init(snapshot(held, at: sleepClock.now(), price: 51), delay: 0.18))
    sleeping.toggleIntraday(for: held)
    spin(0.05, until: { sleepClient.count == 1 })
    sleeping.suspend()
    try check(!sleeping.isIntradayRefreshing, "暂停取消分时并立即清刷新状态")
    spin(0.22)
    try check(sleeping.intradaySnapshot == nil && sleeping.intradayError == nil, "暂停后迟到包不能写入图或错误")
    sleeping.resume()
    spin(until: { sleepClient.count == 2 && sleeping.intradaySnapshot != nil })
    try check(sleepClient.count == 2 && sleeping.expandedChartSymbolID == held.id
              && sleeping.intradaySnapshot?.points.last?.price == 11, "恢复立即重试当前图并绕过旧冷却")
    sleepClient.append(.init(snapshot(held, at: sleepClock.now(), price: 52), delay: 0.18))
    sleeping.refresh(forceMarket: true)
    spin(0.05, until: { sleepClient.count == 3 })
    sleeping.suspend(); sleeping.resume()
    spin(until: { sleepClient.count == 4 && !sleeping.isIntradayRefreshing })
    spin(0.22)
    try check(sleepClient.count == 4 && sleeping.intradaySnapshot?.points.last?.price == 11
              && !sleeping.isIntradayRefreshing, "恢复的新图不被上次取消的慢包覆盖")
    sleeping.stop(); sleeping.resume()
    spin(0.02)
    try check(sleepClient.count == 4 && !sleeping.isIntradayRefreshing, "stop后resume不会重启分时")

    let (ordering, orderClient, orderClock) = fixture()
    let ordered = ordering.symbols[0]
    ordering.toggleIntraday(for: ordered)
    spin(until: { ordering.intradaySnapshot != nil })
    let acceptedTime = ordering.intradaySnapshot!.timestamp
    for invalidTime in [orderClock.now().addingTimeInterval(6), acceptedTime.addingTimeInterval(-1)] {
        orderClient.append(.init(snapshot(ordered, at: invalidTime, price: 88)))
        ordering.refresh(forceMarket: true)
        spin(until: { !ordering.isIntradayRefreshing })
        try check(ordering.intradaySnapshot?.timestamp == acceptedTime
                  && ordering.intradaySnapshot?.points.last?.price == 11 && ordering.intradayError != nil,
                  "拒绝未来超过五秒或倒退的真实源时间，保留旧图")
    }
    orderClient.append(.init(snapshot(ordered, at: orderClock.now(), price: 14, minute: 601)))
    ordering.refresh(forceMarket: true)
    spin(until: { !ordering.isIntradayRefreshing })
    try check(ordering.intradaySnapshot?.points.last?.minute == 601
              && ordering.intradaySnapshot?.points.last?.price == 14 && ordering.intradayError == nil,
              "下一分钟标签不作为未来源时间，正常数据解除错误")
    orderClient.append(.init(snapshot(ordered, at: orderClock.now().addingTimeInterval(5), price: 15)))
    ordering.refresh(forceMarket: true)
    spin(until: { !ordering.isIntradayRefreshing })
    try check(ordering.intradaySnapshot?.points.last?.price == 15 && ordering.intradayError == nil,
              "源时间允许五秒容差边界")
    orderClient.append(.init(nil, delay: 0.15))
    ordering.refresh(forceMarket: true)
    spin(0.05, until: { orderClient.count == 6 })
    ordering.closeIntraday()
    spin(0.18)
    try check(ordering.intradaySnapshot == nil && ordering.intradayError == nil && !ordering.isIntradayRefreshing,
              "关闭后的晚到失败不能写入错误")
    ordering.stop()

    for (at, cooldown) in [(date("11:40:00"), 30.0), (date(day: "2026-10-25"), 60.0)] {
        let (quiet, quietClient, quietClock) = fixture(at: at)
        quiet.toggleIntraday(for: quiet.symbols[0])
        spin(until: { quiet.intradaySnapshot != nil })
        quietClock.advance(cooldown - 0.1); quiet.refresh()
        spin(0.02)
        try check(quietClient.count == 1, "午休三十秒或休市六十秒内不按交易频率重复请求")
        quietClock.advance(0.2); quiet.refresh()
        spin(until: { quietClient.count == 2 && !quiet.isIntradayRefreshing })
        try check(quietClient.count == 2, "午休或休市达到对应冷却后恢复分时请求")
        quiet.stop()
    }

    let twenty = (0..<20).map { String(format: "600%03d", $0) }.joined(separator: ",")
    let (capacity, capacityClient, _) = fixture(symbols: twenty)
    capacity.toggleIntraday(for: capacity.symbols[0])
    spin(until: { capacity.intradaySnapshot != nil && capacity.quotes.count == 20 })
    try check(capacity.symbols.count == 20 && capacity.quotes.count == 20 && capacityClient.count == 1,
              "完整二十只自选仍可开图，分时不占股票名额")
    do {
        try capacity.addSymbols("002580")
        throw IntradayRefreshFailure(message: "第21只股票被错误接纳")
    } catch is IntradayRefreshFailure { throw IntradayRefreshFailure(message: "第21只股票被错误接纳") }
      catch { checks += 1 }
    try check(capacity.symbols.count == 20 && capacity.expandedChartSymbolID == capacity.symbols[0].id,
              "超上限添加失败不改变自选或当前图")
    capacity.stop()
    return checks
}
