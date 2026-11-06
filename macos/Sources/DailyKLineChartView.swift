import SwiftUI

struct DailyKLineChartView: View {
    static let height = IntradayChartView.height

    let snapshot: DailyKLineSnapshot?
    let error: String?
    let isRefreshing: Bool
    var chartHeight: CGFloat = Self.height
    var onExpand: (() -> Void)? = nil
    var interactive = false
    var annotationStore = DailyChartAnnotationStore()

    @State private var inspectedID: String?
    @State private var viewport = DailyChartViewport()
    @State private var tool: DailyChartTool = .browse
    @State private var annotations: [DailyChartAnnotation] = []
    @State private var undoHistory: [[DailyChartAnnotation]] = []
    @State private var loadedWorkspace: String?
    @State private var draftStart: DailyChartAnchor?
    @State private var draftEnd: DailyChartAnchor?
    @State private var selectedAnnotationID: UUID?
    @State private var panRemainder: CGFloat = 0

    private static let rising = Color(red: 0.85, green: 0.19, blue: 0.24)
    private static let falling = Color(red: 0.06, green: 0.59, blue: 0.38)
    private static let cursor = Color(red: 0.12, green: 0.48, blue: 0.95)

    private var allCandles: [DailyCandle] { snapshot?.candles ?? [] }
    private var dates: [String] { allCandles.map(\.date) }
    private var visibleRange: Range<Int> {
        interactive ? viewport.range(in: dates) : max(0, allCandles.count - 60)..<allCandles.count
    }
    private var candles: [DailyCandle] { Array(allCandles[visibleRange]) }
    private var workspace: String? {
        snapshot.map { $0.symbol.id + "|" + $0.adjustment }
    }

    private var inspectedCandle: DailyCandle? {
        guard let inspectedID else { return nil }
        return candles.first { $0.id == inspectedID }
    }

    private var headerCandle: DailyCandle? { inspectedCandle ?? candles.last }
    private var isLargeChart: Bool { chartHeight > Self.height }

