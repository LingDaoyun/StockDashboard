import Foundation

// Independent, deterministic transport: no production URLSession or preferences are used.
private final class MarketRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private let realStart = Date()
    private var offset: TimeInterval = 0
    init(_ start: Date) { self.start = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return start.addingTimeInterval(Date().timeIntervalSince(realStart) + offset)
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        offset += seconds
    }
}

private final class MarketRefreshFake: MarketOverviewFetching, @unchecked Sendable {
    struct Action {
        let delay: TimeInterval
        let snapshot: MarketOverviewSnapshot?
        init(_ snapshot: MarketOverviewSnapshot?, delay: TimeInterval = 0.01) {
            self.snapshot = snapshot; self.delay = delay
        }
    }
    private let lock = NSLock()
    private var actions: [Action] = []
    private var requests = 0
    private let fallback: () -> MarketOverviewSnapshot
    init(fallback: @escaping () -> MarketOverviewSnapshot) { self.fallback = fallback }
    func append(_ action: Action) {
        lock.lock(); defer { lock.unlock() }
        actions.append(action)
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    private func next() -> Action {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return actions.isEmpty ? Action(fallback()) : actions.removeFirst()
    }
    func fetch() async throws -> MarketOverviewSnapshot {
        let action = next()
        // Deliberately ignore cancellation so a late transport callback exercises Store guards.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + action.delay) {
                if let snapshot = action.snapshot { continuation.resume(returning: snapshot) }
                else { continuation.resume(throwing: URLError(.networkConnectionLost)) }
            }
        }
    }
}

private final class MarketRefreshStockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var clock: MarketRefreshClock?
    func use(_ clock: MarketRefreshClock) {
        lock.lock(); defer { lock.unlock() }
        self.clock = clock; requests = 0
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    func record() -> Date {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return clock!.now()
    }
}

