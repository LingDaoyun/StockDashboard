import Foundation
import CoreFoundation

protocol MarketOverviewFetching: Sendable {
    func fetch() async throws -> MarketOverviewSnapshot
}

struct MarketOverviewSnapshot: Sendable {
    let index: Quote
    let market: AllAMarketQuote
    let comparison: MarketComparison?
    let comparisonNotice: String?
}

struct AllAMarketQuote: Sendable {
    let timestamp: Date
    let advancing: Int
    let declining: Int
    let total: Int
    let turnoverYuan: Double
    let breadthTimestamp: Date
    let turnoverTimestamp: Date
    var latestTimestamp: Date { max(breadthTimestamp, turnoverTimestamp) }

    init(timestamp: Date, advancing: Int, declining: Int, total: Int, turnoverYuan: Double,
         breadthTimestamp: Date? = nil, turnoverTimestamp: Date? = nil) {
        self.timestamp = timestamp
        self.advancing = advancing
        self.declining = declining
        self.total = total
        self.turnoverYuan = turnoverYuan
        self.breadthTimestamp = breadthTimestamp ?? timestamp
        self.turnoverTimestamp = turnoverTimestamp ?? timestamp
    }
}

struct MarketComparison: Sendable {
    let minute: String
    let previousDate: String
    let currentYuan: Double
    let previousYuan: Double
    var changeYuan: Double { currentYuan - previousYuan }
}

enum MarketOverviewError: LocalizedError {
    case invalidResponse(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse(let source): "大盘\(source)数据无效，请稍后刷新。"
        }
    }
}

enum MarketOverviewParser {
    private static let callback = "quotebridge_v6_realhead_bk_883957_last"

    static func parse(index: Data, breadth: Data, turnover: Data) throws -> MarketOverviewSnapshot {
        let symbol = StockSymbol(code: "000001", market: "sh")
        guard let indexQuote = try QuoteParser.parse(index, symbols: [symbol])[symbol.id] else {
            throw MarketOverviewError.invalidResponse("上证指数")
        }
        let items = try breadthItems(breadth)
        guard items["5"] as? String == "883957", items["name"] as? String == "同花顺全A(沪深京)",
              let up = integer(items["38"]), let down = integer(items["39"]),
              let total = integer(items["37"]), total > 0, up <= total, down <= total - up,
              let sourceTime = items["time"] as? String, sourceTime.hasSuffix(" 北京时间"),
              let breadthTime = date(String(sourceTime.dropLast(" 北京时间".count))) else {
            throw MarketOverviewError.invalidResponse("涨跌家数")
        }
        guard let root = try JSONSerialization.jsonObject(with: turnover) as? [String: Any],
              integer(root["status_code"]) == 0,
              let data = root["data"] as? [String: Any],
              let chart = data["charts"] as? [String: Any],
              let timeText = chart["mtime"] as? String, let amountTime = date(timeText),
              sameDay(breadthTime, amountTime),
              let header = chart["header"] as? [[String: Any]],
              let amount = headerNumber("turnover", in: header), amount >= 0 else {
            throw MarketOverviewError.invalidResponse("成交额")
        }
        let comparison = comparison(chart, header: header, amount: amount, sourceTime: amountTime)
        let market = AllAMarketQuote(timestamp: min(breadthTime, amountTime), advancing: up,
                                    declining: down, total: total, turnoverYuan: amount,
                                    breadthTimestamp: breadthTime, turnoverTimestamp: amountTime)
        return MarketOverviewSnapshot(index: indexQuote, market: market, comparison: comparison,
                                      comparisonNotice: comparison == nil ? "昨日同刻成交额暂不可用" : nil)
    }

    private static func breadthItems(_ data: Data) throws -> [String: Any] {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MarketOverviewError.invalidResponse("涨跌家数")
        }
        if text.hasSuffix(";") { text.removeLast(); text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let prefix = callback + "("
        guard text.hasPrefix(prefix), text.hasSuffix(")") else {
            throw MarketOverviewError.invalidResponse("涨跌家数")
        }
        let json = String(text.dropFirst(prefix.count).dropLast())
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let items = root["items"] as? [String: Any] else {
            throw MarketOverviewError.invalidResponse("涨跌家数")
        }
        return items
    }

    private static func comparison(_ chart: [String: Any], header: [[String: Any]],
                                   amount: Double, sourceTime: Date) -> MarketComparison? {
        guard let delta = headerNumber("turnover_change", in: header),
              let keys = chart["point_key_list"] as? [String], Set(keys).count == keys.count,
              let timeColumn = keys.firstIndex(of: "timestamp"),
              let currentColumn = keys.firstIndex(of: "turnover"),
              let priorColumn = keys.firstIndex(of: "turnover_pre"),
              let deltaColumn = keys.firstIndex(of: "turnover_change"),
              let points = chart["point_list"] as? [[Any]] else { return nil }
        var latest: (time: Date, current: Double, prior: Double, delta: Double)?
        let neededColumn = max(timeColumn, currentColumn, priorColumn, deltaColumn)
        for point in points {
            guard point.count > neededColumn, let milliseconds = number(point[timeColumn]),
                  milliseconds >= 0, milliseconds < 253_402_300_800_000,
                  let current = number(point[currentColumn]), current >= 0 else { continue }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
            guard sameDay(timestamp, sourceTime) else { continue }
            // A point label is the interval's minute end; source mtime determines freshness.
            if latest == nil || timestamp > latest!.time {
                latest = (timestamp, current, number(point[priorColumn]) ?? .nan,
                          number(point[deltaColumn]) ?? .nan)
            }
        }
        guard let latest, latest.prior.isFinite, latest.prior > 0, latest.delta.isFinite,
              close(latest.current, amount), close(latest.delta, delta),
              (amount - delta).isFinite, amount - delta > 0,
              close(latest.current - latest.prior, delta), close(amount - delta, latest.prior) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return MarketComparison(minute: formatter.string(from: latest.time), previousDate: "上一交易日",
                                currentYuan: amount, previousYuan: amount - delta)
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= 0.02
    }

    private static func headerNumber(_ key: String, in header: [[String: Any]]) -> Double? {
        let matches = header.filter { $0["key"] as? String == key }
        guard matches.count == 1 else { return nil }
        return number(matches[0]["val"])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value >= 0 else { return nil }
        return Int(exactly: value)
    }

    private static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            parsed = value.doubleValue
        } else if let value = value as? String, !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) {
            parsed = Double(value)
        } else { return nil }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func date(_ text: String) -> Date? {
        guard text.utf8.count == 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private static func sameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

final class MarketOverviewClient: MarketOverviewFetching, Sendable {
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

    func fetch() async throws -> MarketOverviewSnapshot {
        async let index = load("https://qt.gtimg.cn/q=sh000001")
        async let breadth = load("https://d.10jqka.com.cn/v6/realhead/bk_883957/last.js")
        async let turnover = load("https://dq.10jqka.com.cn/fuyao/market_analysis_api/chart/v1/get_chart_data?chart_key=turnover_minute")
        return try await MarketOverviewParser.parse(index: index, breadth: breadth, turnover: turnover)
    }

    private func load(_ address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        if request.url?.host?.hasSuffix("10jqka.com.cn") == true {
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.10jqka.com.cn/", forHTTPHeaderField: "Referer")
        }
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
        try Task.checkCancellation()
        return data
    }
}
