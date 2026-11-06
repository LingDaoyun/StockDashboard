import Foundation

private struct DailyKLineTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class DailyKLineTransport: @unchecked Sendable {
    enum Result: Sendable { case response(Int, Data), failure(URLError.Code), pending }
    private let lock = NSLock()
    private var result: Result = .pending
    private var requests: [URLRequest] = []
    private var stops = 0
    func set(_ value: Result) { lock.lock(); defer { lock.unlock() }; result = value }
    func begin(_ request: URLRequest) -> Result {
        lock.lock(); defer { lock.unlock() }; requests.append(request); return result
    }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var snapshot: (requests: [URLRequest], stops: Int) {
        lock.lock(); defer { lock.unlock() }; return (requests, stops)
    }
}

private final class DailyKLineTestProtocol: URLProtocol, @unchecked Sendable {
    static let transport = DailyKLineTransport()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.transport.begin(request) {
        case .response(let status, let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending: break
        }
    }
    override func stopLoading() { Self.transport.stop() }
}

@main
@MainActor
enum DailyKLineTests {
    static var checks = 0
    static let symbol = StockSymbol(code: "600108", market: "sh")
    static let rows = [
        ["2026-11-04", "3.17", "3.21", "3.24", "3.15", "751678.000"],
        ["2026-11-05", "3.18", "3.27", "3.29", "3.17", "995591"]
    ]
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw DailyKLineTestFailure(description: message) }
        checks += 1
    }
    static func rejected(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch let failure as DailyKLineTestFailure { throw failure }
        catch {
            try expect(error is LocalizedError && !error.localizedDescription.isEmpty, message)
            return
        }
        throw DailyKLineTestFailure(description: message)
    }
    static func fixture(rows: [[Any]] = rows, key: String = "qfqday", id: String = "sh600108",
                        time: String = "20261105161451", code: Int = 0,
                        qtCode: String? = nil, extra: [String: Any] = [:]) -> Data {
        var qt = Array(repeating: "", count: 38)
        qt[2] = qtCode ?? String(id.dropFirst(2)); qt[30] = time
        var payload = extra
        payload[key] = rows
        payload["qt"] = [id: qt, "market": ["status": true], "unrelated": NSNull()] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: ["code": code, "data": [id: payload]])
    }
    static func parserTests() throws {
        let value = try DailyKLineParser.parse(fixture(), symbol: symbol)
        try expect(value.symbol == symbol && value.adjustment == "前复权", "股票前复权来自实际qfqday字段")
        try expect(value.candles.count == 2 && value.candles[0].id == "2026-11-04", "保留实际交易日")
        let latest = value.candles[1]
        try expect(latest.open == 3.18 && latest.close == 3.27 && latest.high == 3.29
                   && latest.low == 3.17 && latest.volumeLots == 995591, "按开收高低量解析而非OHLC常见顺序")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        try expect(formatter.string(from: value.timestamp) == "20261105161451", "保留行情源真实时间")
        let index = StockSymbol(code: "980017", market: "sz")
        let single = try DailyKLineParser.parse(fixture(rows: [rows[1]], key: "day", id: index.id), symbol: index)
        try expect(single.candles.count == 1 && single.adjustment == "不复权", "允许指数源仅提供真实单条日K")
        let beijing = StockSymbol(code: "920002", market: "bj")
        let north = try DailyKLineParser.parse(fixture(rows: [rows[1]], key: "day", id: beijing.id), symbol: beijing)
        try expect(north.candles.count == 1 && north.adjustment == "不复权", "北交所普通日线按实际复权字段标注")
        let preferred = try DailyKLineParser.parse(fixture(extra: ["day": [rows[0]]]), symbol: symbol)
        try expect(preferred.candles.count == 2 && preferred.adjustment == "前复权", "存在前复权字段时采用前复权")
        let dividend: [Any] = ["2026-09-24", "11.350", "11.300", "11.470", "11.290", "1043819.000",
                               ["nd": "2026", "fh_sh": "2.49", "djr": "2026-09-23", "cqr": "2026-09-24", "FHcontent": "10派2.49元"]]
        let dividendValue = try DailyKLineParser.parse(fixture(rows: [dividend]), symbol: symbol)
        try expect(dividendValue.candles[0].close == 11.3 && dividendValue.candles[0].volumeLots == 1043819,
                   "前六列为日K，除权日第七列附加对象不妨碍解析")
        let suspended = try DailyKLineParser.parse(fixture(rows: [rows[0]]), symbol: symbol)
        try expect(suspended.candles.last?.date == "2026-11-04", "停牌或数据源未更新时允许最近交易日早于报价日")
        var flat = rows[0]; flat[1] = "3.2"; flat[2] = "3.2"; flat[3] = "3.2"; flat[4] = "3.2"; flat[5] = "0"
        try expect(try DailyKLineParser.parse(fixture(rows: [flat]), symbol: symbol).candles[0].volumeLots == 0,
                   "平价且零成交量K线有效")

        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: "2026-08-01")!
        let history = (0..<61).map { offset -> [String] in
            var row = rows[0]
            row[0] = formatter.string(from: start.addingTimeInterval(Double(offset) * 86400))
            return row
        }
        let bounded = try DailyKLineParser.parse(fixture(rows: history), symbol: symbol)
        try expect(bounded.candles.count == 60 && bounded.candles.first?.date == history[1][0]
                   && bounded.candles.last?.date == history.last?[0], "源返回61根时只保留最近60个实际记录")
        for bad in ["", "NaN", "inf", "-inf", "bad", "0", "-1"] {
            for column in 1...4 {
                var row = rows[0]; row[column] = bad
                try rejected("拒绝无效价格列\(column)：\(bad)") {
                    _ = try DailyKLineParser.parse(fixture(rows: [row]), symbol: symbol)
                }
            }
        }
        for bad in ["", "NaN", "inf", "-1", "bad"] {
            var row = rows[0]; row[5] = bad
            try rejected("拒绝无效成交量：\(bad)") { _ = try DailyKLineParser.parse(fixture(rows: [row]), symbol: symbol) }
        }
        for edit in [[1: "4"], [2: "4"], [3: "3"], [4: "3.3"]] {
            var row = rows[0]; for (column, value) in edit { row[column] = value }
            try rejected("拒绝OHLC范围矛盾") { _ = try DailyKLineParser.parse(fixture(rows: [row]), symbol: symbol) }
        }
        for bad in ["2026-02-30", "2026-1-04", "20261104", "2026-11-06", "2026-13-01"] {
            var row = rows[0]; row[0] = bad
            try rejected("拒绝非法日期或源时间之后的K线：\(bad)") {
                _ = try DailyKLineParser.parse(fixture(rows: [row]), symbol: symbol)
            }
        }
        for invalidRows in [[], [Array(rows[0].prefix(5))], [rows[0], rows[0]], [rows[1], rows[0]]] {
            try rejected("拒绝空数据、缺列、重复或倒序日期") {
                _ = try DailyKLineParser.parse(fixture(rows: invalidRows), symbol: symbol)
            }
        }
        for badTime in ["", "202611051614", "20260230161451", "20261105241451", "2026AA05161451"] {
            try rejected("拒绝非法源时间") { _ = try DailyKLineParser.parse(fixture(time: badTime), symbol: symbol) }
        }
        for invalid in [fixture(code: 1), fixture(id: "sz000001"), fixture(qtCode: "600519"), Data("{}".utf8), Data("[]".utf8), Data("invalid".utf8)] {
            try rejected("拒绝失败、不匹配或非JSON响应") { _ = try DailyKLineParser.parse(invalid, symbol: symbol) }
        }
    }
    static func waitUntil(_ body: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !body(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(body(), "隔离传输应在两秒内完成事件")
    }
    static func clientTests() async throws {
        var sessions: [URLSession] = []
        let client = DailyKLineClient(makeSession: { configuration in
            configuration.protocolClasses = [DailyKLineTestProtocol.self]
            let session = URLSession(configuration: configuration); sessions.append(session); return session
        })
        DailyKLineTestProtocol.transport.set(.response(200, fixture()))
        _ = try await client.fetch(symbol); _ = try await client.fetch(symbol)
        try expect(sessions.count == 1 && DailyKLineTestProtocol.transport.snapshot.requests.count == 2, "多次刷新复用会话")
        let config = sessions[0].configuration
        try expect(config.urlCache == nil && config.requestCachePolicy == .reloadIgnoringLocalCacheData
                   && config.timeoutIntervalForRequest == 6 && config.timeoutIntervalForResource == 6, "不缓存且限制请求时长")
        for request in DailyKLineTestProtocol.transport.snapshot.requests {
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            try expect(url.scheme == "https" && url.host == "web.ifzq.gtimg.cn"
                       && url.path == "/appstock/app/fqkline/get"
                       && url.queryItems == [URLQueryItem(name: "param", value: "sh600108,day,,,60,qfq")], "仅向固定腾讯接口发送股票代码和日线参数")
            try expect(request.httpMethod == "GET" && request.httpBody == nil
                       && request.cachePolicy == .reloadIgnoringLocalCacheData, "日K请求不发送持仓数据")
        }
        DailyKLineTestProtocol.transport.set(.response(503, Data()))
        do { _ = try await client.fetch(symbol); throw DailyKLineTestFailure(description: "HTTP错误未拒绝") }
        catch DailyKLineError.httpStatus(let code) { try expect(code == 503, "保留HTTP异常状态") }
        DailyKLineTestProtocol.transport.set(.failure(.timedOut))
        let beforeError = DailyKLineTestProtocol.transport.snapshot.requests.count
        do { _ = try await client.fetch(symbol); throw DailyKLineTestFailure(description: "网络错误未拒绝") }
        catch DailyKLineError.requestFailed(let detail) { try expect(!detail.isEmpty, "网络错误可读") }
        try expect(DailyKLineTestProtocol.transport.snapshot.requests.count == beforeError + 1, "失败不做额外隐式请求")
        DailyKLineTestProtocol.transport.set(.failure(.cancelled))
        do { _ = try await client.fetch(symbol); throw DailyKLineTestFailure(description: "取消未映射") }
        catch is CancellationError { try expect(true, "保留URLSession取消语义") }
        DailyKLineTestProtocol.transport.set(.pending)
        let beforeCancel = DailyKLineTestProtocol.transport.snapshot
        let task = Task { try await client.fetch(symbol) }
        try await waitUntil { DailyKLineTestProtocol.transport.snapshot.requests.count == beforeCancel.requests.count + 1 }
        task.cancel()
        do { _ = try await task.value; throw DailyKLineTestFailure(description: "Task取消未生效") }
        catch is CancellationError { try expect(true, "Task取消终止实际请求") }
        try await waitUntil { DailyKLineTestProtocol.transport.snapshot.stops > beforeCancel.stops }
        let requestCount = DailyKLineTestProtocol.transport.snapshot.requests.count
        do { _ = try await client.fetch(StockSymbol(code: "600108&x=1", market: "sh")); throw DailyKLineTestFailure(description: "非法代码未拒绝") }
        catch QuoteError.invalidSymbol { try expect(requestCount == DailyKLineTestProtocol.transport.snapshot.requests.count, "非法代码发请求前拒绝") }
        DailyKLineTestProtocol.transport.set(.response(200, fixture()))
        let recovered = try await client.fetch(symbol)
        try expect(recovered.candles.count == 2 && sessions.count == 1, "取消后同一会话可继续加载")
    }
    static func liveTests() async throws {
        let ids = ["sz980017", "sh000688", "sz399006", "sh000001", "sz399001", "sh000300", "sh000905", "sh000852", "sh600108", "sz000001", "bj920002"]
        let client = DailyKLineClient()
        for id in ids {
            let stock = try StockSymbol.parseList(id)[0]
            let snapshot = try await client.fetch(stock)
            try expect(snapshot.symbol == stock && (1...60).contains(snapshot.candles.count), "实盘日线响应有效：\(id)")
            print("LIVE: \(id) \(snapshot.adjustment) \(snapshot.candles.count)根 \(snapshot.candles.first!.date)…\(snapshot.candles.last!.date)")
        }
    }
    static func main() async {
        do {
            try parserTests(); try await clientTests()
            print("PASS: \(checks) daily K-line assertions (offline)")
            if CommandLine.arguments.contains("--live") { try await liveTests(); print("PASS: daily K-line live validation") }
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
