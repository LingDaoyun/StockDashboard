import Foundation

private final class RefreshProbe {
    let lock = NSLock()
    var requests: [(Date, String)] = []
    var active = 0
    var maximumActive = 0
    var delay: TimeInterval = 0.02
    var failures: [URLError.Code] = []
    var clock: () -> Date = Date.init

    func reset(delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        precondition(active == 0)
        requests = []; maximumActive = 0; self.delay = delay; failures = []
    }

    func failNext(_ error: URLError.Code) {
        lock.lock(); defer { lock.unlock() }
        failures.append(error)
    }

    func useClock(_ clock: @escaping () -> Date) {
        lock.lock(); defer { lock.unlock() }
        self.clock = clock
    }

    var quoteTime: Date {
        lock.lock()
        let currentClock = clock
        lock.unlock()
        return currentClock()
    }

    var snapshot: (requests: [(Date, String)], active: Int, maximumActive: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, active, maximumActive)
    }
}

private final class RefreshProtocol: URLProtocol {
    static let probe = RefreshProbe()
    private let lock = NSLock()
    private var finished = false
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.probe.lock.lock()
        Self.probe.requests.append((Date(), request.url!.absoluteString))
        let requestNumber = Self.probe.requests.count
        Self.probe.active += 1
        Self.probe.maximumActive = max(Self.probe.maximumActive, Self.probe.active)
        let delay = Self.probe.delay
        let failure = Self.probe.failures.isEmpty ? nil : Self.probe.failures.removeFirst()
        Self.probe.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.finished else { self.lock.unlock(); return }
            self.finished = true
            self.lock.unlock()
            Self.probe.lock.lock(); Self.probe.active -= 1; Self.probe.lock.unlock()
            if let failure {
                self.client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyyMMddHHmmss"
            let timestamp = formatter.string(from: Self.probe.quoteTime)
            let data = ["sh600108", "sz002580"].map { id -> String in
                var fields = Array(repeating: "", count: 58)
                fields[1] = "synthetic"; fields[2] = String(id.dropFirst(2))
                fields[3] = "10"; fields[4] = "10"; fields[30] = timestamp
                fields[31] = "0"; fields[32] = "0"; fields[36] = "100"; fields[37] = "1"
                fields[33] = String(10 + Double(requestNumber) / 10)
                fields[34] = String(10 - Double(requestNumber) / 10)
                return "v_\(id)=\"\(fields.joined(separator: "~"))\";"
            }.joined(separator: "\n").data(using: .utf8)!
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200,
                                                                      httpVersion: "HTTP/1.1", headerFields: nil)!,
                                     cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        lock.lock(); pending = work; let stopped = finished; lock.unlock()
        if stopped { work.cancel() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) }
    }

    override func stopLoading() {
        lock.lock()
        let wasFinished = finished
        finished = true
        pending?.cancel()
        lock.unlock()
        if !wasFinished {
            Self.probe.lock.lock(); Self.probe.active -= 1; Self.probe.lock.unlock()
        }
    }
}

