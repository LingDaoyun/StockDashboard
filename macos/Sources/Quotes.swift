import Foundation
import CoreFoundation

struct StockSymbol: Hashable, Sendable, Identifiable {
    let code: String
    let market: String
    var id: String { market + code }

    static func parseList(_ text: String) throws -> [StockSymbol] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，"))
        let tokens = text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw QuoteError.emptyInput }
        var symbols: [StockSymbol] = []
        var seen = Set<String>()
        for token in tokens {
            let explicitMarket = ["sh", "sz", "bj"].first { token.hasPrefix($0) }
            let code = explicitMarket == nil ? token : String(token.dropFirst(2))
            guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw QuoteError.invalidSymbol(token)
            }
            let market: String
            if let explicitMarket { market = explicitMarket }
            else if code.hasPrefix("6") { market = "sh" }
            else if code.hasPrefix("0") || code.hasPrefix("3") { market = "sz" }
            else if code.hasPrefix("4") || code.hasPrefix("8") || code.hasPrefix("92") { market = "bj" }
            else { throw QuoteError.invalidSymbol(token) }
            let symbol = StockSymbol(code: code, market: market)
            if seen.insert(symbol.id).inserted { symbols.append(symbol) }
        }
        guard symbols.count <= 20 else { throw QuoteError.tooManySymbols }
        return symbols
    }
}

struct Quote: Sendable {
    let symbol: StockSymbol
    let name: String
    let price: Double
    let previousClose: Double
    let change: Double
    let changePercent: Double
    let volumeLots: Double
    let amountYuan: Double
    let timestamp: Date
    let turnoverPercent: Double?
}

enum QuoteParser {
    static func parse(_ data: Data, symbols: [StockSymbol]) throws -> [String: Quote] {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: encoding) else { throw QuoteError.invalidEncoding }
        let pattern = #"v_((?:sh|sz|bj)[0-9]{6})\s*=\s*"([^"]*)"\s*;"#
        let regex = try NSRegularExpression(pattern: pattern)
        let requested = Dictionary(symbols.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.isLenient = false
        var quotes: [String: Quote] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let idRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text),
                  let symbol = requested[String(text[idRange])] else { continue }
            let fields = text[bodyRange].components(separatedBy: "~")
            guard fields.count > 37 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let timeText = fields[30]
            let amountText = fields.count > 57 && !fields[57].isEmpty ? fields[57] : fields[37]
            guard !name.isEmpty, fields[2] == symbol.code,
                  let price = number(fields[3]), price > 0,
                  let previousClose = number(fields[4]), previousClose >= 0,
                  let change = number(fields[31]),
                  let changePercent = number(fields[32]),
                  let volumeLots = number(fields[36]), volumeLots >= 0,
                  let amountWan = number(amountText), amountWan >= 0,
                  (amountWan * 10_000).isFinite,
                  timeText.utf8.count == 14, timeText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let timestamp = formatter.date(from: timeText), formatter.string(from: timestamp) == timeText else { continue }
            let turnoverPercent = fields.count > 38 ? number(fields[38]).flatMap { $0 >= 0 ? $0 : nil } : nil
            quotes[symbol.id] = Quote(symbol: symbol, name: name, price: price, previousClose: previousClose,
                                    change: change, changePercent: changePercent, volumeLots: volumeLots,
                                    amountYuan: amountWan * 10_000, timestamp: timestamp, turnoverPercent: turnoverPercent)
        }
        guard !quotes.isEmpty else { throw QuoteError.noQuotes }
        return quotes
    }

    private static func number(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

struct QuoteClient {
    func fetch(_ symbols: [StockSymbol]) async throws -> [String: Quote] {
        guard !symbols.isEmpty else { return [:] }
        let normalized = try StockSymbol.parseList(symbols.map(\.id).joined(separator: ","))
        let url = URL(string: "https://qt.gtimg.cn/q=" + normalized.map(\.id).joined(separator: ","))!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw QuoteError.requestFailed(error.localizedDescription)
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw QuoteError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try QuoteParser.parse(data, symbols: normalized)
    }
}

enum QuoteError: LocalizedError {
    case emptyInput
    case invalidSymbol(String)
    case tooManySymbols
    case invalidEncoding
    case noQuotes
    case requestFailed(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput: "请输入至少一个股票代码。"
        case .invalidSymbol(let code): "股票代码“\(code)”格式不支持，请输入六位代码或 sh、sz、bj 前缀。"
        case .tooManySymbols: "最多显示20只股票，请减少代码数量。"
        case .invalidEncoding: "行情响应编码无法识别，请稍后刷新。"
        case .noQuotes: "没有获取到有效行情，请检查股票代码或稍后刷新。"
        case .requestFailed(let detail): "行情请求失败：\(detail)"
        case .httpStatus(let status): "行情服务返回异常状态（\(status)），请稍后刷新。"
        }
    }
}
