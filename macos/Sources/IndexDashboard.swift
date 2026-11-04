import SwiftUI

struct DashboardIndex: Identifiable, Sendable {
    let symbol: StockSymbol
    let title: String
    let detail: String
    var id: String { symbol.id }

    static let all: [DashboardIndex] = [
        DashboardIndex(symbol: StockSymbol(code: "980017", market: "sz"), title: "半导体", detail: "国证芯片"),
        DashboardIndex(symbol: StockSymbol(code: "000688", market: "sh"), title: "科创50", detail: "科创板"),
        DashboardIndex(symbol: StockSymbol(code: "399006", market: "sz"), title: "创业板指", detail: "创业板"),
        DashboardIndex(symbol: StockSymbol(code: "000001", market: "sh"), title: "上证指数", detail: "沪市"),
        DashboardIndex(symbol: StockSymbol(code: "399001", market: "sz"), title: "深证成指", detail: "深市"),
        DashboardIndex(symbol: StockSymbol(code: "000300", market: "sh"), title: "沪深300", detail: "大盘"),
        DashboardIndex(symbol: StockSymbol(code: "000905", market: "sh"), title: "中证500", detail: "中盘"),
        DashboardIndex(symbol: StockSymbol(code: "000852", market: "sh"), title: "中证1000", detail: "小盘")
    ]

    static var symbols: [StockSymbol] { all.map(\.symbol) }
}

struct IndexDashboardView: View {
    static let height: CGFloat = 496
    static let expandedHeight: CGFloat = 570

    let quotes: [String: Quote]
    let unavailable: Set<String>
    let error: String?
    let now: Date
    let expandedChartSymbolID: String?
    let intradaySnapshot: IntradaySnapshot?
    let intradayError: String?
    let isIntradayRefreshing: Bool
    let showIntraday: (StockSymbol) -> Void

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<(DashboardIndex.all.count / 2), id: \.self) { row in
                        let indices = Array(DashboardIndex.all[(row * 2)..<(row * 2 + 2)])
                        HStack(spacing: 8) {
                            ForEach(indices) { index in
                                IndexCard(index: index, quote: quotes[index.id],
                                          unavailable: unavailable.contains(index.id), error: error, now: now,
                                          isChartExpanded: expandedChartSymbolID == index.id,
                                          showIntraday: { showIntraday(index.symbol) })
                            }
                        }
                        if let index = indices.first(where: { $0.id == expandedChartSymbolID }) {
                            chart(for: index)
                                .id("chart-" + index.id)
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: expandedChartSymbolID == nil ? Self.height : Self.expandedHeight)
            .onChange(of: expandedChartSymbolID) { id in
                guard let id else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scroll.scrollTo("chart-" + id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func chart(for index: DashboardIndex) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(index.title).fontWeight(.semibold)
                Text(index.symbol.code).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { showIntraday(index.symbol) } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起" + index.title + "分时图")
                .accessibilityLabel("收起" + index.title + "分时图")
            }
            .font(.system(size: 11))
            IntradayChartView(snapshot: intradaySnapshot, error: intradayError,
                              isRefreshing: isIntradayRefreshing, now: now)
                .id(index.id)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct IndexCard: View {
    let index: DashboardIndex
    let quote: Quote?
    let unavailable: Bool
    let error: String?
    let now: Date
    let isChartExpanded: Bool
    let showIntraday: () -> Void

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
        Button(action: showIntraday) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(index.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    if warning != nil {
                        Circle().fill(.orange).frame(width: 4, height: 4)
                    }
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 10))
                        .foregroundStyle(isChartExpanded ? Color.accentColor : Color.secondary)
                }
                HStack(spacing: 4) {
                    Text(index.detail)
                    Spacer(minLength: 0)
                    Text(index.symbol.code)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                Text(quote.map { Self.point($0.price) } ?? "—")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(changeColor)
                HStack(spacing: 6) {
                    Text(quote.map { String(format: "%+.2f%%", $0.changePercent) } ?? "—")
                        .fontWeight(.semibold)
                    Text(quote.map { String(format: "%+.2f", $0.change) } ?? "—")
                        .font(.system(size: 10))
                }
                .font(.system(size: 11))
                .foregroundStyle(changeColor)
                HStack(spacing: 4) {
                    Text("高 " + (quote?.dayHigh.map(Self.point) ?? "—"))
                    Spacer(minLength: 0)
                    Text("低 " + (quote?.dayLow.map(Self.point) ?? "—"))
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 112)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isChartExpanded ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(details)
        .accessibilityLabel((isChartExpanded ? "收起" : "查看") + index.title + "分时图")
        .accessibilityValue(accessibilityText)
    }

    private var changeColor: Color {
        guard let change = quote?.change else { return .secondary }
        return change > 0 ? Self.rising : change < 0 ? Self.falling : .primary
    }

    private var warning: String? {
        var messages: [String] = []
        if let error, !error.isEmpty { messages.append(error) }
        if unavailable { messages.append("本次未收到有效指数报价") }
        if let quote {
            if MarketClock.isStale(timestamp: quote.timestamp, at: now, session: MarketClock.session(at: now)) {
                messages.append("指数报价较旧")
            }
        } else {
            messages.append("等待指数行情")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private var details: String {
        var lines = ["\(index.title) · \(quote?.name ?? index.detail)（\(index.symbol.id.uppercased())）", "指数点位及涨跌来自腾讯行情；涨跌以昨收为基准。"]
        if let quote {
            lines.append("源时间：" + Self.sourceTime.string(from: quote.timestamp))
            lines.append("今日最高：\(quote.dayHigh.map(Self.point) ?? "—")；今日最低：\(quote.dayLow.map(Self.point) ?? "—")")
        }
        if let warning { lines.append(warning) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var text = "\(index.title)，\(index.detail)，代码\(index.symbol.code)"
        if let quote {
            text += String(format: "，点位%.2f，涨跌幅%+.2f%%，涨跌%+.2f", quote.price, quote.changePercent, quote.change)
            text += "，最高\(quote.dayHigh.map(Self.point) ?? "暂无")，最低\(quote.dayLow.map(Self.point) ?? "暂无")"
        }
        if let warning { text += "，" + warning }
        return text
    }

    private static func point(_ value: Double) -> String { String(format: "%.2f", value) }
}
