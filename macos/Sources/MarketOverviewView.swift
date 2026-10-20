import SwiftUI

struct MarketOverviewView: View {
    static let height: CGFloat = 56

    let snapshot: MarketOverviewSnapshot?
    let notice: String?
    let now: Date

    private static let rising = Color(red: 0.85, green: 0.19, blue: 0.24)
    private static let falling = Color(red: 0.06, green: 0.59, blue: 0.38)
    private static let sourceTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("上证指数").foregroundStyle(.secondary)
                Text(snapshot.map { String(format: "%.2f", $0.index.price) } ?? "—")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(indexColor)
                Text(snapshot.map { String(format: "%+.2f%%", $0.index.changePercent) } ?? "—")
                    .foregroundStyle(indexColor)
                if let warning {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                        .help(warning)
                        .accessibilityLabel("大盘数据提示：" + warning)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Text("涨" + (snapshot.map { String($0.market.advancing) } ?? "—"))
                        .foregroundStyle(Self.rising)
                    Text("跌" + (snapshot.map { String($0.market.declining) } ?? "—"))
                        .foregroundStyle(Self.falling)
                }
                .font(.system(size: 10, weight: .medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("全A成交").foregroundStyle(.secondary)
                Text(snapshot.map { Self.yi($0.market.turnoverYuan) } ?? "—")
                    .fontWeight(.medium)
                    .foregroundStyle(turnoverColor)
                Spacer(minLength: 4)
                if let comparison = snapshot?.comparison {
                    Text("较昨同刻").foregroundStyle(.secondary)
                    Text(comparisonText(comparison))
                        .foregroundStyle(turnoverColor)
                } else {
                    Text("昨同刻—").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10))
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .help(details)
    }

    private var indexColor: Color {
        guard let change = snapshot?.index.change else { return .secondary }
        return change > 0 ? Self.rising : change < 0 ? Self.falling : .primary
    }

    private var turnoverColor: Color {
        guard let change = snapshot?.comparison?.changeYuan else { return .primary }
        return change > 0 ? Self.rising : change < 0 ? Self.falling : .primary
    }

    private var warning: String? {
        var messages = [notice, snapshot?.comparisonNotice].compactMap { $0 }.filter { !$0.isEmpty }
        if let snapshot {
            let session = MarketClock.session(at: now)
            if MarketClock.isStale(timestamp: snapshot.index.timestamp, at: now, session: session) {
                messages.append("上证指数报价较旧")
            }
            if MarketClock.isStale(timestamp: snapshot.market.timestamp, at: now, session: session) {
                messages.append("全A行情报价较旧")
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var details: String {
        var lines = ["全A：同花顺沪深京A股；上证指数：腾讯行情。", "交易时段大盘每3秒刷新，刷新频率不代表行情源实时性。"]
        if let snapshot {
            lines.append("全A源时间：" + Self.sourceTime.string(from: snapshot.market.timestamp))
            lines.append("上证源时间：" + Self.sourceTime.string(from: snapshot.index.timestamp))
            lines.append("统计股票：\(snapshot.market.total)只；成交额：\(Self.yi(snapshot.market.turnoverYuan))")
            if let comparison = snapshot.comparison {
                lines.append("同花顺同刻分时采样：\(comparison.minute)；对比：\(comparison.previousDate)。分钟标签可能取整至下一分钟，时效以上述源时间为准。")
                lines.append("当前同刻：\(Self.yi(comparison.currentYuan))；昨日同刻：\(Self.yi(comparison.previousYuan))")
                if comparison.previousYuan > 0 {
                    lines.append(String(format: "成交额变化：%+.2f%%", comparison.changeYuan / comparison.previousYuan * 100))
                }
            } else {
                lines.append("昨日同刻成交额暂不可用。")
            }
        } else {
            lines.append("等待大盘行情。")
        }
        if let warning { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    private func comparisonText(_ comparison: MarketComparison) -> String {
        let change = comparison.changeYuan
        if change == 0 { return "持平" }
        return (change > 0 ? "放量" : "缩量") + Self.yi(abs(change))
    }

    private static func yi(_ yuan: Double) -> String {
        String(format: "%.2f亿", yuan / 100_000_000)
    }
}
