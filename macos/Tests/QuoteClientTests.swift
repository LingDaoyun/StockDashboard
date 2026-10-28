import Foundation

private struct ClientTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class TransportProbe: @unchecked Sendable {
    enum Result: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
        case pending
    }

    private let lock = NSLock()
    private var result: Result = .pending
    private var requests: [URLRequest] = []
    private var stopped = 0

    func set(_ value: Result) {
        lock.lock(); defer { lock.unlock() }
        result = value
    }

    func begin(_ request: URLRequest) -> Result {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return result
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped += 1
    }

    var snapshot: (requests: [URLRequest], stopped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, stopped)
    }
}

private final class ClientTestProtocol: URLProtocol, @unchecked Sendable {
    static let probe = TransportProbe()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.probe.begin(request) {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Cache-Control": "max-age=3600"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            break
        }
    }

    override func stopLoading() { Self.probe.stop() }
}

private final class SessionProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    private var invalidated = 0

    func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        configuration.protocolClasses = [ClientTestProtocol.self]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.lock(); sessions.append(session); lock.unlock()
        return session
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock(); invalidated += 1; lock.unlock()
    }

    var snapshot: (sessions: [URLSession], invalidated: Int) {
        lock.lock(); defer { lock.unlock() }
        return (sessions, invalidated)
    }

    func cleanUp() {
        lock.lock(); let values = sessions; sessions = []; lock.unlock()
        values.forEach { $0.invalidateAndCancel() }
    }
}

