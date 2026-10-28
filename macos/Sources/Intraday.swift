import Foundation

protocol IntradayFetching: Sendable {
    func fetch(_ symbol: StockSymbol) async throws -> IntradaySnapshot
}

struct IntradayPoint: Identifiable, Sendable {
    let minute: Int
    let price: Double
    let cumulativeVolumeLots: Double
    let volumeLots: Double?
    var second: Int = 0
    var id: Int { minute * 60 + second }
    var sessionMinute: Int { minute <= 690 ? minute - 570 : minute - 780 + 120 }
    var timeText: String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

struct IntradaySnapshot: Sendable {
    let symbol: StockSymbol
    let date: String
    let timestamp: Date
    let previousClose: Double
    let points: [IntradayPoint]
    var isOpeningAuction: Bool = false
    var dayHigh: Double? = nil
    var dayLow: Double? = nil
}

// Keep only source-stamped quotes actually received while this process is running.
// The minute endpoint does not supply the opening-auction price history.
struct OpeningAuctionHistory {
    private var snapshots: [String: IntradaySnapshot] = [:]
    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()
    private static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
    }
    static func isActive(at date: Date) -> Bool {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let phase = MarketClock.session(at: date).phase
        return (555..<570).contains(minute) && (phase == .auction || phase == .preOpen)
    }
    func snapshot(for id: String, at now: Date) -> IntradaySnapshot? {
        guard Self.isActive(at: now), let value = snapshots[id], value.date == Self.day(now) else { return nil }
        return value
    }
    mutating func retainSymbols(_ ids: Set<String>) {
        snapshots = snapshots.filter { ids.contains($0.key) }
    }
    mutating func record(_ quote: Quote, receivedAt now: Date) {
        let day = Self.day(now)
        snapshots = snapshots.filter { $0.value.date == day }
        guard Self.isActive(at: quote.timestamp), Self.day(quote.timestamp) == day,
              quote.timestamp <= now.addingTimeInterval(5), now.timeIntervalSince(quote.timestamp) <= 15,
              quote.previousClose.isFinite, quote.previousClose > 0 else { return }
        let minute = Self.calendar.component(.hour, from: quote.timestamp) * 60
            + Self.calendar.component(.minute, from: quote.timestamp)
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        // After 09:25 the auction has matched; use the actual last trade, not the live order book.
        guard let price = minute < 565 ? (valid(quote.bidPrice) ?? valid(quote.askPrice)) : valid(quote.price) else { return }
        var points = snapshots[quote.symbol.id]?.points ?? []
        if let previous = snapshots[quote.symbol.id], quote.timestamp < previous.timestamp { return }
        let point = IntradayPoint(minute: minute, price: price, cumulativeVolumeLots: 0, volumeLots: nil,
                                  second: Self.calendar.component(.second, from: quote.timestamp))
        if points.last?.id == point.id { points[points.count - 1] = point }
        else { points.append(point) }
        snapshots[quote.symbol.id] = IntradaySnapshot(symbol: quote.symbol, date: day,
            timestamp: quote.timestamp, previousClose: quote.previousClose, points: points, isOpeningAuction: true)
    }
}

enum IntradayError: LocalizedError {
    case invalidData
    case unsupportedMarket
    case requestFailed(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidData: "没有获取到有效分时数据，请稍后刷新。"
        case .unsupportedMarket: "该市场暂不支持分时图。"
        case .requestFailed(let detail): "分时请求失败：\(detail)"
        case .httpStatus(let status): "分时服务返回异常状态（\(status)），请稍后刷新。"
        }
    }
}

enum IntradayParser {
    static func parse(_ data: Data, symbol: StockSymbol) throws -> IntradaySnapshot {
        guard ["sh", "sz", "bj"].contains(symbol.market) else { throw IntradayError.unsupportedMarket }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw IntradayError.invalidData }
        guard response.code == 0, let payload = response.data[symbol.id],
              let qt = payload.qt[symbol.id], qt.count > 30, qt[2] == symbol.code,
              positiveNumber(qt[3]) != nil, let previousClose = positiveNumber(qt[4]),
              !payload.data.data.isEmpty else { throw IntradayError.invalidData }

