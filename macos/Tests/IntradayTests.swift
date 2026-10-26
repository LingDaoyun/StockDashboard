import Foundation

private struct IntradayTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class IntradayTransport: @unchecked Sendable {
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

private final class IntradayTestProtocol: URLProtocol, @unchecked Sendable {
    static let transport = IntradayTransport()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.transport.begin(request) {
        case .response(let status, let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=3600"])!, cacheStoragePolicy: .allowed)
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
enum IntradayTests {
    static var checks = 0
    static let symbol = StockSymbol(code: "600108", market: "sh")
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw IntradayTestFailure(description: message) }; checks += 1
    }
    static func rejected(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch let failure as IntradayTestFailure { throw failure }
        catch { try expect(error is LocalizedError && !error.localizedDescription.isEmpty, message); return }
        throw IntradayTestFailure(description: message)
    }
    static func fixture(rows: [String] = ["0930 3.35 6607 2213345", "0931 3.35 45881 15375472"],
                        date: String = "20261026", time: String = "20261026093033",
                        previousClose: String = "3.36", code: Int = 0, id: String = "sh600108",
                        qtEdits: [Int: String] = [:], extraQT: [String: Any] = [:]) -> Data {
        var qt = Array(repeating: "", count: 38)
        qt[2] = String(id.dropFirst(2)); qt[3] = "3.35"; qt[4] = previousClose; qt[30] = time
        for (index, value) in qtEdits { qt[index] = value }
        var quotes: [String: Any] = extraQT
        quotes[id] = qt
        return try! JSONSerialization.data(withJSONObject: ["code": code, "data": [id: [
            "data": ["date": date, "data": rows], "qt": quotes]]])
    }
    static func waitUntil(_ body: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !body(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(body(), "隔离传输应在两秒内完成事件")
    }
    static func parserTests() throws {
        let value = try IntradayParser.parse(fixture(), symbol: symbol)
        let mixedQT = try IntradayParser.parse(fixture(extraQT: ["market": ["status": true], "v_ff_sh600108": NSNull()]), symbol: symbol)
        try expect(mixedQT.points.count == 2, "无关qt字段的混合类型不应阻止目标股票解析")
        try expect(value.symbol == symbol && value.date == "20261026", "分时数据匹配代码和交易日")
        try expect(value.previousClose == 3.36 && value.points.map(\.price) == [3.35, 3.35], "读取昨收和价格")
        try expect(value.points.map(\.cumulativeVolumeLots) == [6607, 45881], "累计量保留手单位，不乘100")
        try expect(value.points.map(\.volumeLots) == [6607, 39274], "首点保留源量，后续量柱为累计差分")
        try expect(value.points.map(\.minute) == [570, 571] && value.points[0].id == 570, "分钟和稳定ID")
        try expect(value.points[0].timeText == "09:30" && value.points[1].sessionMinute == 1, "时间标签与交易分钟")
        let formatter = ISO8601DateFormatter()
        try expect(value.timestamp == formatter.date(from: "2026-10-26T01:30:33Z"), "源时间用北京时间qt[30]，不用向上取整的0931点")
        let lunch = try IntradayParser.parse(fixture(rows: ["1130 3.35 100", "1300 3.35 100", "1301 3.36 120"],
                                                   time: "20261026130100"), symbol: symbol)
        try expect(lunch.points.map(\.volumeLots) == [nil, 0, 20], "首点缺失0930时量未知；午休跨越不制造成交量")
        try expect(lunch.points.map(\.sessionMinute) == [120, 120, 121], "午休时间轴压缩")
        let gap = try IntradayParser.parse(fixture(rows: ["0930 3.35 100", "0932 3.36 150", "0933 3.37 180"],
                                                 time: "20261026093300"), symbol: symbol)
        try expect(gap.points.map(\.volumeLots) == [100, nil, 30], "缺分钟不能把多分钟累积当单分钟量")
        let zero = try IntradayParser.parse(fixture(rows: ["0930 3.35 0", "0931 3.35 0"]), symbol: symbol)
        try expect(zero.points.map(\.volumeLots) == [0, 0], "真实零量保留")
        let beijing = StockSymbol(code: "920002", market: "bj")
        let beijingValue = try IntradayParser.parse(fixture(rows: ["0930 51.90 130", "0931 52.04 732"],
                                                           id: beijing.id), symbol: beijing)
        try expect(beijingValue.points.map(\.volumeLots) == [130, 602], "北交所三列数据与qt相同保留手单位")
        for bad in ["NaN", "inf", "-1", "bad"] {
            try rejected("拒绝非法累计量 \(bad)") { _ = try IntradayParser.parse(fixture(rows: ["0930 3.35 \(bad)"]), symbol: symbol) }
        }
        for bad in ["0", "-1", "NaN", "inf", "bad"] {
            try rejected("拒绝非法价格 \(bad)") { _ = try IntradayParser.parse(fixture(rows: ["0930 \(bad) 100"]), symbol: symbol) }
            try rejected("拒绝非法昨收 \(bad)") { _ = try IntradayParser.parse(fixture(previousClose: bad), symbol: symbol) }
            try rejected("拒绝非法源现价 \(bad)") { _ = try IntradayParser.parse(fixture(qtEdits: [3: bad]), symbol: symbol) }
        }
        for rows in [[], ["0930 3.35"], ["0930 3.35 100", "0931 3.35 90"],
                     ["0930 3.35 100", "0930 3.35 100"], ["0931 3.35 100", "0930 3.35 101"],
                     ["0929 3.35 100"], ["1131 3.35 100"], ["1259 3.35 100"],
                     ["1501 3.35 100"], ["0960 3.35 100"], ["930 3.35 100"], ["0932 3.35 100"]] {
            try rejected("拒绝空、无效、倒退、重复、乱序、超前和交易外分钟") {
                _ = try IntradayParser.parse(fixture(rows: rows), symbol: symbol)
            }
        }
        for (date, time) in [("20260230", "20260230093000"), ("20261026", "20261025093000"),
                             ("20261026", "20261026096000"), ("20261026", "202610260930"),
                             ("2026102x", "20261026093000")] {
            try rejected("交易日和源时间严格校验") { _ = try IntradayParser.parse(fixture(date: date, time: time), symbol: symbol) }
        }
        for data in [Data(), Data("<html>error</html>".utf8), fixture(code: 1), fixture(id: "sz000858")] {
            try rejected("拒绝失败或不匹配的响应") { _ = try IntradayParser.parse(data, symbol: symbol) }
        }
        try rejected("qt代码必须匹配目标股票") { _ = try IntradayParser.parse(fixture(qtEdits: [2: "600519"]), symbol: symbol) }
    }
    static func clientTests() async throws {
        var sessions: [URLSession] = []
        let client = IntradayClient(makeSession: { configuration in
            configuration.protocolClasses = [IntradayTestProtocol.self]
            let session = URLSession(configuration: configuration); sessions.append(session); return session
        })
        IntradayTestProtocol.transport.set(.response(200, fixture()))
        _ = try await client.fetch(symbol); _ = try await client.fetch(symbol)
        try expect(sessions.count == 1 && IntradayTestProtocol.transport.snapshot.requests.count == 2, "复用会话且两次请求不读旧缓存")
        let config = sessions[0].configuration
        try expect(config.urlCache == nil && config.requestCachePolicy == .reloadIgnoringLocalCacheData, "临时会话不缓存")
        try expect(config.timeoutIntervalForRequest == 6 && config.timeoutIntervalForResource == 6, "请求资源超时均6秒")
        for request in IntradayTestProtocol.transport.snapshot.requests {
            try expect(request.url?.absoluteString == "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=sh600108", "只发送目标股票代码到固定HTTPS端点")
            try expect(request.httpMethod == "GET" && request.httpBody == nil && request.timeoutInterval == 6 &&
                       request.cachePolicy == .reloadIgnoringLocalCacheData, "单GET不发持仓且不缓存")
        }
        IntradayTestProtocol.transport.set(.response(503, Data()))
        do { _ = try await client.fetch(symbol); throw IntradayTestFailure(description: "HTTP错误未拒绝") }
        catch IntradayError.httpStatus(let code) { try expect(code == 503, "保留HTTP状态") }
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            IntradayTestProtocol.transport.set(.failure(code))
            let count = IntradayTestProtocol.transport.snapshot.requests.count
            do { _ = try await client.fetch(symbol); throw IntradayTestFailure(description: "网络错误未拒绝") }
            catch IntradayError.requestFailed(let detail) { try expect(!detail.isEmpty, "网络失败保留可读信息") }
            try expect(IntradayTestProtocol.transport.snapshot.requests.count == count + 1, "单次请求失败不自动重试")
        }
        IntradayTestProtocol.transport.set(.failure(.cancelled))
        do { _ = try await client.fetch(symbol); throw IntradayTestFailure(description: "取消未映射") }
        catch is CancellationError { try expect(true, "传输取消保持取消语义") }
        IntradayTestProtocol.transport.set(.pending)
        let before = IntradayTestProtocol.transport.snapshot
        let task = Task { try await client.fetch(symbol) }
        try await waitUntil { IntradayTestProtocol.transport.snapshot.requests.count == before.requests.count + 1 }
        task.cancel()
        do { _ = try await task.value; throw IntradayTestFailure(description: "Task取消未生效") }
        catch is CancellationError { try expect(true, "Task取消保持取消语义") }
        try await waitUntil { IntradayTestProtocol.transport.snapshot.stops > before.stops }
        IntradayTestProtocol.transport.set(.response(200, fixture()))
        let recovered = try await client.fetch(symbol)
        try expect(recovered.points.count == 2 && sessions.count == 1, "取消和网络失败后原会话可恢复")
        let count = IntradayTestProtocol.transport.snapshot.requests.count
        do { _ = try await client.fetch(StockSymbol(code: "600108&x=1", market: "sh")); throw IntradayTestFailure(description: "无效代码未拒绝") }
        catch QuoteError.invalidSymbol { try expect(IntradayTestProtocol.transport.snapshot.requests.count == count, "无效代码在请求前拒绝") }
    }
    static func main() async {
        do { try parserTests(); try await clientTests(); print("PASS: \(checks) intraday assertions (offline)") }
        catch { print("FAIL: \(error)"); exit(1) }
    }
}
