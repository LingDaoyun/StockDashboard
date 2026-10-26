import SwiftUI

struct IntradayChartView: View {
    static let height: CGFloat = 220

    let snapshot: IntradaySnapshot?
    let error: String?
    let isRefreshing: Bool
    let now: Date

    @State private var inspectedMinute: Int?

    private static let rising = Color(red: 0.85, green: 0.19, blue: 0.24)
    private static let falling = Color(red: 0.06, green: 0.59, blue: 0.38)
    private static let line = Color(red: 0.12, green: 0.48, blue: 0.95)
    private static let sourceTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text("分时").fontWeight(.medium)
                if let warning {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                        .help(warning)
                        .accessibilityLabel("分时数据提示：" + warning)
                }
                Spacer(minLength: 3)
                if let point = inspectedPoint {
                    Text(point.timeText).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", point.price)).foregroundStyle(Self.line)
                    Text("量 " + Self.volumeText(point.volumeLots)).foregroundStyle(.secondary)
                } else {
                    Text("价格 / 分钟量").foregroundStyle(.secondary)
                }
                if isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("正在更新分时")
                }
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: 14)

            if let snapshot, !snapshot.points.isEmpty {
                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(snapshot, in: size, context: context)
                    }
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let plot = priceRect(in: geometry.size)
                                    guard location.x >= plot.minX, location.x <= plot.maxX else {
                                        inspectedMinute = nil
                                        return
                                    }
                                    let minute = Double((location.x - plot.minX) / plot.width) * 240
                                    inspectedMinute = snapshot.points.min {
                                        abs(Double($0.sessionMinute) - minute) < abs(Double($1.sessionMinute) - minute)
                                    }?.minute
                                case .ended:
                                    inspectedMinute = nil
                                }
                            }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("价格走势与分钟成交量")
                .accessibilityValue(accessibilitySummary(snapshot))
            } else {
                VStack(spacing: 5) {
                    Text(error == nil ? (isRefreshing ? "正在加载分时…" : "尚无分时数据") : "分时暂不可用")
                        .foregroundStyle(.secondary)
                    if let error, !error.isEmpty {
                        Text(error).lineLimit(2).foregroundStyle(.orange)
                        Text("将自动重试").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, 5)
        .frame(height: Self.height)
        .help(details)
    }

    private var inspectedPoint: IntradayPoint? {
        guard let inspectedMinute else { return nil }
        return snapshot?.points.first { $0.minute == inspectedMinute }
    }

    private var warning: String? {
        var messages = [error].compactMap { $0 }.filter { !$0.isEmpty }
        if let snapshot {
            if MarketClock.isStale(timestamp: snapshot.timestamp, at: now, session: MarketClock.session(at: now)) {
                messages.append("行情源时间较旧，保留最近可用分时并自动更新")
            }
            if snapshot.date < Self.day.string(from: now) {
                messages.append("显示最近可用交易日 \(snapshot.date) 的分时")
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var details: String {
        var lines = [
            "腾讯分时行情；上方蓝线为价格，下方为分钟成交量（手），虚线为昨收。",
            "显示09:30至15:00的正常时段；收盘后仍可查看当天曲线，接口附加的15:00后尾段不计入图中。",
            "量柱红绿仅表示该点价格较前一点上涨或下跌，首点与昨收比较；不代表主动买卖量。午休不占横轴时长。",
            "缺失分钟量不画零量柱；价格缺点处断开。分钟标签可能取区间末端或下一分钟，最后一个桶仍可能更新，不代表该分钟已结束。",
            "09:30首点保留接口量，集合竞价的细分口径尚未核验。"
        ]
        if let snapshot {
            lines.append("分时交易日：\(snapshot.date)；真实行情源时间：" + Self.sourceTime.string(from: snapshot.timestamp))
            lines.append("刷新频率与分钟标签均不代表行情源实时性；更新失败时保留最近可用数据。")
        }
        if let warning { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    private func priceRect(in size: CGSize) -> CGRect {
        CGRect(x: 2, y: 5, width: max(1, size.width - 43), height: max(1, size.height - 70))
    }

    private func draw(_ snapshot: IntradaySnapshot, in size: CGSize, context: GraphicsContext) {
        let plot = priceRect(in: size)
        let volume = CGRect(x: plot.minX, y: plot.maxY + 12, width: plot.width, height: 35)
        let prices = snapshot.points.map(\.price) + [snapshot.previousClose]
        let minimum = prices.min() ?? snapshot.previousClose
        let maximum = prices.max() ?? snapshot.previousClose
        let padding = max((maximum - minimum) * 0.12, max(snapshot.previousClose * 0.001, 0.02))
        let low = max(0, minimum - padding)
        let high = maximum + padding
        let span = max(high - low, 0.01)
        guard span.isFinite else { return }
        let maximumVolume = max(snapshot.points.compactMap(\.volumeLots).max() ?? 0, 1)
        let x: (Int) -> CGFloat = { plot.minX + CGFloat($0) / 240 * plot.width }
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - low) / span) * plot.height }

        // Both plots use the same compressed trading-minute axis.
        for minute in [0, 60, 120, 180, 240] {
            let grid = Path { path in
                path.move(to: CGPoint(x: x(minute), y: plot.minY))
                path.addLine(to: CGPoint(x: x(minute), y: volume.maxY))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)
        }
        for value in [high, low] {
            let grid = Path { path in
                path.move(to: CGPoint(x: plot.minX, y: y(value)))
                path.addLine(to: CGPoint(x: plot.maxX, y: y(value)))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
            label(String(format: "%.2f", value), at: CGPoint(x: size.width, y: y(value)), context: context)
        }
        let previousCloseY = y(snapshot.previousClose)
        let reference = Path { path in
            path.move(to: CGPoint(x: plot.minX, y: previousCloseY))
            path.addLine(to: CGPoint(x: plot.maxX, y: previousCloseY))
        }
        context.stroke(reference, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        if abs(previousCloseY - plot.minY) > 12 && abs(previousCloseY - plot.maxY) > 12 {
            label(String(format: "%.2f", snapshot.previousClose), at: CGPoint(x: size.width, y: previousCloseY), context: context)
        }

        var path = Path()
        var previous: IntradayPoint?
        for point in snapshot.points {
            let position = CGPoint(x: x(point.sessionMinute), y: y(point.price))
            if let previous, point.minute == previous.minute + 1 || (previous.minute == 690 && point.minute == 780) {
                path.addLine(to: position)
            } else {
                path.move(to: position)
            }
            let dot = CGRect(x: position.x - 0.9, y: position.y - 0.9, width: 1.8, height: 1.8)
            context.fill(Path(ellipseIn: dot), with: .color(Self.line))
            if let lots = point.volumeLots, lots > 0 {
                let height = max(0.7, CGFloat(lots / maximumVolume) * volume.height)
                let width = max(0.8, min(3, plot.width / 240 * 0.82))
                let bar = CGRect(x: position.x - width / 2, y: volume.maxY - height, width: width, height: height)
                let referencePrice = previous?.price ?? snapshot.previousClose
                let color = point.price > referencePrice ? Self.rising : point.price < referencePrice ? Self.falling : Color.secondary
                context.fill(Path(bar), with: .color(color.opacity(0.85)))
            }
            previous = point
        }
        context.stroke(path, with: .color(Self.line), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))

        let baseline = Path { path in
            path.move(to: CGPoint(x: volume.minX, y: volume.maxY))
            path.addLine(to: CGPoint(x: volume.maxX, y: volume.maxY))
        }
        context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
        label(Self.volumeText(maximumVolume), at: CGPoint(x: size.width, y: volume.minY + 3), context: context)
        label("0", at: CGPoint(x: size.width, y: volume.maxY), context: context)

        let axis: [(Int, String, UnitPoint)] = [
            (0, "09:30", .leading), (60, "10:30", .center),
            (120, "11:30/13:00", .center), (180, "14:00", .center), (240, "15:00", .trailing)
        ]
        for (minute, text, anchor) in axis {
            label(text, at: CGPoint(x: x(minute), y: size.height - 4), anchor: anchor, context: context)
        }

        if let selected = inspectedPoint {
            let selectedX = x(selected.sessionMinute)
            let cursor = Path { path in
                path.move(to: CGPoint(x: selectedX, y: plot.minY))
                path.addLine(to: CGPoint(x: selectedX, y: volume.maxY))
            }
            context.stroke(cursor, with: .color(Self.line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
            let dot = CGRect(x: selectedX - 2.5, y: y(selected.price) - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(Self.line))
        }
    }

    private func label(_ text: String, at position: CGPoint, anchor: UnitPoint = .trailing, context: GraphicsContext) {
        context.draw(Text(text).font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                     at: position, anchor: anchor)
    }

    private static func volumeText(_ lots: Double?) -> String {
        guard let lots else { return "—" }
        return lots >= 10_000 ? String(format: "%.1f万手", lots / 10_000) : String(format: "%.0f手", lots)
    }

    private func accessibilitySummary(_ snapshot: IntradaySnapshot) -> String {
        guard let latest = snapshot.points.last else { return "尚无分时数据" }
        return "\(latest.timeText)，价格\(String(format: "%.2f", latest.price))，分钟成交量\(Self.volumeText(latest.volumeLots))。\(warning ?? "")"
    }
}
