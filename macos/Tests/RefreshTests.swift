import Foundation

private final class RefreshProbe {
    let lock = NSLock()
    var requests: [(Date, String)] = []
    var active = 0
    var maximumActive = 0
    var delay: TimeInterval = 0.02
    var failures: [URLError.Code] = []

    func reset(delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        precondition(active == 0)
        requests = []; maximumActive = 0; self.delay = delay; failures = []
    }

    func failNext(_ error: URLError.Code) {
        lock.lock(); defer { lock.unlock() }
        failures.append(error)
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
            let timestamp = formatter.string(from: Date())
            let data = ["sh600108", "sz002580"].map { id -> String in
                var fields = Array(repeating: "", count: 58)
                fields[1] = "synthetic"; fields[2] = String(id.dropFirst(2))
                fields[3] = "10"; fields[4] = "10"; fields[30] = timestamp
                fields[31] = "0"; fields[32] = "0"; fields[36] = "100"; fields[37] = "1"
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
    func makeStore() -> QuoteStore {
        QuoteStore(defaults: defaults, preview: nil, client: QuoteClient(makeSession: { configuration in
            configuration.protocolClasses = [RefreshProtocol.self]
            return URLSession(configuration: configuration)
        }))
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
    spin(2.8, until: { RefreshProtocol.probe.snapshot.requests.count >= 3 })
    let regular = RefreshProtocol.probe.snapshot
    check(regular.requests.count >= 3, "启动立即请求并在两秒左右完成三次批量请求")
    let intervals = zip(regular.requests.dropFirst(), regular.requests).map { $0.0.timeIntervalSince($1.0) }
    check(intervals.allSatisfy { $0 >= 0.8 && $0 < 1.6 }, "实际定时器每秒触发，不是仅修改显示文字")
    check(regular.requests.allSatisfy { $0.1 == "https://qt.gtimg.cn/q=sh600108,sz002580" }, "每秒仍为所有股票一次批量请求")
    spin(0.2, until: { normal.quotes.count == 2 })
    check(normal.quotes.count == 2 && normal.errorMessage == nil, "每秒刷新正常更新行情缓存")
    normal.stop()
    spin(0.1, until: { RefreshProtocol.probe.snapshot.active == 0 })

    RefreshProtocol.probe.reset(delay: 2.3)
    let slow = makeStore()
    defer { slow.stop() }
    slow.start()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.requests.count == 1 })
    slow.refresh(); slow.refresh()
    spin(2.05)
    check(RefreshProtocol.probe.snapshot.requests.count == 1, "慢请求期间每秒触发与手动刷新均不叠加请求")
    check(RefreshProtocol.probe.snapshot.maximumActive == 1, "慢网络最多只有一笔在途请求")
    spin(1.5, until: { RefreshProtocol.probe.snapshot.requests.count == 2 })
    check(RefreshProtocol.probe.snapshot.requests.count == 2, "慢请求结束后自动恢复下一次轮询")
    slow.suspend()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.active == 0 })
    check(!slow.isRefreshing && RefreshProtocol.probe.snapshot.active == 0, "睡眠暂停取消在途请求")
    let beforePause = RefreshProtocol.probe.snapshot.requests.count
    spin(1.15)
    check(RefreshProtocol.probe.snapshot.requests.count == beforePause, "暂停期间定时器不会请求")
    slow.resume()
    spin(0.4, until: { RefreshProtocol.probe.snapshot.requests.count > beforePause })
    check(RefreshProtocol.probe.snapshot.requests.count == beforePause + 1, "唤醒立即请求，不等待下一秒")
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
    try changing.addSymbols("002580")
    spin(0.3, until: { RefreshProtocol.probe.snapshot.requests.count == 3 })
    check(RefreshProtocol.probe.snapshot.requests.last?.1 == "https://qt.gtimg.cn/q=sz002580" && changing.isRefreshing,
          "清空后立即添加可正常重新请求")
    spin(0.8, until: { changing.quotes.count == 1 })
    check(changing.quotes.keys.sorted() == ["sz002580"] && !changing.isRefreshing && changing.errorMessage == nil,
          "恢复的缓存仅包含最新自选列表，旧请求不覆盖")
    return checks
}
