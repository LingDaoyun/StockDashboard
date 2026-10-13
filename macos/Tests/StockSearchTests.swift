import Foundation

private struct SearchTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class SearchTransportProbe: @unchecked Sendable {
    enum Result: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
        case pending
    }
    private let lock = NSLock()
    private var result: Result = .pending
    private var requests: [URLRequest] = []
    private var stopped = 0
    func set(_ value: Result) { lock.lock(); result = value; lock.unlock() }
    func begin(_ request: URLRequest) -> Result {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return result
    }
    func stop() { lock.lock(); stopped += 1; lock.unlock() }
    var snapshot: (requests: [URLRequest], stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stopped)
    }
}

private final class SearchTestProtocol: URLProtocol, @unchecked Sendable {
    static let probe = SearchTransportProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.probe.begin(request) {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending: break
        }
    }
    override func stopLoading() { Self.probe.stop() }
}

@main
@MainActor
enum StockSearchTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SearchTestFailure(description: message) }
        checks += 1
    }
    static func fixture(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["stock": rows, "fund": [["code": "jj123456", "name": "基金"]]])
    }
    static func row(_ id: String, _ name: String, _ type: String = "GP-A") -> [String: Any] {
        ["code": id, "name": name, "type": type]
    }
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(condition(), "隔离搜索网络事件应在两秒内到达")
    }
    static func main() async {
        do {
            let realShape = Data(#"{"stock":[{"code":"sh600108","name":"\u4e9a\u76db\u96c6\u56e2","type":"GP-A","suggest":"","reportInfo":{"match_field":"secu_name","match_level":"full_match"}}],"fund":[]}"#.utf8)
            let asheng = try StockSearchParser.parse(realShape)
            try expect(asheng.count == 1, "真实腾讯 JSON 结构应读到一只股票")
            try expect(asheng[0].symbol.id == "sh600108" && asheng[0].name == "亚盛集团",
                       "JSON Unicode 转义应保留正确中文名称和市场代码")
            try expect(asheng[0].id == asheng[0].symbol.id, "候选身份由市场和证券代码确定")

            let allowed = try StockSearchParser.parse(fixture([
                row("sz002580", "圣阳股份"), row("sz300750", "宁德时代", "GP-A-CYB"),
                row("sh688981", "中芯国际", "GP-A-KCB"), row("bj920077", "吉林碳谷"),
                row("bj830799", "北交所旧代码"), row("sh600519", " 贵州茅台 "),
                row("sz002580", "同代码重复")
            ]))
            try expect(allowed.map(\.id) == ["sz002580", "sz300750", "sh688981", "bj920077", "bj830799", "sh600519"],
                       "主板、创业板、科创板及有合法证券类别的北交所结果保序去重")
            try expect(allowed.last?.name == "贵州茅台", "名称去掉首尾空白")
            for denied in [
                row("hk02318", "中国平安", "GP"), row("usPNGAY.PS", "中国平安", "GP"),
                row("sh512930", "AI人工智能ETF平安", "ETF"), row("sz167001", "平安LOF", "LOF"),
                row("sh000001", "上证指数", "ZS"), row("sh900901", "B股", "GP-B"),
                row("jj123456", "基金", "KJ"), row("ptBK1234", "板块", "BK"),
                row("sh600108", "错误类型", "GP"), row("sz600108", "市场不一致"),
                row("sh000001", "代码市场不一致"), row("sh60010", "位数不足"),
                row("sh600108&x=1", "恶意代码"), row("SH600108", "非规范市场"),
                row("sh600108", "  "), row("sh600108", "标题\n注入"),
                ["code": 600108, "name": "错误类型", "type": "GP-A"],
                ["code": "sh600108", "name": "类型缺失"], ["name": "代码缺失", "type": "GP-A"]
            ] {
                try expect(try StockSearchParser.parse(fixture([denied])).isEmpty,
                           "非 A 股、非法代码或损坏项不得出现在候选列表：\(denied)")
            }
            try expect(try StockSearchParser.parse(fixture([])).isEmpty, "合法空 stock 数组表示无匹配")
            for broken in ["", "<html>error</html>", "v_hint=\"sh~600108~name~ysjt~GP-A\";",
                           "{\"stock\":null}", "{\"stock\":{}}", "{\"fund\":[]}", "[]"] {
                do {
                    _ = try StockSearchParser.parse(Data(broken.utf8))
                    throw SearchTestFailure(description: "损坏响应必须报错，且不能执行响应 JS")
                } catch StockSearchError.invalidResponse { try expect(true, "非约定 JSON 响应被拒绝") }
            }
            let mixed = try StockSearchParser.parse(Data(#"{"stock":[null,42,{"code":"sh600108","name":"亚盛集团","type":"GP-A"}]}"#.utf8))
            try expect(mixed == asheng, "损坏单项不阻断其他有效搜索结果")

            let pingan = try StockSearchParser.parse(fixture([
                row("sh601318", "中国平安"), row("sz000001", "平安银行"), row("sz001359", "平安电工")
            ]))
            try expect(StockSearchResult.automaticMatch(in: [], query: "平安") == nil, "无结果不自动添加")
            try expect(StockSearchResult.automaticMatch(in: pingan, query: "平安") == nil, "多个模糊匹配必须由用户选择")
            try expect(StockSearchResult.automaticMatch(in: pingan, query: "平安银行")?.id == "sz000001", "唯一精确中文名称可自动匹配")
            try expect(StockSearchResult.automaticMatch(in: pingan, query: " 平安银行 ")?.id == "sz000001", "自动匹配忽略输入首尾空白")
            try expect(StockSearchResult.automaticMatch(in: asheng, query: "亚盛")?.id == "sh600108", "只剩一条候选时可自动匹配简称")
            let duplicateNames = [pingan[0], StockSearchResult(symbol: StockSymbol(code: "000001", market: "sz"), name: "中国平安")]
            try expect(StockSearchResult.automaticMatch(in: duplicateNames, query: "中国平安") == nil, "多只同名证券不擅自选第一条")

            var sessions: [URLSession] = []
            let client = StockSearchClient(makeSession: { configuration in
                configuration.protocolClasses = [SearchTestProtocol.self]
                let session = URLSession(configuration: configuration)
                sessions.append(session)
                return session
            })
            defer { sessions.forEach { $0.invalidateAndCancel() } }
            SearchTestProtocol.probe.set(.response(200, realShape))
            let found = try await client.search(" 亚盛集团 ")
            try expect(found == asheng, "真实网络调用应返回解析后的中文搜索结果")
            let request = SearchTestProtocol.probe.snapshot.requests.last!
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            try expect(components.scheme == "https" && components.host == "proxy.finance.qq.com" &&
                       components.path == "/cgi/cgi-bin/smartbox/search", "搜索只向已核验固定 HTTPS 腾讯端点请求")
            try expect(components.queryItems?.first(where: { $0.name == "query" })?.value == "亚盛集团", "中文查询按 UTF-8 正确编码，忽略首尾空白")
            try expect(request.url!.absoluteString.contains("%E4%BA%9A%E7%9B%9B"), "中文请求使用百分号编码")
            try expect(components.queryItems?.first(where: { $0.name == "stockFlag" })?.value == "1", "使用官网股票查询参数")
            try expect(request.httpMethod == "GET" && request.timeoutInterval == 6 && request.cachePolicy == .reloadIgnoringLocalCacheData,
                       "搜索使用 GET、六秒超时及绕过缓存策略")
            try expect(sessions.count == 1 && sessions[0].configuration.urlCache == nil &&
                       sessions[0].configuration.timeoutIntervalForRequest == 6 &&
                       sessions[0].configuration.timeoutIntervalForResource == 6, "复用无缓存且超时受限的单一会话")
            _ = try await client.search("a&stockFlag=0#x+中")
            let encoded = URLComponents(url: SearchTestProtocol.probe.snapshot.requests.last!.url!, resolvingAgainstBaseURL: false)!
            try expect(encoded.queryItems?.first(where: { $0.name == "query" })?.value == "a&stockFlag=0#x+中", "输入参数不能注入第二个请求参数")
            try expect(encoded.queryItems?.filter({ $0.name == "stockFlag" }).count == 1, "固定参数不被用户输入覆盖")
            try expect(sessions.count == 1, "连续名称搜索保持单一会话")
            let beforeEmpty = SearchTestProtocol.probe.snapshot.requests.count
            do {
                _ = try await client.search(" \n ")
                throw SearchTestFailure(description: "空查询必须在请求前拒绝")
            } catch StockSearchError.emptyInput { try expect(SearchTestProtocol.probe.snapshot.requests.count == beforeEmpty, "空输入不发请求") }
            SearchTestProtocol.probe.set(.response(200, try fixture([])))
            try expect(try await client.search("不存在股票").isEmpty, "空搜索结果不假造股票")
            SearchTestProtocol.probe.set(.response(503, Data()))
            do { _ = try await client.search("亚盛"); throw SearchTestFailure(description: "503 必须报告") }
            catch StockSearchError.httpStatus(let status) { try expect(status == 503, "HTTP 故障保留状态") }
            SearchTestProtocol.probe.set(.response(200, Data("bad response".utf8)))
            do { _ = try await client.search("亚盛"); throw SearchTestFailure(description: "损坏网络响应必须报告") }
            catch StockSearchError.invalidResponse { try expect(true, "网络损坏响应报告搜索错误") }
            for code in [URLError.Code.networkConnectionLost, .notConnectedToInternet, .timedOut] {
                SearchTestProtocol.probe.set(.failure(code))
                do { _ = try await client.search("亚盛"); throw SearchTestFailure(description: "网络错误必须报告") }
                catch StockSearchError.requestFailed(let detail) { try expect(!detail.isEmpty, "连接丢失、断网和超时保留说明") }
                SearchTestProtocol.probe.set(.response(200, realShape))
                try expect(try await client.search("亚盛") == asheng, "故障后同一客户端能恢复")
            }
            SearchTestProtocol.probe.set(.failure(.cancelled))
            do { _ = try await client.search("亚盛"); throw SearchTestFailure(description: "传输取消必须保留取消") }
            catch is CancellationError { try expect(true, "取消不能误报连接失败") }
            SearchTestProtocol.probe.set(.pending)
            let beforeCancel = SearchTestProtocol.probe.snapshot
            let pending = Task { try await client.search("亚盛") }
            try await waitUntil { SearchTestProtocol.probe.snapshot.requests.count == beforeCancel.requests.count + 1 }
            pending.cancel()
            do { _ = try await pending.value; throw SearchTestFailure(description: "任务取消必须结束在途请求") }
            catch is CancellationError { try expect(true, "任务取消保留取消类型") }
            try await waitUntil { SearchTestProtocol.probe.snapshot.stopped > beforeCancel.stopped }
            SearchTestProtocol.probe.set(.response(200, realShape))
            try expect(try await client.search("亚盛") == asheng && sessions.count == 1, "取消单次查询后共享会话仍可继续使用")
            print("PASS: \(checks) stock search assertions (isolated URLProtocol; no live requests)")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
