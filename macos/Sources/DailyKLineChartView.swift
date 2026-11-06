import SwiftUI

struct DailyKLineChartView: View {
    static let height = IntradayChartView.height

    let snapshot: DailyKLineSnapshot?
    let error: String?
    let isRefreshing: Bool
    var chartHeight: CGFloat = Self.height
    var onExpand: (() -> Void)? = nil

    @State private var inspectedID: String?

    private static let rising = Color(red: 0.85, green: 0.19, blue: 0.24)
    private static let falling = Color(red: 0.06, green: 0.59, blue: 0.38)
    private static let cursor = Color(red: 0.12, green: 0.48, blue: 0.95)

    private var candles: [DailyCandle] {
        snapshot.map { Array($0.candles.suffix(60)) } ?? []
    }

    private var inspectedCandle: DailyCandle? {
        guard let inspectedID else { return nil }
        return candles.first { $0.id == inspectedID }
    }

    private var headerCandle: DailyCandle? { inspectedCandle ?? candles.last }
    private var isLargeChart: Bool { chartHeight > Self.height }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text("日K").fontWeight(.medium)
                if let snapshot {
                    Text(snapshot.adjustment).foregroundStyle(.secondary)
                }
                if let error, !error.isEmpty {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                        .help(error)
                        .accessibilityLabel("日K数据提示：" + error)
                }
                Spacer(minLength: 3)
                if let candle = headerCandle {
                    Text(candle.date).foregroundStyle(.secondary)
                    Text("开 " + Self.priceText(candle.open)).foregroundStyle(.secondary)
                    Text("收 " + Self.priceText(candle.close)).foregroundStyle(Self.color(candle))
                } else {
                    Text("日线 / 成交量").foregroundStyle(.secondary)
                }
                if isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("正在更新日K")
                }
            }
            .font(.system(size: isLargeChart ? 13 : 10))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: isLargeChart ? 20 : 14)

            if let candle = headerCandle, let latest = candles.last {
                HStack(spacing: 8) {
                    Text("\(candles.count)日 · " + String(latest.date.suffix(5))).fixedSize()
                    Spacer(minLength: 0)
                    Text("高 " + Self.priceText(candle.high)).fixedSize()
                    Text("低 " + Self.priceText(candle.low)).fixedSize()
                    Text("量 " + Self.volumeText(candle.volumeLots)).fixedSize()
                }
                .font(.system(size: isLargeChart ? 13 : 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(height: isLargeChart ? 18 : 12)
            }

            if !candles.isEmpty {
                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(in: size, context: context)
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
                                    let index = Int((location.x - plot.minX) / plot.width * CGFloat(candles.count))
                                    inspectedID = candles[min(index, candles.count - 1)].id
                                case .ended:
                                    inspectedID = nil
                                }
                            }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("最近\(candles.count)个交易日的日K线与成交量")
                .accessibilityValue(accessibilitySummary)
                .accessibilityActions {
                    if let onExpand { Button("放大图表", action: onExpand) }
                }
            } else {
                VStack(spacing: 5) {
                    Text(error == nil ? (isRefreshing ? "正在加载日K…" : "尚无日K数据") : "日K暂不可用")
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
        .onChange(of: snapshot?.symbol) { _ in inspectedID = nil }
    }

    private func priceRect(in size: CGSize) -> CGRect {
        CGRect(x: 2, y: isLargeChart ? 8 : 5,
               width: max(1, size.width - (isLargeChart ? 80 : 43)),
               height: max(1, size.height - (isLargeChart ? 115 : 70)))
    }

    private func draw(in size: CGSize, context: GraphicsContext) {
        let candles = candles
        guard let minimum = candles.map(\.low).min(), let maximum = candles.map(\.high).max() else { return }
        let plot = priceRect(in: size)
        let volume = CGRect(x: plot.minX, y: plot.maxY + (isLargeChart ? 16 : 12),
                            width: plot.width, height: isLargeChart ? 65 : 35)
        let padding = max((maximum - minimum) * 0.08, max(maximum * 0.001, 0.02))
        let low = max(0, minimum - padding)
        let high = maximum + padding
        let span = max(high - low, 0.01)
        guard span.isFinite else { return }
        let maximumVolume = candles.map(\.volumeLots).max() ?? 0
        let step = plot.width / CGFloat(candles.count)
        let bodyWidth = max(1, min(8, step * 0.65))
        let x: (Int) -> CGFloat = { plot.minX + (CGFloat($0) + 0.5) * step }
        let y: (Double) -> CGFloat = { plot.maxY - CGFloat(($0 - low) / span) * plot.height }

        for value in [high, (high + low) / 2, low] {
            let grid = Path { path in
                path.move(to: CGPoint(x: plot.minX, y: y(value)))
                path.addLine(to: CGPoint(x: plot.maxX, y: y(value)))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.32)), lineWidth: 0.75)
            label(Self.priceText(value), at: CGPoint(x: size.width, y: y(value)), context: context)
        }

        for (index, candle) in candles.enumerated() {
            let centerX = x(index)
            let color = Self.color(candle)
            let wick = Path { path in
                path.move(to: CGPoint(x: centerX, y: y(candle.high)))
                path.addLine(to: CGPoint(x: centerX, y: y(candle.low)))
            }
            context.stroke(wick, with: .color(color), lineWidth: 0.8)
            let openY = y(candle.open)
            let closeY = y(candle.close)
            let body = CGRect(x: centerX - bodyWidth / 2,
                              y: min(openY, closeY),
                              width: bodyWidth,
                              height: max(1, abs(openY - closeY)))
            context.fill(Path(body), with: .color(color))

            if candle.volumeLots > 0 {
                let height = max(0.7, CGFloat(candle.volumeLots / max(maximumVolume, 1)) * volume.height)
                let bar = CGRect(x: centerX - bodyWidth / 2, y: volume.maxY - height,
                                 width: bodyWidth, height: height)
                context.fill(Path(bar), with: .color(color.opacity(0.85)))
            }
        }

        let baseline = Path { path in
            path.move(to: CGPoint(x: volume.minX, y: volume.maxY))
            path.addLine(to: CGPoint(x: volume.maxX, y: volume.maxY))
        }
        context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 0.75)
        label(Self.volumeText(maximumVolume), at: CGPoint(x: size.width, y: volume.minY + 3), context: context)
        label("0", at: CGPoint(x: size.width, y: volume.maxY), context: context)

        label(String(candles[0].date.suffix(5)),
              at: CGPoint(x: candles.count == 1 ? plot.midX : plot.minX, y: size.height - (isLargeChart ? 7 : 4)),
              anchor: candles.count == 1 ? .center : .leading, context: context)
        if candles.count > 2 {
            let middle = candles.count / 2
            label(String(candles[middle].date.suffix(5)), at: CGPoint(x: x(middle), y: size.height - (isLargeChart ? 7 : 4)), anchor: .center, context: context)
        }
        if candles.count > 1 {
            label(String(candles[candles.count - 1].date.suffix(5)), at: CGPoint(x: plot.maxX, y: size.height - (isLargeChart ? 7 : 4)), context: context)
        }

        if let inspectedID, let index = candles.firstIndex(where: { $0.id == inspectedID }) {
            let selectedX = x(index)
            let cursor = Path { path in
                path.move(to: CGPoint(x: selectedX, y: plot.minY))
                path.addLine(to: CGPoint(x: selectedX, y: volume.maxY))
            }
            context.stroke(cursor, with: .color(Self.cursor.opacity(0.6)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 2]))
        }
    }

    private func label(_ text: String, at position: CGPoint, anchor: UnitPoint = .trailing, context: GraphicsContext) {
        context.draw(Text(text).font(.system(size: isLargeChart ? 11 : 8, design: .monospaced)).foregroundColor(.secondary),
                     at: position, anchor: anchor)
    }

    private static func color(_ candle: DailyCandle) -> Color {
        candle.close > candle.open ? rising : candle.close < candle.open ? falling : .secondary
    }

    private static func priceText(_ price: Double) -> String {
        String(format: "%.2f", price)
    }

    private static func volumeText(_ lots: Double) -> String {
        if lots >= 100_000_000 { return String(format: "%.2f亿手", lots / 100_000_000) }
        return lots >= 10_000 ? String(format: "%.1f万手", lots / 10_000) : String(format: "%.0f手", lots)
    }

    private var accessibilitySummary: String {
        guard let candle = headerCandle else { return "尚无日K数据" }
        return "\(candle.date)，\(snapshot?.adjustment ?? "")，开盘\(Self.priceText(candle.open))，最高\(Self.priceText(candle.high))，最低\(Self.priceText(candle.low))，收盘\(Self.priceText(candle.close))，成交量\(Self.volumeText(candle.volumeLots))。\(error ?? "")"
    }

    private var details: String {
        guard let candle = headerCandle else { return "尚无日K数据" }
        return [
            "日期：\(candle.date)　\(snapshot?.adjustment ?? "")",
            "开盘：\(Self.priceText(candle.open))　收盘：\(Self.priceText(candle.close))",
            "最高：\(Self.priceText(candle.high))　最低：\(Self.priceText(candle.low))",
            "成交量：\(Self.volumeText(candle.volumeLots))"
        ].joined(separator: "\n")
    }

}