@main
@MainActor
enum QuoteClientTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ClientTestFailure(description: message) }
        checks += 1
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(condition(), "隔离网络测试应在两秒内收到预期事件")
    }

    static func fixture(_ symbols: [StockSymbol], price: String) -> Data {
        Data(symbols.map { symbol in
            var fields = Array(repeating: "", count: 58)
            fields[1] = "synthetic"
            fields[2] = symbol.code
            fields[3] = price
            fields[4] = "10"
            fields[30] = "20261009145653"
            fields[31] = "0"
            fields[32] = "0"
            fields[36] = "100"
            fields[37] = "1"
            return "v_\(symbol.id)=\"\(fields.joined(separator: "~"))\";"
        }.joined(separator: "\n").utf8)
    }

    static func main() async {
        let probe = SessionProbe()
        defer { probe.cleanUp() }
        do {
            let symbols = try StockSymbol.parseList("600001,000002")
            var client: QuoteClient? = QuoteClient(makeSession: { probe.makeSession($0) })
            ClientTestProtocol.probe.set(.response(200, fixture(symbols, price: "10")))
            let first = try await client!.fetch(symbols + [symbols[0]])
            ClientTestProtocol.probe.set(.response(200, fixture(symbols, price: "10.01")))
            let second = try await client!.fetch(symbols)
            try expect(first.count == 2 && first.values.allSatisfy { $0.price == 10 },
                       "第一次请求应真正解析两只股票的批量行情")
            try expect(second.count == 2 && second.values.allSatisfy { $0.price == 10.01 },
                       "第二次必须访问传输层得到新行情，不能使用可缓存的旧响应")
            try expect(ClientTestProtocol.probe.snapshot.requests.count == 2,
                       "连续两次刷新应发生两次真实传输请求")
            try expect(probe.snapshot.sessions.count == 1,
                       "同一客户端连续刷新应只创建一次 URLSession，复用连接池")
            try expect(probe.snapshot.invalidated == 0,
                       "每次成功请求后不能结束共享会话")

            let sessionConfiguration = probe.snapshot.sessions[0].configuration
            try expect(sessionConfiguration.urlCache == nil, "共享会话不应保留行情响应缓存")
            try expect(sessionConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData,
                       "会话配置必须跳过本地缓存")
            try expect(sessionConfiguration.timeoutIntervalForRequest == 6 &&
                       sessionConfiguration.timeoutIntervalForResource == 6,
                       "共享会话继续保留六秒请求与资源超时")
            for request in ClientTestProtocol.probe.snapshot.requests {
                try expect(request.url?.absoluteString == "https://qt.gtimg.cn/q=sh600001,sz000002",
                           "股票仍按固定 HTTPS 地址一次批量请求，并规范化去重")
                try expect(request.httpMethod == "GET", "行情请求保持 GET")
                try expect(request.cachePolicy == .reloadIgnoringLocalCacheData,
                           "每笔实际行情请求都跳过本地缓存")
                try expect(request.timeoutInterval == 6, "每笔请求保留六秒超时")
            }

            let firstTab = try StockSymbol.parseList((600000..<600020).map(String.init).joined(separator: ","))
            let secondTab = try StockSymbol.parseList((600020..<600040).map(String.init).joined(separator: ","))
            let union = firstTab + secondTab
            ClientTestProtocol.probe.set(.response(200, fixture(union, price: "10.04")))
            let beforeUnion = ClientTestProtocol.probe.snapshot.requests.count
            let combined = try await client!.fetch(firstTab + [firstTab[0]] + secondTab + [secondTab[0]])
            try expect(combined.count == 40 && combined.values.allSatisfy { $0.price == 10.04 },
                       "两个各20只股票的页签应在一次合并请求中返回全部40只行情")
            let unionRequests = Array(ClientTestProtocol.probe.snapshot.requests.dropFirst(beforeUnion))
            try expect(unionRequests.count == 1,
                       "40只股票和重复代码应合并为一次传输请求")
            try expect(unionRequests.first?.url?.absoluteString ==
                       "https://qt.gtimg.cn/q=" + union.map(\.id).joined(separator: ","),
                       "合并请求应按首次出现的顺序去重，不受单页20只上限影响")

            let beforeEmpty = ClientTestProtocol.probe.snapshot.requests.count
            let empty = try await client!.fetch([])
            try expect(empty.isEmpty && ClientTestProtocol.probe.snapshot.requests.count == beforeEmpty,
                       "空自选列表直接返回，不访问传输层")
            do {
                _ = try await client!.fetch([StockSymbol(code: "600001&x=1", market: "sh")])
                throw ClientTestFailure(description: "非法代码必须在网络请求前拒绝")
            } catch QuoteError.invalidSymbol {
                try expect(ClientTestProtocol.probe.snapshot.requests.count == beforeEmpty,
                           "非法代码不能拼入 URL 或发出请求")
            }
            for code in ["600001,sz000002", "600001,sh600001"] {
                do {
                    _ = try await client!.fetch([StockSymbol(code: code, market: "sh")])
                    throw ClientTestFailure(description: "单个股票对象不能包含多个代码：\(code)")
                } catch QuoteError.invalidSymbol {
                    try expect(ClientTestProtocol.probe.snapshot.requests.count == beforeEmpty,
                               "含分隔符的股票对象必须在网络请求前拒绝，即使解析后会去重：\(code)")
                }
            }

            ClientTestProtocol.probe.set(.response(503, Data()))
            do {
                _ = try await client!.fetch(symbols)
                throw ClientTestFailure(description: "HTTP 错误必须继续抛出")
            } catch QuoteError.httpStatus(let status) {
                try expect(status == 503, "HTTP 异常状态保留原状态码")
            }
            ClientTestProtocol.probe.set(.response(200, Data("bad response".utf8)))
            do {
                _ = try await client!.fetch(symbols)
                throw ClientTestFailure(description: "损坏响应不能伪造行情")
            } catch QuoteError.noQuotes {
                try expect(true, "解析错误继续保留原错误类型")
            }

            for code in [URLError.Code.networkConnectionLost, .notConnectedToInternet, .timedOut] {
                ClientTestProtocol.probe.set(.failure(code))
                let beforeFailure = ClientTestProtocol.probe.snapshot.requests.count
                do {
                    _ = try await client!.fetch(symbols)
                    throw ClientTestFailure(description: "网络故障必须报告失败：\(code)")
                } catch QuoteError.requestFailed(let detail) {
                    try expect(!detail.isEmpty, "网络故障保留可显示的错误说明：\(code)")
                }
                try expect(ClientTestProtocol.probe.snapshot.requests.count == beforeFailure + 1,
                           "一次失败请求不会自行叠加重试：\(code)")
                ClientTestProtocol.probe.set(.response(200, fixture(symbols, price: "10.02")))
                let recovered = try await client!.fetch(symbols)
                try expect(recovered.count == 2 && recovered.values.allSatisfy { $0.price == 10.02 },
                           "断开连接、断网或超时后，同一客户端下一次请求能恢复：\(code)")
                try expect(probe.snapshot.sessions.count == 1 && probe.snapshot.invalidated == 0,
                           "网络故障无需销毁共享会话或新建客户端：\(code)")
            }

            ClientTestProtocol.probe.set(.failure(.cancelled))
            do {
                _ = try await client!.fetch(symbols)
                throw ClientTestFailure(description: "传输取消必须抛出取消错误")
            } catch is CancellationError {
                try expect(true, "URLError.cancelled 不会误报普通连接失败")
            }

            ClientTestProtocol.probe.set(.pending)
            let beforeCancel = ClientTestProtocol.probe.snapshot
            let cancellable = client!
            let task = Task { try await cancellable.fetch(symbols) }
            try await waitUntil { ClientTestProtocol.probe.snapshot.requests.count == beforeCancel.requests.count + 1 }
            task.cancel()
            do {
                _ = try await task.value
                throw ClientTestFailure(description: "取消 Task 必须终止在途请求")
            } catch is CancellationError {
                try expect(true, "Task 取消保留取消错误类型")
            }
            try await waitUntil { ClientTestProtocol.probe.snapshot.stopped > beforeCancel.stopped }
            ClientTestProtocol.probe.set(.response(200, fixture(symbols, price: "10.03")))
            let afterCancellation = try await client!.fetch(symbols)
            try expect(afterCancellation.values.allSatisfy { $0.price == 10.03 },
                       "取消单次请求后共享会话仍能继续刷新")
            try expect(probe.snapshot.sessions.count == 1 && probe.snapshot.invalidated == 0,
                       "取消单笔请求不能关闭共享会话")

            // Use a separate lexical scope so the cancellation Task cannot retain this client.
            let lifecycleProbe = SessionProbe()
            defer { lifecycleProbe.cleanUp() }
            do {
                let owned = QuoteClient(makeSession: { lifecycleProbe.makeSession($0) })
                _ = try await owned.fetch(symbols)
                try expect(lifecycleProbe.snapshot.invalidated == 0,
                           "客户端存活期间保持会话可复用")
            }
            try await waitUntil { lifecycleProbe.snapshot.invalidated == 1 }
            try expect(lifecycleProbe.snapshot.sessions.count == 1,
                       "客户端释放时清理它唯一拥有的会话")
            client = nil
            print("PASS: \(checks) quote client assertions (isolated URLProtocol; no live requests)")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
