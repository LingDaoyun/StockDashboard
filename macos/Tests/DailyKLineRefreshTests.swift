import Foundation

private struct DailyRefreshFailure: Error { let message: String }

private final class DailyRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private func dailyRefreshSnapshot(_ symbol: StockSymbol, at: Date, close: Double = 11) -> DailyKLineSnapshot {
    DailyKLineSnapshot(symbol: symbol, candles: [
        DailyCandle(date: "2026-10-23", open: 10, close: close, high: max(12, close), low: 9, volumeLots: 100)
    ], adjustment: "前复权", timestamp: at)
}

private final class DailyRefreshFake: DailyKLineFetching, @unchecked Sendable {
    struct Action {
        let snapshot: DailyKLineSnapshot?
        let delay: TimeInterval
        init(_ snapshot: DailyKLineSnapshot?, delay: TimeInterval = 0.001) {
            self.snapshot = snapshot; self.delay = delay
        }
    }
    private let lock = NSLock()
    private let clock: DailyRefreshClock
    private var actions: [Action] = []
    private var requested: [StockSymbol] = []
    init(_ clock: DailyRefreshClock) { self.clock = clock }
    func append(_ action: Action) { lock.lock(); defer { lock.unlock() }; actions.append(action) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requested.count }
    private func next(_ symbol: StockSymbol) -> Action {
        lock.lock(); defer { lock.unlock() }; requested.append(symbol)
        return actions.isEmpty ? Action(dailyRefreshSnapshot(symbol, at: clock.now())) : actions.removeFirst()
    }
    func fetch(_ symbol: StockSymbol) async throws -> DailyKLineSnapshot {
        let action = next(symbol)
        // Ignore cancellation so late callbacks exercise Store ownership checks.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + action.delay) {
                if let snapshot = action.snapshot { continuation.resume(returning: snapshot) }
                else { continuation.resume(throwing: URLError(.networkConnectionLost)) }
            }
        }
    }
}

private struct DailyRefreshIntradayFake: IntradayFetching {
    let clock: DailyRefreshClock
    func fetch(_ symbol: StockSymbol) async throws -> IntradaySnapshot {
        IntradaySnapshot(symbol: symbol, date: "20261026", timestamp: clock.now(), previousClose: 10,
                         points: [IntradayPoint(minute: 600, price: 11, cumulativeVolumeLots: 100, volumeLots: 100)])
    }
}

