import Foundation

private struct DailyKLineTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class DailyKLineTransport: @unchecked Sendable {
    enum Result: Sendable { case response(Int, Data), failure(URLError.Code), pending }
    private let lock = NSLock()
    private var result: Result = .pending
    private var rawResult: Result?
    private var requests: [URLRequest] = []
    private var stops = 0
    func set(_ value: Result) { lock.lock(); defer { lock.unlock() }; result = value; rawResult = nil }
    func set(main: Result, raw: Result) {
        lock.lock(); defer { lock.unlock() }; result = main; rawResult = raw
    }
    func begin(_ request: URLRequest) -> Result {
        lock.lock(); defer { lock.unlock() }; requests.append(request)
        let param = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name == "param" })?.value
        return param?.hasSuffix(",qfq") == true ? result : (rawResult ?? result)
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
                        qtCode: String? = nil, extra: [String: Any] = [:], qtEdits: [Int: String] = [:]) -> Data {
        var qt = Array(repeating: "", count: 88)
        qt[1] = "测试股票"; qt[2] = qtCode ?? String(id.dropFirst(2)); qt[30] = time
        qt[3] = rows.last.flatMap { $0.count > 2 ? $0[2] as? String : nil } ?? ""
        qt[61] = "GP-A"
        for (index, value) in qtEdits { qt[index] = value }
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
        let start = formatter.date(from: "2022-01-01")!
        let history = (0..<1001).map { offset -> [String] in
            var row = rows[0]
            row[0] = formatter.string(from: start.addingTimeInterval(Double(offset) * 86400))
            return row
        }
        let expanded = try DailyKLineParser.parse(fixture(rows: Array(history.prefix(120))), symbol: symbol)
        try expect(expanded.candles.count == 120 && expanded.candles.first?.date == history[0][0]
                   && expanded.candles.last?.date == history[119][0], "保留超过60根的完整历史供大图缩放")
        let bounded = try DailyKLineParser.parse(fixture(rows: history), symbol: symbol)
        try expect(bounded.candles.count == 1000 && bounded.candles.first?.date == history[1][0]
                   && bounded.candles.last?.date == history.last?[0], "源追加当日记录超过上限时保留最新1000根")
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
    static func priceLimitTests() throws {
        let closes = [10.0, 10, 10, 10, 10, 11, 9.9, 9.91]
        let raw: [[Any]] = closes.enumerated().map { index, close in
            let open = index == 0 ? 10 : closes[index - 1]
            return [String(format: "2026-10-%02d", index + 1),
                    String(format: "%.2f", open), String(format: "%.2f", close),
                    String(format: "%.2f", max(open, close)), String(format: "%.2f", min(open, close)), "1000"]
        }
        let adjusted: [[Any]] = raw.map { row in
            [row[0]] + (1...4).map { String(format: "%.3f", Double(row[$0] as! String)! * 0.8) } + [row[5]]
        }
        let snapshot = try DailyKLineParser.parse(fixture(rows: adjusted), symbol: symbol,
            unadjustedData: fixture(rows: raw, key: "day"))
        try expect(snapshot.candles[5].limitStatus == .up, "未复权收盘封涨停应在对应前复权K线上标识")
        try expect(snapshot.candles[6].limitStatus == .down, "未复权收盘封跌停应在对应前复权K线上标识")
        try expect(snapshot.candles[7].limitStatus == nil, "普通收盘不能标识为涨跌停")
        try expect(snapshot.candles[5].close == 8.8 && snapshot.adjustment == "前复权", "限价判断不能改写显示的前复权OHLC")
        let shortDisplay = try DailyKLineParser.parse(fixture(rows: Array(adjusted.suffix(3))), symbol: symbol,
            unadjustedData: fixture(rows: raw, key: "day"))
        try expect(shortDisplay.candles.map(\.limitStatus) == [.up, .down, nil],
                   "两份序列长度不同时按日期匹配，并用原始历史而非显示窗口判定前五条")
        for unusable in [Data("invalid".utf8), fixture(rows: raw, key: "day", id: "sz000001"),
                         fixture(rows: raw, key: "day", code: 1), fixture(rows: adjusted)] {
            let preserved = try DailyKLineParser.parse(fixture(rows: adjusted), symbol: symbol, unadjustedData: unusable)
            try expect(preserved.candles.count == adjusted.count && preserved.candles.allSatisfy { $0.limitStatus == nil },
                       "辅助原价无效、证券不匹配或仍为前复权时保留主图且不猜历史涨跌停")
        }
        let missingDay = try DailyKLineParser.parse(fixture(rows: adjusted), symbol: symbol,
            unadjustedData: fixture(rows: raw.enumerated().filter { $0.offset != 5 }.map(\.element), key: "day"))
        try expect(missingDay.candles[5].limitStatus == nil, "原价缺少对应交易日时不能错位贴上相邻日标识")

        func historyStatus(previous: String = "10.00", close: String,
                           high: String? = nil, low: String? = nil, volume: String = "1000",
                           stock: StockSymbol = symbol, extraColumn: Any? = nil,
                           month: String = "2026-10",
                           qtEdits: [Int: String] = [:], time: String = "20261105161451") throws -> DailyPriceLimit? {
            var history: [[Any]] = (1...5).map { index in
                [String(format: "%@-%02d", month, index), previous, previous, previous, previous, "1000"]
            }
            var last: [Any] = ["\(month)-06", previous, close,
                               high ?? String(max(Double(previous)!, Double(close)!)),
                               low ?? String(min(Double(previous)!, Double(close)!)), volume]
            if let extraColumn { last.append(extraColumn) }
            history.append(last)
            return try DailyKLineParser.parse(fixture(rows: history, key: "day", id: stock.id,
                                                      time: time, qtEdits: qtEdits), symbol: stock).candles.last?.limitStatus
        }
        try expect(try historyStatus(close: "10.99", high: "10.99") == nil, "差一分钱未封涨停不能近似当涨停")
        try expect(try historyStatus(close: "10.98", high: "11.00") == nil, "盘中触及涨停但收盘打开不标收盘涨停")
        try expect(try historyStatus(close: "9.01", low: "9.00") == nil, "盘中触及跌停但收盘打开不标收盘跌停")
        try expect(try historyStatus(close: "11.00", high: "11.01") == nil, "最高超出推算涨停价时拒绝将无幅限行情误标")
        try expect(try historyStatus(close: "11.00", low: "8.99") == nil, "最低低于推算跌停价时整根不能认定涨停")
        try expect(try historyStatus(close: "9.00", high: "11.01") == nil, "收盘在跌停价但最高越上限也不能认定")
        try expect(try historyStatus(close: "11.00", volume: "0") == nil, "零成交量占位K线不标涨跌停")
        try expect(try historyStatus(previous: "10.05", close: "11.06") == .up, "涨停价按分四舍五入，半分向上而非银行家舍入")
        try expect(try historyStatus(previous: "10.05", close: "9.05") == .down, "跌停价也按分四舍五入，不能直接比较百分比")
        try expect(try historyStatus(previous: "10.05", close: "11.05") == nil, "未到四舍五入后的涨停价不能误标")
        try expect(try historyStatus(close: "11.00", extraColumn: ["fh_sh": "1", "cqr": "2026-10-06"]) == nil,
                   "除权分红日不拿前日原始收盘推算限价")
        try expect(try historyStatus(close: "10.50", month: "2026-06", qtEdits: [1: "*ST测试"]) == nil,
                   "没有历史风险警示元数据时不凭当前名称猜历史五个百分点涨停")
        let opening = try DailyKLineParser.parse(fixture(rows: Array(raw.prefix(5)), key: "day"), symbol: symbol)
        try expect(opening.candles.allSatisfy { $0.limitStatus == nil }, "原始历史前五条保守不做历史限幅识别")
        let earlyLimitRows: [[Any]] = (0..<5).map { index in
            let previous = pow(1.1, Double(index)) * 10
            let close = (previous * 1.1 * 100).rounded() / 100
            return [String(format: "2026-10-%02d", index + 1), String(previous), String(close), String(close), String(previous), "1000"]
        }
        let ipo = try DailyKLineParser.parse(fixture(rows: earlyLimitRows, key: "day"), symbol: symbol)
        try expect(ipo.candles.allSatisfy { $0.limitStatus == nil }, "前五条即使表面每天涨十个百分点也不冒充IPO涨停")
        for stock in [StockSymbol(code: "300750", market: "sz"), StockSymbol(code: "301001", market: "sz"),
                      StockSymbol(code: "688001", market: "sh"), StockSymbol(code: "689009", market: "sh")] {
            try expect(try historyStatus(close: "12.00", stock: stock) == .up, "创业板和科创板按二十个百分点识别：\(stock.id)")
            try expect(try historyStatus(close: "8.00", stock: stock) == .down, "创业板和科创板跌停为二十个百分点：\(stock.id)")
            try expect(try historyStatus(close: "11.00", stock: stock) == nil, "成长板块普通十个百分点上涨不误标涨停")
        }
        let oldChiNext = StockSymbol(code: "300750", market: "sz")
        try expect(try historyStatus(close: "11.00", stock: oldChiNext, month: "2020-08") == .up,
                   "创业板规则变更前的历史按十个百分点识别")
        try expect(try historyStatus(close: "12.00", stock: oldChiNext, month: "2020-08") == nil,
                   "创业板旧历史不能套用现在二十个百分点的限幅")
        let beijing = StockSymbol(code: "920002", market: "bj")
        try expect(try historyStatus(close: "13.00", stock: beijing) == .up, "北交所涨停按三十个百分点识别")
        try expect(try historyStatus(close: "7.00", stock: beijing) == .down, "北交所跌停按三十个百分点识别")
        for stock in [StockSymbol(code: "000001", market: "sh"), StockSymbol(code: "399001", market: "sz"),
                      StockSymbol(code: "980017", market: "sz"), StockSymbol(code: "510300", market: "sh") ] {
            try expect(try historyStatus(close: "11.00", stock: stock) == nil, "指数或未知证券类型不套普通股票限幅：\(stock.id)")
        }

        func currentStatus(close: String = "11.00", high: String = "11.00", low: String = "10.00",
                           day: String = "2026-11-05", volume: String = "1000",
                           edits: [Int: String] = [:], extraColumn: Any? = nil) throws -> DailyPriceLimit? {
            var row: [Any] = [day, "10.00", close, high, low, volume]
            if let extraColumn { row.append(extraColumn) }
            var qt = [3: close, 4: "10.00", 47: "11.00", 48: "9.00"]
            qt.merge(edits) { _, new in new }
            return try DailyKLineParser.parse(fixture(rows: [row], qtEdits: qt), symbol: symbol).candles[0].limitStatus
        }
        try expect(try currentStatus() == .up, "源日真实涨停价可识别只有一根的最新K线，不靠历史比例猜测")
        try expect(try currentStatus(close: "9.00", high: "10.00", low: "9.00") == .down, "源日真实跌停价可直接识别")
        try expect(try currentStatus(close: "10.50", high: "10.50", edits: [47: "10.50", 48: "9.50"]) == .up,
                   "当天使用来源明确的实际限价，不强行套历史标准比例")
        try expect(try currentStatus(extraColumn: ["fh_sh": "1", "cqr": "2026-11-05"]) == .up,
                   "当天除权有源明确限价时仍可识别，不使用前收推算")
        try expect(try currentStatus(edits: [3: "10.99"]) == nil, "quote最新价与展示尾K收盘价不一致时不提前贴涨停")
        try expect(try currentStatus(day: "2026-11-04") == nil, "当前限价不得用于旧交易日或停牌历史末根")
        try expect(try currentStatus(high: "11.01") == nil, "当前行情高点越过真实上限时拒绝错误封板标识")
        try expect(try currentStatus(low: "8.99") == nil, "当前行情低点越过真实下限时拒绝错误封板标识")
        try expect(try currentStatus(volume: "0") == nil, "当天无成交量不标涨跌停")
        for edits in [[47: "-1", 48: "-1"], [47: ""], [48: ""], [47: "NaN"], [47: "9.00", 48: "11.00"]] {
            try expect(try currentStatus(edits: edits) == nil, "无幅限、缺失或无效限价不凭价格接近推测")
        }
        try expect(try historyStatus(close: "11.00", qtEdits: [3: "11.00", 47: "-1", 48: "-1"],
                                     time: "20261006150000") == nil,
                   "源日明确无幅限时即使超过历史前五条也不能退回百分比推算")
    }
    static func clientTests() async throws {
        var sessions: [URLSession] = []
        let client = DailyKLineClient(makeSession: { configuration in
            configuration.protocolClasses = [DailyKLineTestProtocol.self]
            let session = URLSession(configuration: configuration); sessions.append(session); return session
        })
        DailyKLineTestProtocol.transport.set(main: .response(200, fixture()), raw: .response(200, fixture(key: "day")))
        _ = try await client.fetch(symbol); _ = try await client.fetch(symbol)
        try expect(sessions.count == 1 && DailyKLineTestProtocol.transport.snapshot.requests.count == 4,
                   "股票每次只请求前复权和原价两份历史，两次刷新仍复用同一会话")
        let config = sessions[0].configuration
        try expect(config.urlCache == nil && config.requestCachePolicy == .reloadIgnoringLocalCacheData
                   && config.timeoutIntervalForRequest == 6 && config.timeoutIntervalForResource == 6, "不缓存且限制请求时长")
        for (index, request) in DailyKLineTestProtocol.transport.snapshot.requests.enumerated() {
            let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let adjustment = index.isMultiple(of: 2) ? "qfq" : ""
            try expect(url.scheme == "https" && url.host == "web.ifzq.gtimg.cn"
                       && url.path == "/appstock/app/fqkline/get"
                       && url.queryItems == [URLQueryItem(name: "param", value: "sh600108,day,,,1000," + adjustment)],
                       "仅向原腾讯接口发送同证券前复权及空后缀原价请求，不新增其他源")
            try expect(request.httpMethod == "GET" && request.httpBody == nil
                       && request.cachePolicy == .reloadIgnoringLocalCacheData, "日K请求不发送持仓数据")
        }
        let raw: [[Any]] = (1...6).map { index in
            [String(format: "2026-10-%02d", index), "10.00", index == 6 ? "11.00" : "10.00",
             index == 6 ? "11.00" : "10.00", "10.00", "1000"]
        }
        let adjusted: [[Any]] = raw.map { row in
            [row[0]] + (1...4).map { String(format: "%.3f", Double(row[$0] as! String)! * 0.8) } + [row[5]]
        }
        DailyKLineTestProtocol.transport.set(main: .response(200, fixture(rows: adjusted)),
                                            raw: .response(200, fixture(rows: raw, key: "day")))
        let merged = try await client.fetch(symbol)
        try expect(merged.candles.last?.limitStatus == .up && merged.candles.last?.close == 8.8
                   && merged.adjustment == "前复权", "客户端将原价识别结果按日期附给前复权主图")
        for supplemental in [DailyKLineTransport.Result.response(501, Data()), .failure(.timedOut),
                             .response(200, Data("invalid".utf8))] {
            DailyKLineTestProtocol.transport.set(main: .response(200, fixture(rows: adjusted)), raw: supplemental)
            let before = DailyKLineTestProtocol.transport.snapshot.requests.count
            let preserved = try await client.fetch(symbol)
            try expect(preserved.candles.last?.close == 8.8 && preserved.candles.allSatisfy { $0.limitStatus == nil },
                       "辅助原价HTTP失败、超时或坏数据只省略标识，不丢失可用前复权图")
            try expect(DailyKLineTestProtocol.transport.snapshot.requests.count == before + 2,
                       "辅助原价失败不重复重试或访问新数据源")
        }
        for (stock, key) in [(symbol, "day"), (StockSymbol(code: "000001", market: "sh"), "day"),
                             (StockSymbol(code: "510300", market: "sh"), "qfqday")] {
            DailyKLineTestProtocol.transport.set(main: .response(200, fixture(key: key, id: stock.id)), raw: .pending)
            let before = DailyKLineTestProtocol.transport.snapshot.requests.count
            _ = try await client.fetch(stock)
            try expect(DailyKLineTestProtocol.transport.snapshot.requests.count == before + 1,
                       "主响应已是原价、指数或未知类型不额外请求辅助历史")
        }
        DailyKLineTestProtocol.transport.set(.response(200, Data("invalid".utf8)))
        let beforeInvalid = DailyKLineTestProtocol.transport.snapshot.requests.count
        do { _ = try await client.fetch(symbol); throw DailyKLineTestFailure(description: "主图坏数据未拒绝") }
        catch DailyKLineError.invalidData {
            try expect(DailyKLineTestProtocol.transport.snapshot.requests.count == beforeInvalid + 1,
                       "主图未解析成功时不发辅助原价请求")
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
        DailyKLineTestProtocol.transport.set(main: .response(200, fixture()), raw: .failure(.cancelled))
        do { _ = try await client.fetch(symbol); throw DailyKLineTestFailure(description: "辅助原价取消被吞掉") }
        catch is CancellationError { try expect(true, "辅助原价传输取消必须传播，不能当作可忽略的网络失败") }
        DailyKLineTestProtocol.transport.set(main: .response(200, fixture()), raw: .pending)
        let beforeRawCancel = DailyKLineTestProtocol.transport.snapshot
        let rawTask = Task { try await client.fetch(symbol) }
        try await waitUntil { DailyKLineTestProtocol.transport.snapshot.requests.count == beforeRawCancel.requests.count + 2 }
        rawTask.cancel()
        do { _ = try await rawTask.value; throw DailyKLineTestFailure(description: "辅助请求期间Task取消未生效") }
        catch is CancellationError { try expect(true, "切图时正在进行的第二请求也被取消，不能发布旧图") }
        try await waitUntil { DailyKLineTestProtocol.transport.snapshot.stops > beforeRawCancel.stops }
        let requestCount = DailyKLineTestProtocol.transport.snapshot.requests.count
        do { _ = try await client.fetch(StockSymbol(code: "600108&x=1", market: "sh")); throw DailyKLineTestFailure(description: "非法代码未拒绝") }
        catch QuoteError.invalidSymbol { try expect(requestCount == DailyKLineTestProtocol.transport.snapshot.requests.count, "非法代码发请求前拒绝") }
        DailyKLineTestProtocol.transport.set(main: .response(200, fixture()), raw: .response(200, fixture(key: "day")))
        let recovered = try await client.fetch(symbol)
        try expect(recovered.candles.count == 2 && sessions.count == 1, "取消后同一会话可继续加载")
    }
    static func liveTests() async throws {
        let ids = ["sz980017", "sh000688", "sz399006", "sh000001", "sz399001", "sh000300", "sh000905", "sh000852", "sh600108", "sz000001", "bj920002"]
        let client = DailyKLineClient()
        for id in ids {
            let stock = try StockSymbol.parseList(id)[0]
            let snapshot = try await client.fetch(stock)
            try expect(snapshot.symbol == stock && (1...DailyKLineClient.historyLimit).contains(snapshot.candles.count), "实盘日线响应有效：\(id)")
            print("LIVE: \(id) \(snapshot.adjustment) \(snapshot.candles.count)根 \(snapshot.candles.first!.date)…\(snapshot.candles.last!.date)")
        }
    }
    static func main() async {
        do {
            try parserTests(); try priceLimitTests(); try await clientTests()
            print("PASS: \(checks) daily K-line assertions (offline)")
            if CommandLine.arguments.contains("--live") { try await liveTests(); print("PASS: daily K-line live validation") }
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
