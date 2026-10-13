import Foundation

struct StockSearchResult: Hashable, Sendable, Identifiable {
    let symbol: StockSymbol
    let name: String
    var id: String { symbol.id }
    static func automaticMatch(in results: [StockSearchResult], query: String) -> StockSearchResult? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = results.filter { $0.name == name }
        if exact.count == 1 { return exact[0] }
        return results.count == 1 ? results[0] : nil
    }
}

enum StockSearchParser {
    static func parse(_ data: Data) throws -> [StockSearchResult] {
        // Tencent's current website consumes this JSON endpoint; never evaluate response scripts.
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["stock"] as? [Any] else { throw StockSearchError.invalidResponse }
        let allowedTypes: Set<String> = ["GP-A", "GP-A-CYB", "GP-A-KCB"]
        var results: [StockSearchResult] = []
        var seen = Set<String>()
        for case let row as [String: Any] in rows {
            guard let id = row["code"] as? String, let rawName = row["name"] as? String,
                  let type = row["type"] as? String, allowedTypes.contains(type), id.count == 8,
                  let symbol = try? StockSymbol.parseList(String(id.dropFirst(2))).first,
                  symbol.id == id else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seen.insert(id).inserted else { continue }
            results.append(StockSearchResult(symbol: symbol, name: name))
        }
        return results
    }
}

final class StockSearchClient: Sendable {
    private let session: URLSession
    init(makeSession: (URLSessionConfiguration) -> URLSession = { URLSession(configuration: $0) }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        session = makeSession(configuration)
    }
    deinit { session.invalidateAndCancel() }
    func search(_ query: String) async throws -> [StockSearchResult] {
        try Task.checkCancellation()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StockSearchError.emptyInput }
        var components = URLComponents(string: "https://proxy.finance.qq.com/cgi/cgi-bin/smartbox/search")!
        components.queryItems = [URLQueryItem(name: "stockFlag", value: "1"),
                                 URLQueryItem(name: "fundFlag", value: "1"),
                                 URLQueryItem(name: "app", value: "official_website"),
                                 URLQueryItem(name: "c", value: "1"),
                                 URLQueryItem(name: "query", value: text)]
        // The server also accepts form-style queries, where an unescaped '+' means a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw StockSearchError.requestFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StockSearchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try StockSearchParser.parse(data)
    }
}

enum StockSearchError: LocalizedError {
    case emptyInput
    case invalidResponse
    case requestFailed(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .emptyInput: "请输入股票名称或代码。"
        case .invalidResponse: "股票搜索响应无法识别，请稍后重试或输入代码。"
        case .requestFailed(let detail): "股票搜索连接失败：\(detail)"
        case .httpStatus(let status): "股票搜索服务返回 HTTP \(status)，请稍后重试。"
        }
    }
}