private final class DailyRefreshQuoteProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clock: DailyRefreshClock?
    static func use(_ clock: DailyRefreshClock) { lock.lock(); defer { lock.unlock() }; Self.clock = clock }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let at = Self.clock!.now(); Self.lock.unlock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyyMMddHHmmss"
        let ids = request.url!.absoluteString.components(separatedBy: "q=").last!.split(separator: ",")
        let text = ids.map { id -> String in
            var fields = Array(repeating: "", count: 58)
            fields[1] = "offline-stock"; fields[2] = String(id.dropFirst(2))
            fields[3] = "12"; fields[4] = "10"; fields[30] = formatter.string(from: at)
            fields[31] = "2"; fields[32] = "20"; fields[36] = "100"; fields[37] = "1"
            return "v_\(id)=\"\(fields.joined(separator: "~"))\";"
        }.joined(separator: "\n")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func runDailyKLineRefreshTests() throws -> Int {
    var domains: [String] = [], stores: [QuoteStore] = [], checks = 0
    defer {
        stores.forEach { $0.stop() }
        domains.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
    }
    func date(_ day: String = "2026-10-26", time: String = "10:00:00") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time)+08:00")!
    }
    func fixture(at: Date? = nil) -> (QuoteStore, DailyRefreshFake, DailyRefreshClock) {
        let domain = "cn.local.AShareDesktop.daily-refresh-tests.\(UUID().uuidString)"
        domains.append(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set("600108,002580", forKey: "symbols")
        let clock = DailyRefreshClock(at ?? date()), fake = DailyRefreshFake(clock)
        DailyRefreshQuoteProtocol.use(clock)
        let client = QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [DailyRefreshQuoteProtocol.self]
            return URLSession(configuration: configuration)
        })
        let store = QuoteStore(defaults: defaults, preview: nil, client: client,
                               intradayClient: DailyRefreshIntradayFake(clock: clock), dailyKLineClient: fake,
                               clock: { clock.now() })
        stores.append(store); store.start()
        return (store, fake, clock)
    }
    func spin(_ seconds: TimeInterval = 0.35, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DailyRefreshFailure(message: message) }; checks += 1
    }

    let (normal, client, clock) = fixture()
    spin(until: { normal.quotes.count == 2 })
    normal.refresh(forceMarket: true); spin(0.02)
    try check(client.count == 0 && normal.expandedChartSymbolID == nil && normal.dailyKLineSnapshot == nil,
              "默认及强制刷新均不请求未展开的日K")
    let a = normal.symbols[0], b = normal.symbols[1]
    try normal.saveTracking(for: a, cost: "", quantity: "100", upper: "", lower: "", totalCost: "1000")
    let tracking = normal.tracking, savedTracking = normal.defaults.data(forKey: "stockTracking")
    let collapsedHeight = normal.listHeight
    normal.expandedSymbolID = a.id; normal.toggleIntraday(for: a)
    spin(until: { normal.intradaySnapshot != nil })
    let chartHeight = normal.listHeight
    normal.toggleDailyKLine(for: a)
    try check(normal.chartKind == .dailyKLine && normal.expandedChartSymbolID == a.id
              && normal.listHeight == chartHeight && chartHeight > collapsedHeight,
              "同股票分时切日K保留一个展开区和相同高度")
    spin(until: { normal.dailyKLineSnapshot != nil })
    normal.toggleIntraday(for: a)
    spin(until: { normal.intradaySnapshot != nil })
    try check(normal.chartKind == .intraday && normal.expandedChartSymbolID == a.id && normal.listHeight == chartHeight,
              "日K切回同股票分时不会收起区域")
    normal.toggleDailyKLine(for: a); spin(until: { normal.dailyKLineSnapshot != nil })
    let before = client.count
    clock.advance(29.9); normal.refresh(); spin(0.02)
    try check(client.count == before, "交易中日K三十秒内不重复请求")
    clock.advance(0.2); normal.refresh(); spin(until: { client.count == before + 1 && !normal.isDailyKLineRefreshing })
    try check(client.count == before + 1, "日K三十秒冷却后自动更新")
    normal.refresh(forceMarket: true); spin(until: { client.count == before + 2 && !normal.isDailyKLineRefreshing })
    try check(client.count == before + 2, "手动刷新绕过日K冷却")
    let acceptedTime = normal.dailyKLineSnapshot!.timestamp
    for action in [DailyRefreshFake.Action(nil), .init(dailyRefreshSnapshot(a, at: clock.now().addingTimeInterval(6), close: 88)),
                   .init(dailyRefreshSnapshot(a, at: acceptedTime.addingTimeInterval(-1), close: 88))] {
        client.append(action); normal.refresh(forceMarket: true); spin(until: { !normal.isDailyKLineRefreshing })
        try check(normal.dailyKLineSnapshot?.timestamp == acceptedTime && normal.dailyKLineSnapshot?.candles.last?.close == 11
                  && normal.dailyKLineError != nil, "断线、未来超过五秒和倒退源时间均保留日K缓存并报告错误")
    }
    normal.refresh(forceMarket: true); spin(until: { !normal.isDailyKLineRefreshing })
    try check(normal.dailyKLineError == nil && normal.errorMessage == nil && normal.tracking == tracking
              && normal.defaults.data(forKey: "stockTracking") == savedTracking && normal.totalPositionProfit == 200
              && normal.expandedSymbolID == nil, "恢复清除日K错误，所有图表操作不改变持仓存储和盈亏")
    normal.toggleDailyKLine(for: b)
    try check(normal.expandedChartSymbolID == b.id && normal.dailyKLineSnapshot == nil, "新股票立即替换唯一展开区")
    spin(until: { normal.dailyKLineSnapshot?.symbol == b })
    normal.toggleDailyKLine(for: b)
    try check(normal.expandedChartSymbolID == nil && normal.dailyKLineSnapshot == nil && normal.listHeight == collapsedHeight,
              "重复点击当前日K收起并恢复列表高度")
    normal.stop()

    let (slow, slowClient, slowClock) = fixture()
    let first = slow.symbols[0], second = slow.symbols[1]
    slowClient.append(.init(dailyRefreshSnapshot(first, at: slowClock.now(), close: 81), delay: 0.16))
    slow.toggleDailyKLine(for: first); spin(0.05, until: { slowClient.count == 1 })
    slow.refresh(forceMarket: true); slow.refresh(forceMarket: true); spin(0.02)
    try check(slowClient.count == 1 && slow.isDailyKLineRefreshing && slow.quotes.count == 2,
              "慢日K不叠加请求且不阻塞股票报价")
    slow.toggleDailyKLine(for: second); spin(0.2)
    try check(slow.dailyKLineSnapshot?.symbol == second && slow.dailyKLineSnapshot?.candles.last?.close == 11
              && !slow.isDailyKLineRefreshing, "换股后的旧慢包不能覆盖新日K或刷新状态")
    for target in ["分时", "关闭", "删除", "页签"] {
        slow.toggleDailyKLine(for: first); spin(until: { !slow.isDailyKLineRefreshing })
        let count = slowClient.count
        slowClient.append(.init(target == "关闭" ? nil : dailyRefreshSnapshot(first, at: slowClock.now(), close: 82), delay: 0.12))
        slow.refresh(forceMarket: true); spin(0.05, until: { slowClient.count == count + 1 })
        switch target {
        case "分时": slow.toggleIntraday(for: first)
        case "关闭": slow.closeIntraday()
        case "删除": slow.removeSymbol(first)
        default: slow.selectList(.indices)
        }
        spin(0.15)
        try check(slow.dailyKLineSnapshot == nil && slow.dailyKLineError == nil && !slow.isDailyKLineRefreshing,
                  "\(target)后忽略取消仍返回的日K成功或失败")
        if target == "分时" { try check(slow.intradaySnapshot?.symbol == first, "旧日K不干扰新分时") }
        if target == "删除" { try slow.addSymbols(first.id) }
    }
    slow.stop()

    let (sleeping, sleepClient, sleepClock) = fixture()
    let held = sleeping.symbols[0]
    sleepClient.append(.init(dailyRefreshSnapshot(held, at: sleepClock.now(), close: 83), delay: 0.16))
    sleeping.toggleDailyKLine(for: held); spin(0.05, until: { sleepClient.count == 1 })
    sleeping.suspend()
    try check(!sleeping.isDailyKLineRefreshing, "睡眠立即结束日K刷新状态")
    sleeping.resume(); spin(0.2)
    try check(sleepClient.count == 2 && sleeping.dailyKLineSnapshot?.candles.last?.close == 11
              && sleeping.expandedChartSymbolID == held.id && !sleeping.isDailyKLineRefreshing,
              "唤醒立即刷新保留的日K，并拒绝睡前慢包")
    sleeping.stop(); sleeping.resume(); spin(0.02)
    try check(sleepClient.count == 2, "stop后的resume不重启日K请求")

    for at in [date(time: "11:40:00"), date("2026-10-25")] {
        let (quiet, quietClient, quietClock) = fixture(at: at)
        quiet.selectList(.indices)
        let index = DashboardIndex.symbols[0]
        quiet.toggleDailyKLine(for: index); spin(until: { quiet.dailyKLineSnapshot != nil })
        try check(quiet.dailyKLineSnapshot?.symbol == index && quiet.chartKind == .dailyKLine,
                  "指数页复用日K请求和展开区")
        let cooldown = at == date("2026-10-25") ? 60.0 : 30.0
        quietClock.advance(cooldown - 0.1); quiet.refresh(); spin(0.02)
        try check(quietClient.count == 1, "午休三十秒或休市六十秒内不重复请求日K")
        quietClock.advance(0.2); quiet.refresh(); spin(until: { quietClient.count == 2 && !quiet.isDailyKLineRefreshing })
        try check(quietClient.count == 2, "午休或休市日K达到冷却时间可再次获取")
        quiet.selectList(.holdings)
        try check(quiet.expandedChartSymbolID == nil && quiet.dailyKLineSnapshot == nil, "切回持仓页关闭指数日K")
        quiet.stop()
    }
    return checks
}
