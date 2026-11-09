import Foundation

protocol DailyKLineFetching: Sendable {
    func fetch(_ symbol: StockSymbol) async throws -> DailyKLineSnapshot
}

enum DailyPriceLimit: String, Sendable {
    case up, down

    var title: String { self == .up ? "涨停" : "跌停" }

    static func percentage(for symbol: StockSymbol) -> Int? {
        switch symbol.market {
        case "sh":
            if symbol.code.hasPrefix("688") || symbol.code.hasPrefix("689") { return 20 }
            if symbol.code.hasPrefix("60") { return 10 }
        case "sz":
            if symbol.code.hasPrefix("300") || symbol.code.hasPrefix("301") { return 20 }
            if symbol.code.hasPrefix("00") { return 10 }
        case "bj":
            if symbol.code.hasPrefix("4") || symbol.code.hasPrefix("8") || symbol.code.hasPrefix("92") { return 30 }
        default: break
        }
        return nil
    }
}

struct DailyCandle: Identifiable, Sendable {
    let date: String
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let volumeLots: Double
    var limitStatus: DailyPriceLimit? = nil
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
    static func parse(_ data: Data, symbol: StockSymbol, unadjustedData: Data? = nil) throws -> DailyKLineSnapshot {
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
        if let percentage = DailyPriceLimit.percentage(for: symbol) {
            if key == "day" {
                // A returned series may begin at an IPO. Omit its first five bars rather than
                // mistaking an unrestricted listing session for an ordinary daily limit.
                for index in candles.indices.dropFirst(5) where candles[index].date < sourceDay {
                    let extra = rows[index].dropFirst(6)
                    guard !extra.contains(where: { ($0 as? [String: Any]).map { !$0.isEmpty } ?? false }),
                          let previous = cents(candles[index - 1].close) else { continue }
                    // Historical ST status is not provided. In particular, do not infer the
                    // pre-2026-07-06 main-board 5% rule from today's security name.
                    let rate = symbol.market == "sz" && symbol.code.hasPrefix("30")
                        && candles[index].date < "2020-08-24" ? 10 : percentage
                    let upper = max(previous + 1, rounded(Decimal(previous) * Decimal(100 + rate) / 100))
                    let lower = max(1, min(previous - 1, rounded(Decimal(previous) * Decimal(100 - rate) / 100)))
                    candles[index].limitStatus = limitStatus(candles[index], upper: upper, lower: lower)
                }
            } else if let unadjustedData,
                      let raw = try? parse(unadjustedData, symbol: symbol), raw.adjustment == "不复权",
                      formatter.string(from: raw.timestamp) == sourceDay {
                let statuses = Dictionary(uniqueKeysWithValues: raw.candles.map { ($0.date, $0.limitStatus) })
                for index in candles.indices where candles[index].date < sourceDay {
                    candles[index].limitStatus = statuses[candles[index].date] ?? nil
                }
            }
            // qt limits describe only the quote's trading day. A stale final daily bar is
            // never paired with today's limits, and a newer quote must not label an old bar.
            if let index = candles.indices.last, candles[index].date == sourceDay, quote.count > 48,
               let latestPrice = Double(quote[3]), cents(latestPrice) == cents(candles[index].close),
               let upperPrice = Double(quote[47]), let lowerPrice = Double(quote[48]),
               let upper = cents(upperPrice), let lower = cents(lowerPrice) {
                candles[index].limitStatus = limitStatus(candles[index], upper: upper, lower: lower)
            }
        }
        // The service can append today's candle to the requested historical rows.
        return DailyKLineSnapshot(symbol: symbol, candles: Array(candles.suffix(DailyKLineClient.historyLimit)),
                                  adjustment: key == "qfqday" ? "前复权" : "不复权", timestamp: timestamp)
    }

    private static func positiveNumber(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func cents(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value < 1_000_000_000,
              let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let amount = decimal * 100
        let result = rounded(amount)
        return Decimal(result) == amount ? result : nil
    }

    private static func rounded(_ value: Decimal) -> Int {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 0, .plain)
        return NSDecimalNumber(decimal: output).intValue
    }

    private static func limitStatus(_ candle: DailyCandle, upper: Int, lower: Int) -> DailyPriceLimit? {
        guard upper > lower, lower > 0, candle.volumeLots > 0,
              let close = cents(candle.close), let high = cents(candle.high), let low = cents(candle.low),
              high <= upper, low >= lower else { return nil }
        if close == upper { return .up }
        if close == lower { return .down }
        return nil
    }
}

final class DailyKLineClient: DailyKLineFetching, Sendable {
    static let historyLimit = 1000
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
        let data = try await request(symbol, adjustment: "qfq")
        let snapshot = try DailyKLineParser.parse(data, symbol: symbol)
        guard snapshot.adjustment == "前复权", DailyPriceLimit.percentage(for: symbol) != nil else { return snapshot }
        // Limit markers are supplemental: unavailable raw history must not hide a usable chart.
        let raw: Data
        do { raw = try await request(symbol, adjustment: "") }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return snapshot
        }
        try Task.checkCancellation()
        return try DailyKLineParser.parse(data, symbol: symbol, unadjustedData: raw)
    }

    private func request(_ symbol: StockSymbol, adjustment: String) async throws -> Data {
        let url = URL(string: "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/fqkline/get?param=" + symbol.id + ",day,,,\(Self.historyLimit)," + adjustment)!
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
        return data
    }
}
