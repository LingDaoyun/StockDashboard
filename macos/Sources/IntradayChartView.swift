import SwiftUI

struct IntradayChartView: View {
    static let height: CGFloat = 220

    let snapshot: IntradaySnapshot?
    let error: String?
    let isRefreshing: Bool
    let now: Date
    var isOpeningAuction: Bool = false
    var chartHeight: CGFloat = Self.height
    var onExpand: (() -> Void)? = nil

    @State private var inspectedID: Int?

    private static let rising = Color(red: 0.85, green: 0.19, blue: 0.24)
    private static let falling = Color(red: 0.06, green: 0.59, blue: 0.38)
    private static let line = Color(red: 0.12, green: 0.48, blue: 0.95)
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private var showsAuction: Bool { snapshot?.isOpeningAuction ?? isOpeningAuction }
    private var isLargeChart: Bool { chartHeight > Self.height }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text(showsAuction ? "竞价" : "分时").fontWeight(.medium)
                if let warning {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                        .help(warning)
                        .accessibilityLabel("分时数据提示：" + warning)
                }
                Spacer(minLength: 3)
                if let point = headerPoint {
                    Text(timeText(point)).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", point.price)).foregroundStyle(Self.line)
                    if showsAuction {
                        Text(point.minute < 565 ? "参考价" : "成交价").foregroundStyle(.secondary)
                    } else {
                        let change = snapshot?.changeFromOpenPercent(at: point)
                        Text("较开盘 " + Self.percentText(change))
                            .foregroundStyle((change ?? 0) > 0 ? Self.rising : (change ?? 0) < 0 ? Self.falling : Color.secondary)
                    }
                } else {
                    Text(showsAuction ? "等待竞价报价" : "价格 / 分钟量").foregroundStyle(.secondary)
                }
                if isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("正在更新分时")
                }
            }
            .font(.system(size: isLargeChart ? 13 : 10))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: isLargeChart ? 20 : 14)

            if !showsAuction, let point = headerPoint {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("最高 " + Self.priceText(snapshot?.dayHigh))
                    Text("最低 " + Self.priceText(snapshot?.dayLow))
                    Text("量 " + Self.volumeText(point.volumeLots))
                }
                .font(.system(size: isLargeChart ? 13 : 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: isLargeChart ? 18 : 12)
            }

            if let snapshot, !snapshot.points.isEmpty {
                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(snapshot, in: size, context: context)
                    }
                    .overlay {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { onExpand?() }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let plot = priceRect(in: geometry.size)
                                    guard location.x >= plot.minX, location.x <= plot.maxX else {
                                        inspectedID = nil
                                        return
                                    }
                                    let minute = Double((location.x - plot.minX) / plot.width) * (snapshot.isOpeningAuction ? 15 : 240)
                                    inspectedID = snapshot.points.min {
                                        abs(chartMinute($0, snapshot: snapshot) - minute) < abs(chartMinute($1, snapshot: snapshot) - minute)
                                    }?.id
                                case .ended:
                                    inspectedID = nil
                                }
                            }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(snapshot.isOpeningAuction ? "集合竞价价格走势" : "价格走势与分钟成交量")
                .accessibilityValue(accessibilitySummary(snapshot))
                .accessibilityActions {
                    if let onExpand { Button("放大图表", action: onExpand) }
                }
            } else {
                VStack(spacing: 5) {
                    Text(showsAuction ? "等待当日竞价报价…" : (error == nil ? (isRefreshing ? "正在加载分时…" : "尚无分时数据") : "分时暂不可用"))
                        .foregroundStyle(.secondary)
                    if let error, !error.isEmpty {
                        Text(error).lineLimit(2).foregroundStyle(.orange)
                        Text("将自动重试").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: isLargeChart ? 13 : 10))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.vertical, 5)
        .frame(height: chartHeight)
        .help(details)
    }

    private var inspectedPoint: IntradayPoint? {
        guard let inspectedID else { return nil }
        return snapshot?.points.first { $0.id == inspectedID }
    }

    private var headerPoint: IntradayPoint? {
        inspectedPoint ?? snapshot?.points.last
    }

    private func timeText(_ point: IntradayPoint) -> String {
        showsAuction
            ? String(format: "%02d:%02d:%02d", point.minute / 60, point.minute % 60, point.second)
            : point.timeText
    }

    private func chartMinute(_ point: IntradayPoint, snapshot: IntradaySnapshot) -> Double {
        snapshot.isOpeningAuction ? Double(point.minute - 555) + Double(point.second) / 60 : Double(point.sessionMinute)
    }

    private var warning: String? {
        var messages = [error].compactMap { $0 }.filter { !$0.isEmpty }
        if let snapshot {
            if MarketClock.isStale(timestamp: snapshot.timestamp, at: now, session: MarketClock.session(at: now))
                || (snapshot.isOpeningAuction && now.timeIntervalSince(snapshot.timestamp) > 15) {
                messages.append("行情源时间较旧，保留最近可用分时并自动更新")
            }
            if snapshot.date < Self.day.string(from: now) {
                messages.append("显示最近可用交易日 \(snapshot.date) 的分时")
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var details: String {
        guard let snapshot, let point = headerPoint else {
            return showsAuction ? "等待当日竞价报价" : "尚无分时数据"
        }
        let date = "\(snapshot.date.prefix(4))-\(snapshot.date.dropFirst(4).prefix(2))-\(snapshot.date.suffix(2))"
        var lines = ["时间：\(date) \(timeText(point))"]
        if showsAuction {
            let label = point.minute < 565 ? "参考价" : "成交价"
            lines.append("\(label)：\(Self.priceText(point.price))")
        } else {
            lines.append("价格：\(Self.priceText(point.price))")
            lines.append("当日最高：\(Self.priceText(snapshot.dayHigh))　最低：\(Self.priceText(snapshot.dayLow))")
            lines.append("分钟量：\(Self.volumeText(point.volumeLots))")
        }
        return lines.joined(separator: "\n")
    }

    private func priceRect(in size: CGSize) -> CGRect {
        CGRect(x: 2, y: isLargeChart ? 8 : 5,
               width: max(1, size.width - (isLargeChart ? 80 : 43)),
               height: max(1, size.height - (isLargeChart ? 115 : 70)))
    }

    private func draw(_ snapshot: IntradaySnapshot, in size: CGSize, context: GraphicsContext) {
        let plot = priceRect(in: size)
        let volume = CGRect(x: plot.minX, y: plot.maxY + (isLargeChart ? 16 : 12),
                            width: plot.width, height: isLargeChart ? 65 : 35)
        let prices = snapshot.points.map(\.price) + [snapshot.previousClose]
        let minimum = prices.min() ?? snapshot.previousClose
        let maximum = prices.max() ?? snapshot.previousClose
        let padding = max((maximum - minimum) * 0.12, max(snapshot.previousClose * 0.001, 0.02))
        let low = max(0, minimum - padding)
        let high = maximum + padding
        let span = max(high - low, 0.01)
        guard span.isFinite else { return }
        let maximumVolume = max(snapshot.points.compactMap(\.volumeLots).max() ?? 0, 1)
        let axisLength: Double = snapshot.isOpeningAuction ? 15 : 240
        let x: (Double) -> CGFloat = { plot.minX + CGFloat($0 / axisLength) * plot.width }
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - low) / span) * plot.height }

        // Auction samples use source seconds; regular plots share compressed trading minutes.
        let gridMinutes: [Double] = snapshot.isOpeningAuction ? [0, 5, 10, 15] : [0, 60, 120, 180, 240]
        for minute in gridMinutes {
            let grid = Path { path in
                path.move(to: CGPoint(x: x(minute), y: plot.minY))
                path.addLine(to: CGPoint(x: x(minute), y: volume.maxY))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.32)), lineWidth: 0.75)
        }
        let gridLevels = snapshot.percentGridLevels(low: low, high: high)
        let labelsFit = abs(y(snapshot.previousClose * 1.02) - y(snapshot.previousClose)) >= (isLargeChart ? 16 : 11)
        let labeledLevels = gridLevels.filter { labelsFit || $0.percent == 0 }
        for value in [high, low] {
            let grid = Path { path in
                path.move(to: CGPoint(x: plot.minX, y: y(value)))
                path.addLine(to: CGPoint(x: plot.maxX, y: y(value)))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.32)), lineWidth: 0.75)
            if labeledLevels.allSatisfy({ abs(y($0.price) - y(value)) >= (isLargeChart ? 16 : 11) }) {
                label(String(format: "%.2f", value), at: CGPoint(x: size.width, y: y(value)), context: context)
            }
        }
        for level in gridLevels {
            let levelY = y(level.price)
            let color: Color = level.percent > 0 ? Self.rising : level.percent < 0 ? Self.falling : .secondary
            let grid = Path { path in
                path.move(to: CGPoint(x: plot.minX, y: levelY))
                path.addLine(to: CGPoint(x: plot.maxX, y: levelY))
            }
            context.stroke(grid, with: .color(color.opacity(level.percent == 0 ? 0.65 : 0.4)),
                           style: StrokeStyle(lineWidth: level.percent == 0 ? 1 : 0.8, dash: [4, 3]))
            if labelsFit || level.percent == 0 {
                let text = level.percent == 0 ? "0% 昨收" : String(format: "%+.0f%%", level.percent)
                label(text, at: CGPoint(x: size.width, y: levelY), color: color, context: context)
            }
        }

        var path = Path()
        var previous: IntradayPoint?
        for point in snapshot.points {
            let position = CGPoint(x: x(chartMinute(point, snapshot: snapshot)), y: y(point.price))
            let connects: Bool
            if let previous {
                if snapshot.isOpeningAuction {
                    let seconds = (point.minute - previous.minute) * 60 + point.second - previous.second
                    connects = seconds > 0 && seconds <= 15
                } else {
                    connects = point.minute == previous.minute + 1 || (previous.minute == 690 && point.minute == 780)
                }
            } else {
                connects = false
            }
            if connects { path.addLine(to: position) }
            else { path.move(to: position) }
            let dot = CGRect(x: position.x - 0.9, y: position.y - 0.9, width: 1.8, height: 1.8)
            context.fill(Path(ellipseIn: dot), with: .color(Self.line))
            if !snapshot.isOpeningAuction, let lots = point.volumeLots, lots > 0 {
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

        if snapshot.isOpeningAuction {
            label("竞价参考价 · 09:25后为成交价", at: CGPoint(x: volume.midX, y: volume.minY + 9), anchor: .center, context: context)
            label("仅记录收到的报价 · 不显示分钟量", at: CGPoint(x: volume.midX, y: volume.minY + 24), anchor: .center, context: context)
        } else {
            let baseline = Path { path in
                path.move(to: CGPoint(x: volume.minX, y: volume.maxY))
                path.addLine(to: CGPoint(x: volume.maxX, y: volume.maxY))
            }
            context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)
            label(Self.volumeText(maximumVolume), at: CGPoint(x: size.width, y: volume.minY + 3), context: context)
            label("0", at: CGPoint(x: size.width, y: volume.maxY), context: context)
        }

        let axis: [(Double, String, UnitPoint)] = snapshot.isOpeningAuction ? [
            (0, "09:15", .leading), (5, "09:20", .center), (10, "09:25", .center), (15, "09:30", .trailing)
        ] : [
            (0, "09:30", .leading), (60, "10:30", .center),
            (120, "11:30/13:00", .center), (180, "14:00", .center), (240, "15:00", .trailing)
        ]
        for (minute, text, anchor) in axis {
            label(text, at: CGPoint(x: x(minute), y: size.height - (isLargeChart ? 7 : 4)), anchor: anchor, context: context)
        }

        if let selected = inspectedPoint {
            let selectedX = x(chartMinute(selected, snapshot: snapshot))
            let cursor = Path { path in
                path.move(to: CGPoint(x: selectedX, y: plot.minY))
                path.addLine(to: CGPoint(x: selectedX, y: volume.maxY))
            }
            context.stroke(cursor, with: .color(Self.line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
            let dot = CGRect(x: selectedX - 2.5, y: y(selected.price) - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dot), with: .color(Self.line))
        }
    }

    private func label(_ text: String, at position: CGPoint, anchor: UnitPoint = .trailing, color: Color = .secondary, context: GraphicsContext) {
        context.draw(Text(text).font(.system(size: isLargeChart ? 11 : 8, design: .monospaced)).foregroundColor(color),
                     at: position, anchor: anchor)
    }

    private static func volumeText(_ lots: Double?) -> String {
        guard let lots else { return "—" }
        return lots >= 10_000 ? String(format: "%.1f万手", lots / 10_000) : String(format: "%.0f手", lots)
    }

    private static func priceText(_ price: Double?) -> String {
        price.map { String(format: "%.2f", $0) } ?? "—"
    }

    private static func percentText(_ percent: Double?) -> String {
        percent.map { String(format: "%+.2f%%", $0) } ?? "—"
    }

    private func accessibilitySummary(_ snapshot: IntradaySnapshot) -> String {
        guard let latest = headerPoint else { return "尚无分时数据" }
        if snapshot.isOpeningAuction {
            let priceKind = latest.minute < 565 ? "竞价参考价" : "竞价成交价"
            return "\(timeText(latest))，\(priceKind)\(String(format: "%.2f", latest.price))，仅记录收到的报价，不显示分钟成交量。\(warning ?? "")"
        }
        return "\(latest.timeText)，价格\(String(format: "%.2f", latest.price))，较开盘\(Self.percentText(snapshot.changeFromOpenPercent(at: latest)))，最高\(Self.priceText(snapshot.dayHigh))，最低\(Self.priceText(snapshot.dayLow))，分钟成交量\(Self.volumeText(latest.volumeLots))。\(warning ?? "")"
    }
}
