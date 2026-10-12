import Foundation

@main
@MainActor
enum MarketClockTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 12,
                     _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    static func session(_ at: Date, phase: MarketPhase, interval: TimeInterval,
                        next: Date, known: Bool = true, label: String) {
        let result = MarketClock.session(at: at)
        check(result.phase == phase, "时段应为 \(phase)：\(at)")
        check(result.pollInterval == interval, "轮询间隔应为 \(interval) 秒：\(at)")
        check(result.nextChange == next, "下一变化应精确到边界：\(at)")
        check(result.nextChange > at, "下一变化必须严格晚于当前时间：\(at)")
        check(result.calendarKnown == known, "应准确标记该年的休市日历是否已确认")
        check(result.expectsFreshQuotes == (phase == .trading), "只有连续交易时段才要求新报价")
        check(result.label == label, "时段应显示简短且准确的报价状态")
    }

    static func main() {
        timezoneTests()
        boundaryTests()
        holidayTests()
        unknownCalendarTests()
        freshnessTests()
        ageTextTests()
        print("PASS: \(checks) market-clock assertions")
    }

    static func timezoneTests() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let utc = ISO8601DateFormatter().date(from: "2026-10-12T01:30:00Z")!
        let next = ISO8601DateFormatter().date(from: "2026-10-12T03:30:00Z")!
        for zone in ["UTC", "America/Los_Angeles", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            session(utc, phase: .trading, interval: 1, next: next, label: "报价")
            session(utc.addingTimeInterval(-960), phase: .preOpen, interval: 1,
                    next: utc, label: "盘前快照")
        }
    }

    static func boundaryTests() {
        let dayStart = date()
        let spans: [(start: Int, end: Int, phase: MarketPhase, interval: TimeInterval, label: String)] = [
            (0, 9 * 3600 + 14 * 60, .closed, 60, "休市快照"),
            (9 * 3600 + 14 * 60, 9 * 3600 + 30 * 60, .preOpen, 1, "盘前快照"),
            (9 * 3600 + 30 * 60, 11 * 3600 + 30 * 60, .trading, 1, "报价"),
            (11 * 3600 + 30 * 60, 11 * 3600 + 31 * 60, .lunch, 1, "午休快照"),
            (11 * 3600 + 31 * 60, 12 * 3600 + 59 * 60, .lunch, 30, "午休快照"),
            (12 * 3600 + 59 * 60, 13 * 3600, .preOpen, 1, "盘前快照"),
            (13 * 3600, 14 * 3600 + 57 * 60, .trading, 1, "报价"),
            (14 * 3600 + 57 * 60, 15 * 3600, .auction, 1, "竞价快照"),
            (15 * 3600, 15 * 3600 + 31 * 60, .postClose, 1, "盘后快照"),
            (15 * 3600 + 31 * 60, 24 * 3600, .closed, 60, "休市快照")
        ]
        for span in spans {
            let next = dayStart.addingTimeInterval(TimeInterval(span.end))
            for offset in [TimeInterval(span.start), TimeInterval(span.start) + 0.25,
                           TimeInterval(span.end) - 1, TimeInterval(span.end) - 0.25] {
                session(dayStart.addingTimeInterval(offset), phase: span.phase,
                        interval: span.interval, next: next, label: span.label)
            }
        }
        session(date(2026, 10, 13), phase: .closed, interval: 60,
                next: date(2026, 10, 13, 9, 14), label: "休市快照")
        session(date(2026, 12, 31, 23, 59, 59).addingTimeInterval(0.75), phase: .closed,
                interval: 60, next: date(2027, 1, 1), label: "休市快照")
    }

    static func holidayTests() {
        let holidays: [(month: Int, days: ClosedRange<Int>)] = [
            (1, 1...3), (2, 15...23), (4, 4...6), (5, 1...5),
            (6, 19...21), (9, 25...27), (10, 1...7)
        ]
        for holiday in holidays {
            for day in holiday.days {
                for hour in [9, 13, 15] {
                    let start = date(2026, holiday.month, day)
                    session(date(2026, holiday.month, day, hour, 30), phase: .closed,
                            interval: 60, next: start.addingTimeInterval(86400), label: "休市快照")
                }
            }
        }
        // 调休上班的周末仍不交易，同时覆盖普通周六和周日。
        for (month, day) in [(1, 4), (2, 14), (2, 28), (5, 9), (9, 20), (10, 10), (10, 17), (10, 18)] {
            session(date(2026, month, day, 10), phase: .closed, interval: 60,
                    next: date(2026, month, day).addingTimeInterval(86400), label: "休市快照")
        }
        for (month, day) in [(1, 5), (2, 13), (2, 24), (4, 3), (4, 7), (4, 30),
                             (5, 6), (6, 18), (6, 22), (9, 24), (9, 28), (9, 30), (10, 8)] {
            session(date(2026, month, day, 10), phase: .trading, interval: 1,
                    next: date(2026, month, day, 11, 30), label: "报价")
        }
        session(date(2026, 10, 7, 23, 59, 59).addingTimeInterval(0.75), phase: .closed,
                interval: 60, next: date(2026, 10, 8), label: "休市快照")
    }

    static func unknownCalendarTests() {
        for (year, month, day) in [(2025, 10, 13), (2027, 1, 1), (2027, 1, 4), (2027, 2, 8)] {
            for hour in [0, 9, 10, 12, 14, 16, 23] {
                session(date(year, month, day, hour, 30), phase: .calendarUnknown, interval: 1,
                        next: date(year, month, day).addingTimeInterval(86400), known: false,
                        label: "日历待更新")
            }
        }
        for (year, month, day) in [(2025, 10, 11), (2025, 10, 12), (2027, 1, 2), (2027, 1, 3)] {
            session(date(year, month, day, 10), phase: .closed, interval: 60,
                    next: date(year, month, day).addingTimeInterval(86400), known: false,
                    label: "休市快照")
        }
    }

    static func freshnessTests() {
        let now = date(2026, 10, 12, 10)
        let trading = MarketClock.session(at: now)
        for age in [-1.0, 0, 14, 14.999, 15] {
            check(!MarketClock.isStale(timestamp: now.addingTimeInterval(-age), at: now, session: trading),
                  "新鲜或未来时间的报价不应警报：\(age)")
        }
        for age: TimeInterval in [15.001, 16, 86400, 259200] {
            check(MarketClock.isStale(timestamp: now.addingTimeInterval(-age), at: now, session: trading),
                  "盘中超过15秒及旧交易日报价应提示过旧：\(age)")
        }
        for at in [date(2026, 10, 12, 9, 14), date(2026, 10, 12, 11, 30),
                   date(2026, 10, 12, 11, 31), date(2026, 10, 12, 12, 59),
                   date(2026, 10, 12, 14, 57), date(2026, 10, 12, 15),
                   date(2026, 10, 12, 15, 31), date(2026, 10, 10, 10), date(2027, 1, 4, 10)] {
            check(!MarketClock.isStale(timestamp: at.addingTimeInterval(-3 * 86400), at: at,
                                       session: MarketClock.session(at: at)),
                  "快照和日历未知时段不应因旧交易日报价警报")
        }
    }

    static func ageTextTests() {
        let now = date(2026, 10, 12, 10)
        let examples: [(TimeInterval, String)] = [
            (-1, "刚刚"), (0, "刚刚"), (0.999, "刚刚"),
            (1, "1秒前"), (1.999, "1秒前"), (59, "59秒前"), (59.999, "59秒前"),
            (60, "1分钟前"), (60.999, "1分钟前"), (119.999, "1分钟前"), (3599.999, "59分钟前"),
            (3600, "1小时前"), (3600.999, "1小时前"), (7199.999, "1小时前"), (86399.999, "23小时前"),
            (86400, "1天前"), (86400.999, "1天前"), (172799.999, "1天前"), (172800, "2天前")
        ]
        for (age, text) in examples {
            check(MarketClock.ageText(since: now.addingTimeInterval(-age), at: now) == text,
                  "报价时长应向下取整：\(age) → \(text)")
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            check(MarketClock.ageText(since: Date(timeIntervalSinceReferenceDate: invalid), at: now) == "刚刚",
                  "无效时间不能因数字转换崩溃")
            check(MarketClock.ageText(since: now, at: Date(timeIntervalSinceReferenceDate: invalid)) == "刚刚",
                  "无效当前时间不能因数字转换崩溃")
        }
        let huge = MarketClock.ageText(since: Date(timeIntervalSinceReferenceDate: 0),
                                      at: Date(timeIntervalSinceReferenceDate: 1e300))
        check(huge.hasSuffix("天前") && !huge.contains("inf"), "极大有限时长不能因整数溢出崩溃")
        check(MarketClock.ageText(since: now.addingTimeInterval(-10 * 86400), at: now) == "10天前",
              "多日陈旧数据应显示距源时间的天数")
    }
}
