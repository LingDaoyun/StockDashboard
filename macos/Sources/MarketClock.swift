import Foundation

enum MarketPhase: Equatable, Sendable {
    case trading, preOpen, auction, lunch, postClose, closed, calendarUnknown
}

struct MarketSession: Equatable, Sendable {
    let phase: MarketPhase
    let pollInterval: TimeInterval
    let nextChange: Date
    var calendarKnown: Bool

    var expectsFreshQuotes: Bool { phase == .trading }

    var label: String {
        switch phase {
        case .trading: "报价"
        case .preOpen: "盘前快照"
        case .auction: "竞价快照"
        case .lunch: "午休快照"
        case .postClose: "盘后快照"
        case .closed: "休市快照"
        case .calendarUnknown: "日历待更新"
        }
    }
}

enum MarketClock {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()

    // 上交所2026年休市安排；调休周末也休市。
    // https://www.sse.com.cn/disclosure/announcement/general/c/c_20251222_10802507.shtml
    private static let holidays2026 = [
        101...103, 215...223, 404...406, 501...505,
        619...621, 925...927, 1001...1007
    ]

    private static let periods: [(until: TimeInterval, phase: MarketPhase, interval: TimeInterval)] = [
        (9 * 3600 + 14 * 60, .closed, 60),
        (9 * 3600 + 15 * 60, .preOpen, 1),
        (9 * 3600 + 25 * 60, .auction, 1),
        (9 * 3600 + 30 * 60, .preOpen, 1),
        (11 * 3600 + 30 * 60, .trading, 1),
        (11 * 3600 + 31 * 60, .lunch, 1),
        (12 * 3600 + 59 * 60, .lunch, 30),
        (13 * 3600, .preOpen, 1),
        (14 * 3600 + 57 * 60, .trading, 1),
        (15 * 3600, .auction, 1),
        (15 * 3600 + 31 * 60, .postClose, 1),
        (24 * 3600, .closed, 60)
    ]

    static func session(at date: Date) -> MarketSession {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let start = calendar.startOfDay(for: date)
        let nextDay = start.addingTimeInterval(86400)
        let known = components.year == 2026
        let weekend = components.weekday == 1 || components.weekday == 7
        let monthDay = components.month! * 100 + components.day!
        if weekend || (known && holidays2026.contains(where: { $0.contains(monthDay) })) {
            return MarketSession(phase: .closed, pollInterval: 60, nextChange: nextDay, calendarKnown: known)
        }
        guard known else {
            // 未确认年度休市表前，工作日保留1秒轮询，避免错过行情。
            return MarketSession(phase: .calendarUnknown, pollInterval: 1, nextChange: nextDay, calendarKnown: false)
        }
        let elapsed = date.timeIntervalSince(start)
        let period = periods.first { elapsed < $0.until }!
        return MarketSession(phase: period.phase, pollInterval: period.interval,
                             nextChange: start.addingTimeInterval(period.until), calendarKnown: true)
    }

    static func ageText(since timestamp: Date, at now: Date) -> String {
        let age = now.timeIntervalSince(timestamp)
        guard age.isFinite, age >= 1 else { return "刚刚" }
        let count: Double
        let unit: String
        if age < 60 {
            count = floor(age)
            unit = "秒前"
        } else if age < 3600 {
            count = floor(age / 60)
            unit = "分钟前"
        } else if age < 86400 {
            count = floor(age / 3600)
            unit = "小时前"
        } else {
            count = floor(age / 86400)
            unit = "天前"
        }
        // 保留Double格式化，避免极大有限时长转换Int时溢出。
        return String(format: "%.0f", count) + unit
    }

    static func isStale(timestamp: Date, at now: Date, session: MarketSession) -> Bool {
        session.expectsFreshQuotes && now.timeIntervalSince(timestamp) > 15
    }
}