private final class MarketRefreshStockProtocol: URLProtocol {
    static let probe = MarketRefreshStockProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let at = Self.probe.record()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let timestamp = formatter.string(from: at)
        let ids = request.url!.absoluteString.components(separatedBy: "q=").last!.components(separatedBy: ",")
        let text = ids.map { id -> String in
            var fields = Array(repeating: "", count: 58)
            fields[1] = "synthetic"; fields[2] = String(id.dropFirst(2))
            fields[3] = "12"; fields[4] = "10"; fields[30] = timestamp
            fields[31] = "2"; fields[32] = "20"; fields[36] = "100"; fields[37] = "1"
            return "v_\(id)=\"\(fields.joined(separator: "~"))\";"
        }.joined(separator: "\n")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                             httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func runMarketRefreshTests() throws -> Int {
    var domains: [String] = []
    var stores: [QuoteStore] = []
    defer {
        stores.forEach { $0.stop() }
        domains.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    }
    func date(_ time: String, day: String = "2026-10-20") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time)+08:00")!
    }
    func snapshot(at: Date, indexTime: Date? = nil, marketTime: Date? = nil,
                  breadthTime: Date? = nil, turnoverTime: Date? = nil,
                  price: Double = 4000, notice: String? = nil) -> MarketOverviewSnapshot {
        let index = Quote(symbol: StockSymbol(code: "000001", market: "sh"), name: "synthetic-index",
                          price: price, previousClose: 3900, change: price - 3900,
                          changePercent: (price / 3900 - 1) * 100, volumeLots: 100,
                          amountYuan: 1000, timestamp: indexTime ?? at,
                          turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
        let market = AllAMarketQuote(timestamp: marketTime ?? at, advancing: 3000, declining: 2000,
                                    total: 5500, turnoverYuan: 700_000_000_000,
                                    breadthTimestamp: breadthTime, turnoverTimestamp: turnoverTime)
        return MarketOverviewSnapshot(index: index, market: market, comparison: nil, comparisonNotice: notice)
    }
    func fixture(symbols: String = "", at: Date? = nil) -> (QuoteStore, MarketRefreshFake, MarketRefreshClock) {
        let domain = "cn.local.AShareDesktop.market-refresh-tests.\(UUID().uuidString)"
        domains.append(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(symbols, forKey: "symbols")
        let clock = MarketRefreshClock(at ?? date("10:00:00"))
        let fake = MarketRefreshFake { snapshot(at: clock.now()) }
        MarketRefreshStockProtocol.probe.use(clock)
        let client = QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [MarketRefreshStockProtocol.self]
            return URLSession(configuration: configuration)
        })
        let store = QuoteStore(defaults: defaults, preview: nil, client: client,
                               marketClient: fake, clock: { clock.now() })
        stores.append(store)
        return (store, fake, clock)
    }
    func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    let (empty, emptyClient, _) = fixture()
    empty.start()
    spin(0.4, until: { empty.marketOverview != nil })
    check(emptyClient.count == 1 && empty.marketOverview != nil, "无自选启动仍立即获取大盘")
    check(empty.symbols.isEmpty && empty.quotes.isEmpty && empty.tracking.isEmpty,
          "大盘不加入自选、股票缓存或持仓")
    check(empty.totalPositionProfit == 0 && MarketRefreshStockProtocol.probe.count == 0,
          "空持仓大盘不产生收益或股票网络请求")
    empty.refresh(); empty.refresh()
    spin(0.12)
    check(emptyClient.count == 1, "交易时连续刷新遵守三秒冷却")
    spin(3.4, until: { emptyClient.count >= 2 })
    check(emptyClient.count == 2, "空自选仍由实际定时器刷新大盘")
    empty.stop()

    let (recovery, recoveryClient, recoveryClock) = fixture()
    recovery.start()
    spin(0.3, until: { recovery.marketOverview != nil })
    let cachedTime = recovery.marketOverview!.market.timestamp
    recoveryClient.append(.init(nil))
    recoveryClock.advance(4)
    recovery.refresh()
    spin(0.3, until: { recovery.marketError != nil })
    check(recovery.marketError != nil && !recovery.isMarketRefreshing, "断线结束大盘在途状态并显示异常")
    check(recovery.marketOverview?.market.timestamp == cachedTime && recovery.errorMessage == nil,
          "大盘断线保留原快照且不污染股票错误")
    recoveryClock.advance(4)
    recovery.refresh()
    spin(0.3, until: { recovery.marketError == nil })
    check(recovery.marketError == nil && recovery.marketOverview!.market.timestamp > cachedTime,
          "冷却后下一轮大盘恢复并解除错误")
    recoveryClient.append(.init(snapshot(at: recoveryClock.now(), notice: "昨日同刻数据暂缺")))
    recovery.refresh(forceMarket: true)
    spin(0.3, until: { recovery.marketOverview?.comparisonNotice != nil })
    check(recovery.marketOverview?.comparisonNotice == "昨日同刻数据暂缺" && recovery.marketError == nil
          && recovery.errorMessage == nil, "仅同比缺失保留大盘与独立提示，不误报行情失败")
    recovery.stop()

    let (slow, slowClient, slowClock) = fixture(symbols: "600108,002580")
    slowClient.append(.init(snapshot(at: slowClock.now()), delay: 1.4))
    slow.start()
    spin(0.4, until: { slow.quotes.count == 2 })
    check(slow.isMarketRefreshing && slow.quotes.count == 2, "慢大盘不会阻塞自选股票刷新")
    slow.refresh(forceMarket: true); slow.refresh(forceMarket: true)
    spin(0.1)
    check(slowClient.count == 1, "即使强制刷新也不叠加在途大盘请求")
    slow.removeSymbol(slow.symbols.last!)
    spin(0.2, until: { slow.quotes.count == 1 && !slow.isRefreshing })
    check(slow.isMarketRefreshing && slowClient.count == 1, "改自选不取消或重启独立大盘请求")
    spin(1.5, until: { slow.marketOverview != nil })
    check(slow.marketOverview != nil && slow.quotes.keys.sorted() == ["sh600108"],
          "改自选后原在途大盘结果仍可接收且不回填已删除股票")
    try slow.saveSymbols("")
    check(slow.symbols.isEmpty && slow.quotes.isEmpty && slow.marketOverview != nil,
          "清空自选保留大盘快照")
    slowClock.advance(4)
    slow.refresh()
    spin(0.3, until: { slowClient.count == 2 && !slow.isMarketRefreshing })
    check(slowClient.count == 2 && slow.marketOverview != nil, "清空后大盘仍能继续请求")
    slow.stop()

    let twenty = (0..<20).map { String(format: "600%03d", $0) }.joined(separator: ",")
    let (capacity, _, _) = fixture(symbols: twenty)
    capacity.start()
    spin(0.5, until: { capacity.quotes.count == 20 && capacity.marketOverview != nil })
    check(capacity.symbols.count == 20 && capacity.quotes.count == 20 && capacity.marketOverview != nil,
          "二十只自选和大盘可同时存在，大盘不占股票名额")
    do { try capacity.addSymbols("002580"); preconditionFailure("第21只自选必须拒绝") }
    catch { checks += 1 }
    let held = capacity.symbols[0]
    try capacity.saveTracking(for: held, cost: "", quantity: "100", upper: "", lower: "", totalCost: "1000")
    check(capacity.totalPositionProfit == 200, "总盈亏仅计算已录入股票，大盘点数不参与")
    capacity.stop()

    let (late, lateClient, lateClock) = fixture()
    lateClient.append(.init(snapshot(at: lateClock.now(), price: 1111), delay: 0.8))
    late.start()
    spin(0.2, until: { lateClient.count == 1 })
    late.suspend()
    check(!late.isMarketRefreshing, "睡眠暂停立即结束大盘刷新状态")
    let pauseTime = late.marketNow
    spin(0.9)
    check(late.marketOverview == nil && late.marketError == nil && late.marketNow == pauseTime,
          "取消后晚到回包不能写快照、错误或时钟")
    late.resume()
    spin(0.3, until: { late.marketOverview != nil })
    check(lateClient.count == 2 && late.marketOverview?.index.price == 4000,
          "唤醒跳过旧冷却立即获取新大盘")
    lateClient.append(.init(snapshot(at: lateClock.now(), price: 2222), delay: 0.6))
    late.refresh(forceMarket: true)
    spin(0.2, until: { lateClient.count == 3 })
    late.suspend(); late.resume()
    spin(0.3, until: { lateClient.count == 4 && !late.isMarketRefreshing })
    check(late.marketOverview?.index.price == 4000, "唤醒的新请求可先于旧回包完成")
    spin(0.7)
    check(late.marketOverview?.index.price == 4000 && !late.isMarketRefreshing,
          "前一次被取消的晚到回包不覆盖新大盘或刷新状态")
    let beforeStop = lateClient.count
    late.stop()
    spin(0.2)
    late.resume()
    spin(0.2)
    check(lateClient.count == beforeStop && !late.isMarketRefreshing, "stop后resume不会擅自重启")

    let (ordering, orderClient, orderClock) = fixture()
    ordering.start()
    spin(0.3, until: { ordering.marketOverview != nil })
    let accepted = ordering.marketOverview!
    for bad in [snapshot(at: orderClock.now(), indexTime: accepted.index.timestamp.addingTimeInterval(-1), price: 3333),
                snapshot(at: orderClock.now(), marketTime: accepted.market.timestamp.addingTimeInterval(-1), price: 3333),
                snapshot(at: orderClock.now(), indexTime: orderClock.now().addingTimeInterval(30), price: 3333),
                snapshot(at: orderClock.now(), marketTime: orderClock.now().addingTimeInterval(30), price: 3333),
                snapshot(at: orderClock.now(), breadthTime: orderClock.now().addingTimeInterval(30), price: 3333),
                snapshot(at: orderClock.now(), turnoverTime: orderClock.now().addingTimeInterval(30), price: 3333)] {
        orderClient.append(.init(bad))
        ordering.refresh(forceMarket: true)
        spin(0.3, until: { !ordering.isMarketRefreshing })
        check(ordering.marketOverview?.index.price == accepted.index.price && ordering.marketError != nil,
              "拒绝逐源时间倒退或未来；未来源时间不能被另一正常源的min遮住")
    }
    ordering.refresh(forceMarket: true)
    spin(0.3, until: { !ordering.isMarketRefreshing })
    check(ordering.marketError == nil, "后续有效快照解除源时间异常")
    ordering.stop()

    for rollbackBreadth in [false, true] {
        let (crossed, crossedClient, crossedClock) = fixture()
        let at = crossedClock.now()
        let initialBreadth = at.addingTimeInterval(rollbackBreadth ? -2 : -4)
        let initialTurnover = at.addingTimeInterval(rollbackBreadth ? -4 : -2)
        crossedClient.append(.init(snapshot(at: at, marketTime: at.addingTimeInterval(-4),
                                            breadthTime: initialBreadth, turnoverTime: initialTurnover)))
        crossed.start()
        spin(0.3, until: { crossed.marketOverview != nil })
        check(crossed.marketOverview != nil && crossed.marketError == nil,
              "两源时间不同但有效时可建立大盘快照")
        let newerBreadth = at.addingTimeInterval(rollbackBreadth ? -3 : -1)
        let newerTurnover = at.addingTimeInterval(rollbackBreadth ? -1 : -3)
        crossedClient.append(.init(snapshot(at: at, marketTime: at.addingTimeInterval(-3),
                                            breadthTime: newerBreadth, turnoverTime: newerTurnover, price: 3333)))
        crossed.refresh(forceMarket: true)
        spin(0.3, until: { !crossed.isMarketRefreshing })
        check(crossed.marketOverview?.index.price == 4000 && crossed.marketError != nil,
              "聚合min已前进时仍拒绝任一单源倒退，另一源前进不能掩盖回退")
        crossed.stop()
    }

    for at in [date("11:40:00"), date("10:00:00", day: "2026-10-18")] {
        let (quiet, quietClient, quietClock) = fixture(at: at)
        quiet.start()
        spin(0.3, until: { quiet.marketOverview != nil })
        quietClock.advance(4)
        quiet.refresh()
        spin(0.1)
        check(quietClient.count == 1, "午休或休市大盘不会按交易三秒频率请求")
        quietClock.advance(quiet.marketSession.pollInterval)
        quiet.refresh()
        spin(0.3, until: { quietClient.count == 2 && !quiet.isMarketRefreshing })
        check(quietClient.count == 2, "午休或休市达到对应30/60秒间隔后重新获取大盘")
        quiet.stop()
    }
    return checks
}