@MainActor
func runRefreshTests() throws -> Int {
    let domain = "cn.local.AShareDesktop.refresh-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defaults.set("600108,002580", forKey: "symbols")
    defer { defaults.removePersistentDomain(forName: domain) }
    func marketDate(_ time: String, day: String = "2026-10-12") -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(time)+08:00")!
    }
    func makeStore(at start: Date? = nil) -> QuoteStore {
        let start = start ?? marketDate("10:00:00")
        let realStart = Date()
        let clock: () -> Date = { start.addingTimeInterval(Date().timeIntervalSince(realStart)) }
        RefreshProtocol.probe.useClock(clock)
        return QuoteStore(defaults: defaults, preview: nil, client: QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [RefreshProtocol.self]
            return URLSession(configuration: configuration)
        }), clock: clock)
    }
    func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    RefreshProtocol.probe.reset(delay: 0.02)
    let normal = makeStore()
    defer { normal.stop() }
    normal.start()
    spin(0.5, until: { normal.quotes.count == 2 })
    let firstHigh = normal.quotes[normal.symbols[0].id]?.dayHigh
    let firstLow = normal.quotes[normal.symbols[0].id]?.dayLow
    check(firstHigh != nil && firstLow != nil, "首次报价读取当日高低价，无需打开分时图")
    spin(2.8, until: { RefreshProtocol.probe.snapshot.requests.count >= 3 })
    let regular = RefreshProtocol.probe.snapshot
    check(regular.requests.count >= 3, "启动立即请求并在两秒左右完成三次批量请求")
    let intervals = zip(regular.requests.dropFirst(), regular.requests).map { $0.0.timeIntervalSince($1.0) }
    check(intervals.allSatisfy { $0 >= 0.8 && $0 < 1.6 }, "实际定时器每秒触发，不是仅修改显示文字")
    check(regular.requests.allSatisfy { $0.1 == "https://qt.gtimg.cn/q=sh600108,sz002580" }, "每秒仍为所有股票一次批量请求")
    spin(0.2, until: { normal.quotes.count == 2 })
    check(normal.quotes.count == 2 && normal.errorMessage == nil, "每秒刷新正常更新行情缓存")
    check(normal.quotes.values.allSatisfy { ($0.dayHigh ?? 0) > (firstHigh ?? 0) },
          "后续自动行情请求更新每只股票的当日最高价")
    check(normal.quotes.values.allSatisfy { ($0.dayLow ?? .infinity) < (firstLow ?? 0) },
          "后续自动行情请求更新每只股票的当日最低价")
    check(normal.lastReceipt.map { $0 >= marketDate("10:00:00") && $0 < marketDate("10:00:04") } == true,
          "接收时间来自随真实耗时前进的模拟交易时钟")
    check(normal.quotes.values.allSatisfy { $0.timestamp >= marketDate("10:00:00") && $0.timestamp <= normal.marketNow },
          "源报价和接收端共用模拟时钟，不受真实日期及当前是否超过10点影响")
    spin(0.3, until: { !normal.isRefreshing })
    let beforeRepeatedStart = RefreshProtocol.probe.snapshot.requests.count
    normal.start()
    spin(0.2)
    check(RefreshProtocol.probe.snapshot.requests.count == beforeRepeatedStart, "重复start不立即请求或重复启动定时器")
    normal.stop()
    spin(0.1, until: { RefreshProtocol.probe.snapshot.active == 0 })

    RefreshProtocol.probe.reset(delay: 2.3)
    let slow = makeStore()
    defer { slow.stop() }
    let slowStart = slow.marketNow
    let sourceTime = slowStart.addingTimeInterval(-14.5)
    let symbol = slow.symbols[0]
    let cachedQuote = Quote(symbol: symbol, name: "synthetic", price: 10, previousClose: 10,
                            change: 0, changePercent: 0, volumeLots: 100, amountYuan: 10_000,
                            timestamp: sourceTime, turnoverPercent: nil, volumeRatio: nil, amplitudePercent: nil)
    slow.receive([symbol.id: cachedQuote], requested: slow.symbols, at: slowStart)
    check(slow.oldestQuoteTime == sourceTime && !slow.hasStaleQuotes, "模拟缓存刚建立时源报价尚未超过15秒")
    slow.start()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.requests.count == 1 })
    slow.refresh(); slow.refresh()
    spin(2.05)
    check(RefreshProtocol.probe.snapshot.requests.count == 1, "慢请求期间每秒触发与手动刷新均不叠加请求")
    check(RefreshProtocol.probe.snapshot.maximumActive == 1, "慢网络最多只有一笔在途请求")
    check(slow.marketNow.timeIntervalSince(slowStart) >= 1.5 && slow.hasStaleQuotes
          && slow.oldestQuoteTime == sourceTime,
          "请求未完成时每秒仍更新界面时间，缓存跨过15秒后显示过旧且源时间不变")
    spin(1.5, until: { RefreshProtocol.probe.snapshot.requests.count == 2 })
    check(RefreshProtocol.probe.snapshot.requests.count == 2, "慢请求结束后自动恢复下一次轮询")
    slow.suspend()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    check(!slow.isRefreshing && RefreshProtocol.probe.snapshot.active == 0, "睡眠暂停取消在途请求")
    let beforePause = RefreshProtocol.probe.snapshot.requests.count
    let pausedTime = slow.marketNow
    spin(1.15)
    check(RefreshProtocol.probe.snapshot.requests.count == beforePause, "暂停期间定时器不会请求")
    check(slow.marketNow == pausedTime, "暂停真正取消定时器，界面时钟也不继续跳动")
    slow.resume()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.requests.count > beforePause })
    check(RefreshProtocol.probe.snapshot.requests.count == beforePause + 1, "唤醒立即请求，不等待下一秒")
    check(slow.marketNow > pausedTime, "唤醒立即恢复当前时钟")
    slow.stop()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    check(RefreshProtocol.probe.snapshot.maximumActive == 1, "取消和唤醒后仍不重叠")

    RefreshProtocol.probe.reset(delay: 0.02)
    let recovery = makeStore()
    defer { recovery.stop() }
    recovery.start()
    spin(0.5, until: { recovery.quotes.count == 2 })
    check(recovery.quotes.count == 2, "断线测试先建立可用行情")
    for error in [URLError.Code.networkConnectionLost, .notConnectedToInternet, .timedOut] {
        let receipt = recovery.lastReceipt
        let cached = recovery.quotes.mapValues(\.timestamp)
        RefreshProtocol.probe.failNext(error)
        spin(1.8, until: { recovery.errorMessage != nil })
        check(recovery.errorMessage != nil && !recovery.isRefreshing, "断开或超时会结束在途状态并提示异常：\(error)")
        check(recovery.quotes.mapValues(\.timestamp) == cached && recovery.lastReceipt == receipt,
              "失败保留原行情，不用当前请求时间冒充报价时间：\(error)")
        spin(1.8, until: { recovery.errorMessage == nil && recovery.lastReceipt != receipt })
        check(recovery.errorMessage == nil && recovery.lastReceipt != receipt && recovery.quotes.count == 2,
              "网络恢复后下一轮自动重新连接并刷新，无需手动操作：\(error)")
    }
    recovery.stop()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    check(RefreshProtocol.probe.snapshot.maximumActive == 1, "断线恢复始终不并发或积压请求")

    RefreshProtocol.probe.reset(delay: 0.5)
    let changing = makeStore()
    defer { changing.stop() }
    changing.start()
    spin(0.3, until: { RefreshProtocol.probe.snapshot.requests.count == 1 })
    changing.removeSymbol(changing.symbols.last!)
    spin(0.3, until: { RefreshProtocol.probe.snapshot.requests.count == 2 })
    check(RefreshProtocol.probe.snapshot.requests.last?.1 == "https://qt.gtimg.cn/q=sh600108" && changing.isRefreshing,
          "在途删除股票会取消旧请求并立即请求新列表")
    spin(0.1)
    check(changing.isRefreshing && changing.errorMessage == nil && changing.quotes.isEmpty,
          "已取消旧Task不能清理新请求状态或写入旧行情")
    try changing.saveSymbols("")
    spin(0.3, until: { RefreshProtocol.probe.snapshot.active == 0 })
    check(!changing.isRefreshing && changing.symbols.isEmpty && changing.quotes.isEmpty && changing.errorMessage == nil,
          "在途清空列表后停止网络并清缓存，取消不显示故障")
    let emptyTime = changing.marketNow
    let beforeEmptyWait = RefreshProtocol.probe.snapshot.requests.count
    spin(1.15)
    check(changing.marketNow == emptyTime && RefreshProtocol.probe.snapshot.requests.count == beforeEmptyWait
          && changing.oldestQuoteTime == nil && !changing.hasStaleQuotes,
          "空列表停止定时器，时钟不跳动且没有过旧报价")
    try changing.addSymbols("002580")
    spin(0.3, until: { RefreshProtocol.probe.snapshot.requests.count == 3 })
    check(RefreshProtocol.probe.snapshot.requests.last?.1 == "https://qt.gtimg.cn/q=sz002580" && changing.isRefreshing,
          "清空后立即添加可正常重新请求")
    spin(0.8, until: { changing.quotes.count == 1 })
    check(changing.quotes.keys.sorted() == ["sz002580"] && !changing.isRefreshing && changing.errorMessage == nil,
          "恢复的缓存仅包含最新自选列表，旧请求不覆盖")
    spin(1.3, until: { RefreshProtocol.probe.snapshot.requests.count >= 4 })
    check(RefreshProtocol.probe.snapshot.requests.count >= 4, "清空后重新添加恢复每秒轮询")
    changing.stop()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })

    defaults.set("600108,002580", forKey: "symbols")
    for (at, phase, interval) in [(marketDate("10:00:00", day: "2026-10-11"), MarketPhase.closed, 60.0),
                                  (marketDate("11:32:00"), MarketPhase.lunch, 30.0)] {
        RefreshProtocol.probe.reset(delay: 0.02)
        let quiet = makeStore(at: at)
        quiet.start()
        spin(0.3, until: { RefreshProtocol.probe.snapshot.requests.count == 1 })
        check(RefreshProtocol.probe.snapshot.requests.count == 1 && quiet.marketSession.phase == phase
              && quiet.marketSession.pollInterval == interval, "休市或午休启动仍立即请求一次快照")
        spin(1.15)
        check(RefreshProtocol.probe.snapshot.requests.count == 1 && quiet.quotes.count == 2 && !quiet.hasStaleQuotes,
              "休市或午休降频，超过一秒不再密集请求也不报陈旧警告")
        quiet.stop()
        spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    }

    for boundary in [marketDate("09:14:00"), marketDate("12:59:00")] {
        RefreshProtocol.probe.reset(delay: 0.02)
        let opening = makeStore(at: boundary.addingTimeInterval(-0.3))
        opening.start()
        spin(1.9, until: { RefreshProtocol.probe.snapshot.requests.count >= 3 })
        let requests = RefreshProtocol.probe.snapshot.requests
        check(requests.count >= 3 && opening.marketSession.phase == .preOpen
              && opening.marketSession.pollInterval == 1,
              "开盘准备边界到达后立即恢复每秒请求，不等原30或60秒间隔")
        let gaps = zip(requests.dropFirst(), requests).map { $0.0.timeIntervalSince($1.0) }
        check(gaps.count >= 2 && gaps[0] >= 0.15 && gaps[0] < 0.8 && gaps[1] >= 0.8 && gaps[1] < 1.6,
              "下一次定时器先准确落在0.3秒后的开盘准备边界，再按一秒继续")
        opening.stop()
        spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    }

    RefreshProtocol.probe.reset(delay: 0.02)
    let closing = makeStore(at: marketDate("15:31:00").addingTimeInterval(-0.3))
    closing.start()
    spin(0.8, until: { closing.marketSession.phase == .closed && RefreshProtocol.probe.snapshot.requests.count >= 2 })
    check(closing.marketSession.phase == .closed && closing.marketSession.pollInterval == 60
          && RefreshProtocol.probe.snapshot.requests.count == 2, "盘后结束边界请求一次后切换到60秒休市轮询")
    let afterClose = RefreshProtocol.probe.snapshot.requests.count
    spin(1.15)
    check(RefreshProtocol.probe.snapshot.requests.count == afterClose, "进入休市后停止一秒密集请求")
    closing.stop()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    return checks
}