        let day = payload.data.date
        let time = qt[30]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.isLenient = false
        guard isDigits(day, count: 8), isDigits(time, count: 14), time.hasPrefix(day),
              let timestamp = formatter.date(from: time), formatter.string(from: timestamp) == time,
              let sourceMinute = minute(String(time.dropFirst(8).prefix(4))) else {
            throw IntradayError.invalidData
        }

        var points: [IntradayPoint] = []
        var previousSourceMinute: Int?
        var previousSourceVolume: Double?
        for row in payload.data.data {
            let fields = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 3, let minute = minute(fields[0]),
                  (570...690).contains(minute) || (780...930).contains(minute),
                  // The source publishes its 09:30 opening bucket after the 09:25 auction match.
                  // Keep its real quote timestamp and allow only this known pre-open bucket.
                  minute <= sourceMinute + 1 || (minute == 570 && (565...569).contains(sourceMinute)),
                  let price = positiveNumber(fields[1]),
                  let cumulative = Double(fields[2]), cumulative.isFinite, cumulative >= 0 else {
                throw IntradayError.invalidData
            }
            if let previousSourceMinute, minute <= previousSourceMinute { throw IntradayError.invalidData }
            if let previousSourceVolume, cumulative < previousSourceVolume { throw IntradayError.invalidData }
            previousSourceMinute = minute
            previousSourceVolume = cumulative
            // The service appends 15:01–15:30 records after its normal 15:00 close point.
            // Keep the regular-session chart without treating that known tail as a bad packet.
            if minute > 900 {
                guard points.last?.minute == 900 else { throw IntradayError.invalidData }
                continue
            }
            let volume: Double?
            if let previous = points.last {
                let adjacent = minute == previous.minute + 1 || (previous.minute == 690 && minute == 780)
                volume = adjacent ? cumulative - previous.cumulativeVolumeLots : nil
            } else {
                // The first source point includes its source-reported opening volume.
                volume = minute == 570 ? cumulative : nil
            }
            points.append(IntradayPoint(minute: minute, price: price,
                                        cumulativeVolumeLots: cumulative, volumeLots: volume))
        }
        return IntradaySnapshot(symbol: symbol, date: day, timestamp: timestamp,
                                previousClose: previousClose, points: points,
                                dayHigh: qt.count > 33 ? positiveNumber(qt[33]) : nil,
                                dayLow: qt.count > 34 ? positiveNumber(qt[34]) : nil)
    }

    private struct Response: Decodable {
        let code: Int
        let data: [String: Payload]
    }
    private struct Payload: Decodable {
        let data: Day
        let qt: [String: [String]]

        private enum Keys: String, CodingKey { case data, qt }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            data = try container.decode(Day.self, forKey: .data)
            let quotes = try container.nestedContainer(keyedBy: SymbolKey.self, forKey: .qt)
            // The payload dictionary key is the requested Tencent stock ID.
            let id = decoder.codingPath.last?.stringValue ?? ""
            let key = SymbolKey(stringValue: id)!
            qt = [id: try quotes.decode([String].self, forKey: key)]
        }
    }
    private struct SymbolKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Day: Decodable {
        let date: String
        let data: [String]
    }
    private static func isDigits(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func minute(_ text: String) -> Int? {
        guard isDigits(text, count: 4), let hour = Int(text.prefix(2)),
              let minute = Int(text.suffix(2)), hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }
    private static func positiveNumber(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }
}

final class IntradayClient: IntradayFetching, Sendable {
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

    func fetch(_ symbol: StockSymbol) async throws -> IntradaySnapshot {
        let normalized = try StockSymbol.parseList(symbol.id)
        guard normalized.count == 1, normalized[0] == symbol else { throw QuoteError.invalidSymbol(symbol.id) }
        let url = URL(string: "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=" + symbol.id)!
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
            throw IntradayError.requestFailed(error.localizedDescription)
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw IntradayError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try IntradayParser.parse(data, symbol: symbol)
    }
}
