import Foundation

protocol DailyKLineFetching: Sendable {
    func fetch(_ symbol: StockSymbol) async throws -> DailyKLineSnapshot
}

struct DailyCandle: Identifiable, Sendable {
    let date: String
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volumeLots: Double
    var id: String { date }
}

struct DailyKLineSnapshot: Sendable {
    let symbol: StockSymbol
    let candles: [DailyCandle]
    let adjustment: String
    let timestamp: Date
}

enum DailyKLineError: LocalizedError {
    case invalidData
    case requestFailed(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidData: "没有获取到有效日K数据，请稍后刷新。"
        case .requestFailed(let detail): "日K请求失败：\(detail)"
        case .httpStatus(let status): "日K服务返回异常状态（\(status)），请稍后刷新。"
        }
    }
}

enum DailyKLineParser {
    static func parse(_ data: Data, symbol: StockSymbol) throws -> DailyKLineSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["code"] as? Int == 0,
              let payloads = root["data"] as? [String: Any],
              let payload = payloads[symbol.id] as? [String: Any],
              let quotes = payload["qt"] as? [String: Any],
              let quote = quotes[symbol.id] as? [String], quote.count > 30,
              quote[2] == symbol.code else { throw DailyKLineError.invalidData }

        // Indices and some stocks provide ordinary day data even when qfq is requested.
        // Label the series actually returned; never mix adjusted and ordinary prices.
        let key = payload["qfqday"] == nil ? "day" : "qfqday"
        guard let rows = payload[key] as? [[Any]], !rows.isEmpty else {
            throw DailyKLineError.invalidData
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMddHHmmss"
        let time = quote[30]
        guard time.utf8.count == 14, time.utf8.allSatisfy({ (48...57).contains($0) }),
              let timestamp = formatter.date(from: time), formatter.string(from: timestamp) == time else {
            throw DailyKLineError.invalidData
        }
        formatter.dateFormat = "yyyy-MM-dd"
        let sourceDay = formatter.string(from: timestamp)
        var candles: [DailyCandle] = []
        for fields in rows {
            // Ex-dividend rows may append a corporate-action object after the six price/volume fields.
            guard fields.count >= 6, let row = Array(fields.prefix(6)) as? [String], row[0].utf8.count == 10,
                  let day = formatter.date(from: row[0]), formatter.string(from: day) == row[0],
                  row[0] <= sourceDay,
                  candles.last.map({ $0.date < row[0] }) ?? true,
                  let open = positiveNumber(row[1]), let close = positiveNumber(row[2]),
                  let high = positiveNumber(row[3]), let low = positiveNumber(row[4]),
                  low <= min(open, close), high >= max(open, close),
                  let volume = Double(row[5]), volume.isFinite, volume >= 0 else {
                throw DailyKLineError.invalidData
            }
            candles.append(DailyCandle(date: row[0], open: open, close: close,
                                       high: high, low: low, volumeLots: volume))
        }
        // The service can append today's candle to the requested 60 historical rows.
        return DailyKLineSnapshot(symbol: symbol, candles: Array(candles.suffix(60)),
                                  adjustment: key == "qfqday" ? "前复权" : "不复权", timestamp: timestamp)
    }

    private static func positiveNumber(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }
}

final class DailyKLineClient: DailyKLineFetching, Sendable {
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

    func fetch(_ symbol: StockSymbol) async throws -> DailyKLineSnapshot {
        let normalized = try StockSymbol.parseList(symbol.id)
        guard normalized.count == 1, normalized[0] == symbol else { throw QuoteError.invalidSymbol(symbol.id) }
        let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=" + symbol.id + ",day,,,60,qfq")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw DailyKLineError.requestFailed(error.localizedDescription)
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw DailyKLineError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try DailyKLineParser.parse(data, symbol: symbol)
    }
}