    var body: some View {
        VStack(spacing: 7) {
            if interactive { workspaceToolbar }
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
                    Text(interactive ? (selectedAnnotationID == nil ? "日K行情" : "已选中 · Esc删除")
                         : "\(candles.count)日 · " + String(latest.date.suffix(5)))
                        .foregroundStyle(selectedAnnotationID == nil ? Color.secondary : Self.cursor)
                        .fixedSize()
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
                        if interactive {
                            DailyChartInteraction(isBrowsing: tool == .browse, tooltip: details,
                                onHover: { inspect($0, in: geometry.size) },
                                onClick: { addAnnotation(at: $0, in: geometry.size) },
                                onDragStart: { panRemainder = 0 },
                                onPan: { pan(by: $0, in: geometry.size) },
                                onZoom: { zoom(by: $0, at: $1, in: geometry.size) },
                                onCancel: cancelCurrentInteraction)
                        } else {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(count: 2) { onExpand?() }
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location): inspect(location, in: geometry.size)
                                    case .ended: inspect(nil, in: geometry.size)
                                    }
                                }
                        }
                    }
                }
                .help(details)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("可见\(candles.count)个交易日的日K线与成交量")
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
        .onAppear(perform: loadWorkspace)
        .onChange(of: workspace) { _ in loadWorkspace() }
        .onChange(of: interactive) { _ in loadWorkspace() }
        .onChange(of: tool) { value in
            cancelDraft()
            if value != .browse { selectedAnnotationID = nil }
        }
    }

    private var workspaceToolbar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Picker("绘图工具", selection: $tool) {
                    Text("浏览").tag(DailyChartTool.browse)
                    Text("标记").tag(DailyChartTool.marker)
                    Text("画线").tag(DailyChartTool.trendLine)
                    Text("水平线").tag(DailyChartTool.horizontalLine)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .help(toolHint)
                Spacer(minLength: 0)
                Button("缩小") { zoom(by: 1.25) }
                    .help("显示更多交易日；鼠标向下滚动也可缩小")
                Button("放大") { zoom(by: 0.8) }
                    .help("显示更少交易日；鼠标向上滚动也可放大")
                Button("最近60日") {
                    viewport.reset()
                    inspectedID = nil
                    panRemainder = 0
                }
            }
            HStack(spacing: 8) {
                if let first = candles.first, let last = candles.last {
                    Text("\(first.date) — \(last.date) · \(candles.count)/\(allCandles.count)日")
                        .monospacedDigit()
                        .help("可见\(candles.count)个交易日，已加载\(allCandles.count)个交易日")
                } else {
                    Text("等待日K数据")
                }
                Spacer(minLength: 0)
                Button("撤销", action: undoAnnotation).disabled(undoHistory.isEmpty && draftStart == nil)
                Button("清空") {
                    cancelDraft()
                    selectedAnnotationID = nil
                    replaceAnnotations(with: [])
                }.disabled(annotations.isEmpty && draftStart == nil)
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .lineLimit(1)
        .onExitCommand(perform: cancelCurrentInteraction)
    }

    private var toolHint: String {
        switch tool {
        case .browse: "拖动平移；单击标注后按Esc删除"
        case .marker: "单击价格区添加价格标记"
        case .trendLine: "依次单击起点和终点；Esc取消"
        case .horizontalLine: "单击价格区添加水平线"
        }
    }

    private func loadWorkspace() {
        inspectedID = nil
        viewport.reset()
        tool = .browse
        cancelDraft()
        selectedAnnotationID = nil
        undoHistory = []
        panRemainder = 0
        loadedWorkspace = workspace
        if interactive, let snapshot {
            annotations = annotationStore.load(symbol: snapshot.symbol.id, adjustment: snapshot.adjustment)
        } else {
            annotations = []
        }
    }

    private func inspect(_ location: CGPoint?, in size: CGSize) {
        let plot = priceRect(in: size)
        guard let location, !candles.isEmpty,
              location.x >= plot.minX, location.x <= plot.maxX else {
            inspectedID = nil
            draftEnd = nil
            return
        }
        let index = min(candles.count - 1, Int((location.x - plot.minX) / plot.width * CGFloat(candles.count)))
        inspectedID = candles[index].id
        if interactive, draftStart != nil { draftEnd = anchor(at: location, in: size) }
    }

    private func zoom(by factor: Double) {
        viewport.zoom(by: factor, anchor: 0.5, dates: dates)
        inspectedID = nil
        panRemainder = 0
    }

    private func zoom(by factor: Double, at location: CGPoint, in size: CGSize) {
        let plot = priceRect(in: size)
        let position = min(1, max(0, Double((location.x - plot.minX) / plot.width)))
        viewport.zoom(by: factor, anchor: position, dates: dates)
        panRemainder = 0
        inspect(location, in: size)
    }

    private func pan(by distance: CGFloat, in size: CGSize) {
        guard tool == .browse, !candles.isEmpty else { return }
        let step = priceRect(in: size).width / CGFloat(candles.count)
        panRemainder += distance
        let shift = Int(-panRemainder / step)
        guard shift != 0 else { return }
        viewport.pan(by: shift, dates: dates)
        panRemainder += CGFloat(shift) * step
    }

    private func anchor(at location: CGPoint, in size: CGSize) -> DailyChartAnchor? {
        let plot = priceRect(in: size)
        guard plot.contains(location), !candles.isEmpty, let priceRange else { return nil }
        let index = min(candles.count - 1, Int((location.x - plot.minX) / plot.width * CGFloat(candles.count)))
        let price = priceRange.lowerBound + Double((plot.maxY - location.y) / plot.height)
            * (priceRange.upperBound - priceRange.lowerBound)
        return DailyChartAnchor(date: candles[index].date, price: price)
    }

    private func addAnnotation(at location: CGPoint, in size: CGSize) {
        guard interactive, loadedWorkspace == workspace else { return }
        let plot = priceRect(in: size)
        if draftStart == nil, let selected = DailyChartAnnotationHitTest.hit(
            at: location, annotations: annotations, plot: plot,
            position: { annotationPosition($0, in: plot) },
            priceY: { annotationPriceY($0, in: plot) }) {
            selectedAnnotationID = selected
            tool = .browse
            return
        }
        selectedAnnotationID = nil
        guard let anchor = anchor(at: location, in: size) else { return }
        switch tool {
        case .browse: break
        case .marker:
            replaceAnnotations(with: annotations + [DailyChartAnnotation(kind: .marker, start: anchor)])
        case .horizontalLine:
            replaceAnnotations(with: annotations + [DailyChartAnnotation(kind: .horizontalLine, start: anchor)])
        case .trendLine:
            if let draftStart {
                replaceAnnotations(with: annotations + [DailyChartAnnotation(kind: .trendLine, start: draftStart, end: anchor)])
                cancelDraft()
            } else {
                draftStart = anchor
                draftEnd = anchor
            }
        }
    }

    private func replaceAnnotations(with values: [DailyChartAnnotation]) {
        guard interactive, loadedWorkspace == workspace, values != annotations else { return }
        undoHistory.append(annotations)
        annotations = values
        saveAnnotations()
    }

    private func undoAnnotation() {
        selectedAnnotationID = nil
        if draftStart != nil {
            cancelDraft()
            return
        }
        guard let previous = undoHistory.popLast() else { return }
        annotations = previous
        saveAnnotations()
    }

    private func saveAnnotations() {
        guard interactive, loadedWorkspace == workspace, let snapshot else { return }
        annotationStore.save(annotations, symbol: snapshot.symbol.id, adjustment: snapshot.adjustment)
    }

    private func cancelDraft() {
        draftStart = nil
        draftEnd = nil
    }

    private func cancelCurrentInteraction() {
        if draftStart != nil {
            cancelDraft()
        } else if let selectedAnnotationID {
            replaceAnnotations(with: annotations.filter { $0.id != selectedAnnotationID })
        }
        selectedAnnotationID = nil
        tool = .browse
    }

    private func annotationPriceY(_ price: Double, in plot: CGRect) -> CGFloat {
        guard let priceRange else { return plot.midY }
        return plot.maxY - CGFloat((price - priceRange.lowerBound)
            / (priceRange.upperBound - priceRange.lowerBound)) * plot.height
    }

    private func annotationPosition(_ anchor: DailyChartAnchor, in plot: CGRect) -> CGPoint? {
        let range = visibleRange
        guard !range.isEmpty, let index = allCandles.firstIndex(where: { $0.date == anchor.date }) else { return nil }
        let step = plot.width / CGFloat(range.count)
        return CGPoint(x: plot.minX + (CGFloat(index - range.lowerBound) + 0.5) * step,
                       y: annotationPriceY(anchor.price, in: plot))
    }

    private var priceRange: ClosedRange<Double>? {
        guard let minimum = candles.map(\.low).min(), let maximum = candles.map(\.high).max() else { return nil }
        let padding = max((maximum - minimum) * 0.08, max(maximum * 0.001, 0.02))
        let low = max(0, minimum - padding)
        let high = maximum + padding
        guard (high - low).isFinite, high > low else { return nil }
        return low...high
    }

    private func priceRect(in size: CGSize) -> CGRect {
        CGRect(x: 2, y: isLargeChart ? 8 : 5,
               width: max(1, size.width - (isLargeChart ? 80 : 43)),
               height: max(1, size.height - (isLargeChart ? 115 : 70)))
    }

    private func draw(in size: CGSize, context: GraphicsContext) {
        let candles = candles
        guard let priceRange else { return }
        let plot = priceRect(in: size)
        let volume = CGRect(x: plot.minX, y: plot.maxY + (isLargeChart ? 16 : 12),
                            width: plot.width, height: isLargeChart ? 65 : 35)
        let low = priceRange.lowerBound
        let high = priceRange.upperBound
        let span = high - low
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

        if interactive, loadedWorkspace == workspace {
            drawAnnotations(in: plot, context: context)
        }
    }

    private func drawAnnotations(in plot: CGRect, context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: Path(plot))
        func endpoint(_ point: CGPoint, price: Double?, color: Color, selected: Bool, draft: Bool) {
            let dot = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            clipped.fill(Path(ellipseIn: dot), with: .color(color.opacity(draft ? 0.65 : 1)))
            if selected {
                clipped.stroke(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(color), lineWidth: 1.5)
            }
            if let price, plot.contains(point) {
                let right = point.x > plot.midX
                let textPoint = CGPoint(x: point.x + (right ? -8 : 8), y: max(plot.minY + 8, point.y - 10))
                clipped.draw(Text(Self.priceText(price)).font(.system(size: 11, design: .monospaced)).foregroundColor(color),
                             at: textPoint, anchor: right ? .trailing : .leading)
            }
        }
        func draw(_ annotation: DailyChartAnnotation, draft: Bool = false) {
            let selected = !draft && annotation.id == selectedAnnotationID
            let color = selected ? Self.cursor : Color.orange
            if annotation.kind == .horizontalLine {
                let lineY = annotationPriceY(annotation.start.price, in: plot)
                let line = Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: lineY))
                    path.addLine(to: CGPoint(x: plot.maxX, y: lineY))
                }
                clipped.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: selected ? 2.6 : 1.4, dash: [5, 3]))
                if selected {
                    endpoint(CGPoint(x: plot.minX + 7, y: lineY), price: nil, color: color, selected: true, draft: false)
                    endpoint(CGPoint(x: plot.maxX - 7, y: lineY), price: nil, color: color, selected: true, draft: false)
                }
                if lineY >= plot.minY, lineY <= plot.maxY {
                    clipped.draw(Text(Self.priceText(annotation.start.price)).font(.system(size: 11, design: .monospaced)).foregroundColor(color),
                                 at: CGPoint(x: plot.maxX - 4, y: max(plot.minY + 8, lineY - 9)), anchor: .trailing)
                }
                return
            }
            guard let start = annotationPosition(annotation.start, in: plot) else { return }
            if annotation.kind == .trendLine, let end = annotation.end.flatMap({ annotationPosition($0, in: plot) }) {
                let line = Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                clipped.stroke(line, with: .color(color.opacity(draft ? 0.65 : 1)),
                               style: StrokeStyle(lineWidth: selected ? 2.8 : 1.6, dash: draft ? [4, 3] : []))
                endpoint(end, price: nil, color: color, selected: selected, draft: draft)
            }
            endpoint(start, price: annotation.kind == .marker ? annotation.start.price : nil,
                     color: color, selected: selected, draft: draft)
        }
        for annotation in annotations { draw(annotation) }
        if let draftStart {
            draw(DailyChartAnnotation(kind: .trendLine, start: draftStart, end: draftEnd), draft: true)
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
