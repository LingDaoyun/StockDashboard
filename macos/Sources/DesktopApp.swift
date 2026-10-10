import AppKit
import SwiftUI
import Combine
import UserNotifications

private let quoteRowHeight: CGFloat = 78
private let trackingEditorHeight: CGFloat = 220

@MainActor
final class QuoteStore: ObservableObject {
    @Published private(set) var symbols: [StockSymbol]
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var lastReceipt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published var isAddingStock = false
    @Published var isAdjustingTransparency = false
    @Published var expandedSymbolID: String?
    @Published private(set) var tracking: [String: StockTracking] = [:]
    @Published private(set) var invalidTracking: [String: StockTracking] = [:]
    @Published private(set) var priceAlerts: [String: String] = [:]
    @Published private(set) var buyCommissionRate: String
    @Published private(set) var trackingStorageNotice: String?
    @Published var notificationNotice: String?
    var onPriceAlert: ((PriceAlert) -> Void)?
    var onAlertSetup: (() -> Void)?
    @Published var backgroundTransparency: Double {
        didSet { defaults.set(backgroundTransparency, forKey: "backgroundTransparency") }
    }
    @Published var isPinned: Bool {
        didSet { defaults.set(isPinned, forKey: "pinned") }
    }
    @Published var autoHideEnabled: Bool {
        didSet { defaults.set(autoHideEnabled, forKey: "autoHideEnabled") }
    }

    let defaults: UserDefaults
    let isPreview: Bool
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var suspended = false
    private let client = QuoteClient()
    private var undecodableTracking: [String: TrackingJSONValue] = [:]
    private var backedUpCorruptTracking = false

    // Keep rejected JSON fields without routing precise costs through Double.
    private indirect enum TrackingJSONValue: Codable {
        case null, bool(Bool), number(Decimal), double(Double), string(String)
        case array([TrackingJSONValue]), object([String: TrackingJSONValue])

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
            else if let text = try? value.decode(String.self) { self = .string(text) }
            else if let number = try? value.decode(Decimal.self) { self = .number(number) }
            else if let number = try? value.decode(Double.self), number.isFinite { self = .double(number) }
            else if let array = try? value.decode([TrackingJSONValue].self) { self = .array(array) }
            else { self = .object(try value.decode([String: TrackingJSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case .bool(let flag): try value.encode(flag)
            case .number(let number): try value.encode(number)
            case .double(let number): try value.encode(number)
            case .string(let text): try value.encode(text)
            case .array(let array): try value.encode(array)
            case .object(let object): try value.encode(object)
            }
        }
    }

    init(defaults: UserDefaults, preview: String?) {
        self.defaults = defaults
        self.isPreview = preview != nil
        let saved = preview ?? defaults.string(forKey: "symbols") ?? ""
        self.symbols = (try? StockSymbol.parseList(saved)) ?? []
        self.isPinned = defaults.object(forKey: "pinned") as? Bool ?? false
        self.buyCommissionRate = defaults.string(forKey: "buyCommissionRate") ?? "2.5"
        self.autoHideEnabled = defaults.object(forKey: "autoHideEnabled") as? Bool ?? true
        self.backgroundTransparency = min(1, max(0, defaults.object(forKey: "backgroundTransparency") as? Double ?? 0.3))
        if let data = defaults.data(forKey: "stockTracking") {
            if let savedTracking = try? JSONDecoder().decode([String: TrackingJSONValue].self, from: data) {
                let ids = Set(symbols.map(\.id))
                for (id, rawValue) in savedTracking where ids.contains(id) {
                    guard let rawData = try? JSONEncoder().encode(rawValue),
                          let value = try? JSONDecoder().decode(StockTracking.self, from: rawData) else {
                        undecodableTracking[id] = rawValue
                        continue
                    }
                    if let validated = try? value.validated() { tracking[id] = validated }
                    else { invalidTracking[id] = value }
                }
                if !undecodableTracking.isEmpty {
                    trackingStorageNotice = "部分持仓配置无法读取，原数据已保留；请重新保存对应股票。"
                }
            } else {
                defaults.set(data, forKey: "stockTrackingCorruptBackup")
                backedUpCorruptTracking = true
                trackingStorageNotice = "持仓配置无法读取，原数据已本地备份；请核对并重新录入。"
            }
        }
    }

    var codeText: String { symbols.map(\.id).joined(separator: ", ") }

    var totalPositionProfit: Decimal? {
        guard trackingStorageNotice == nil, !invalidTracking.values.contains(where: {
            $0.costPrice != nil || $0.totalCostYuan != nil || $0.quantity != nil
                || $0.purchaseAmountYuan != nil || $0.purchaseCommissionRate != nil
        }) else { return nil }
        var total = Decimal.zero
        for symbol in symbols {
            guard let position = tracking[symbol.id], position.hasPosition else { continue }
            guard let quote = quotes[symbol.id], var amount = position.profit(at: quote.price)?.amount else { return nil }
            var sum = Decimal()
            guard NSDecimalAdd(&sum, &total, &amount, .plain) == .noError else { return nil }
            total = sum
        }
        return total
    }

    var listHeight: CGFloat {
        if symbols.isEmpty { return 198 }
        return min(symbols.reduce(CGFloat(max(0, symbols.count - 1))) { total, symbol in
            let configuration = tracking[symbol.id]
            return total + quoteRowHeight
                + (configuration?.hasPosition == true ? 18 : 0)
                + (configuration?.hasAlerts == true ? 18 : 0)
                + (expandedSymbolID == symbol.id ? trackingEditorHeight : 0)
        }, 570)
    }

    func saveTracking(for symbol: StockSymbol, cost: String, quantity: String, upper: String, lower: String,
                      totalCost: String = "", purchaseAmount: String = "", purchaseCommissionRate: Decimal? = nil,
                      now: Date = Date()) throws {
        guard symbols.contains(symbol) else {
            throw NSError(domain: "StockTracking", code: 1, userInfo: [NSLocalizedDescriptionKey: "股票已移除，请重新添加。"])
        }
        var value = try StockTracking.parse(cost: cost, quantity: quantity, upper: upper, lower: lower,
                                           totalCost: totalCost, purchaseAmount: purchaseAmount,
                                           purchaseCommissionRate: purchaseCommissionRate)
        let previous = tracking[symbol.id] ?? invalidTracking[symbol.id]
        value.upperTriggered = value.upperPrice != nil && value.upperPrice == previous?.upperPrice && previous?.upperTriggered == true
        value.lowerTriggered = value.lowerPrice != nil && value.lowerPrice == previous?.lowerPrice && previous?.lowerTriggered == true
        let changedPrices = value.upperPrice != previous?.upperPrice || value.lowerPrice != previous?.lowerPrice
        value.armedAt = value.hasAlerts ? (changedPrices ? now : previous?.armedAt ?? now) : nil
        tracking[symbol.id] = value.hasPosition || value.hasAlerts ? value : nil
        invalidTracking[symbol.id] = nil
        undecodableTracking[symbol.id] = nil
        if changedPrices { priceAlerts[symbol.id] = nil }
        persistTracking()
        if value.hasAlerts { onAlertSetup?() }
    }

    func savePosition(for symbol: StockSymbol, amount: String, quantity: String, upper: String, lower: String,
                      estimateFees: Bool, commissionRate: String, now: Date = Date()) throws {
        let amountText = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        if estimateFees, amountText.isEmpty,
           let existing = tracking[symbol.id], existing.hasPosition, existing.purchaseAmountYuan == nil,
           let existingQuantity = existing.quantity,
           quantity.trimmingCharacters(in: .whitespacesAndNewlines) == String(existingQuantity) {
            try saveTracking(for: symbol, cost: existing.costPrice.map { String($0) } ?? "",
                             quantity: quantity, upper: upper, lower: lower,
                             totalCost: existing.totalCostYuan.map { NSDecimalNumber(decimal: $0).stringValue } ?? "", now: now)
            return
        }
        if estimateFees && !amountText.isEmpty {
            let estimate = try BuyFeeEstimate.calculate(amount: amount, commissionRate: commissionRate, symbol: symbol)
            let previousRate = (tracking[symbol.id] ?? invalidTracking[symbol.id])?.purchaseCommissionRate
            try saveTracking(for: symbol, cost: "", quantity: quantity, upper: upper, lower: lower,
                             totalCost: estimate.totalCostText,
                             purchaseAmount: NSDecimalNumber(decimal: estimate.purchaseAmountYuan).stringValue,
                             purchaseCommissionRate: estimate.commissionRatePerTenThousand, now: now)
            if previousRate != estimate.commissionRatePerTenThousand {
                buyCommissionRate = commissionRate.trimmingCharacters(in: .whitespacesAndNewlines)
                defaults.set(buyCommissionRate, forKey: "buyCommissionRate")
            }
        } else {
            try saveTracking(for: symbol, cost: "", quantity: quantity, upper: upper, lower: lower,
                             totalCost: amount, now: now)
        }
    }

    func rearmAlerts(for symbol: StockSymbol, now: Date = Date()) {
        guard var value = tracking[symbol.id], value.hasAlerts else { return }
        value.upperTriggered = false
        value.lowerTriggered = false
        value.armedAt = now
        tracking[symbol.id] = value
        priceAlerts[symbol.id] = nil
        persistTracking()
        onAlertSetup?()
    }

    func evaluateAlerts(_ incoming: [String: Quote], now: Date) {
        var changed = false
        for symbol in symbols {
            guard let quote = incoming[symbol.id], var value = tracking[symbol.id] else { continue }
            let alerts = value.takeAlerts(for: quote, now: now)
            guard !alerts.isEmpty else { continue }
            tracking[symbol.id] = value
            changed = true
            for alert in alerts {
                priceAlerts[symbol.id] = alert.message
                onPriceAlert?(alert)
            }
        }
        if changed { persistTracking() }
    }

    private func persistTracking() {
        // Preserve rejected entries for correction instead of deleting their saved fields.
        let values = invalidTracking.merging(tracking) { _, valid in valid }
        if let encoded = try? JSONEncoder().encode(values),
           let records = try? JSONDecoder().decode([String: TrackingJSONValue].self, from: encoded),
           let data = try? JSONEncoder().encode(undecodableTracking.merging(records) { _, valid in valid }) {
            defaults.set(data, forKey: "stockTracking")
        }
        trackingStorageNotice = !undecodableTracking.isEmpty
            ? "部分持仓配置无法读取，原数据已保留；请重新保存对应股票。"
            : backedUpCorruptTracking ? "持仓配置无法读取，原数据已本地备份；请核对并重新录入。" : nil
    }

    func start() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateActivity()
        refresh()
    }

    func saveSymbols(_ text: String) throws {
        let values = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : try StockSymbol.parseList(text)
        applySymbols(values)
    }

    func addSymbols(_ text: String) throws {
        let added = try StockSymbol.parseList(text)
        let merged = try StockSymbol.parseList((symbols + added).map(\.id).joined(separator: ","))
        applySymbols(merged)
    }

    func removeSymbol(_ symbol: StockSymbol) {
        applySymbols(symbols.filter { $0 != symbol })
    }

    private func applySymbols(_ values: [StockSymbol]) {
        request?.cancel()
        request = nil
        isRefreshing = false
        symbols = values
        defaults.set(codeText, forKey: "symbols")
        let ids = Set(values.map(\.id))
        quotes = quotes.filter { ids.contains($0.key) }
        tracking = tracking.filter { ids.contains($0.key) }
        invalidTracking = invalidTracking.filter { ids.contains($0.key) }
        undecodableTracking = undecodableTracking.filter { ids.contains($0.key) }
        priceAlerts = priceAlerts.filter { ids.contains($0.key) }
        if let expandedSymbolID, !ids.contains(expandedSymbolID) { self.expandedSymbolID = nil }
        persistTracking()
        unavailable = []
        lastReceipt = nil
        errorMessage = nil
        if values.isEmpty {
            quotes = [:]
        }
        updateActivity()
        refresh()
    }

    func suspend() {
        suspended = true
        request?.cancel()
        request = nil
        isRefreshing = false
        updateActivity()
    }

    func resume() {
        suspended = false
        updateActivity()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suspend()
    }

    private func updateActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if !symbols.isEmpty && !suspended {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "用户指定的桌面行情每3秒刷新"
            )
        }
    }

    func refresh() {
        guard !suspended, !symbols.isEmpty, !isRefreshing else { return }
        let requested = symbols
        isRefreshing = true
        if isPreview {
            print("request \(Date().timeIntervalSince1970) \(requested.map(\.id).joined(separator: ","))")
            fflush(stdout)
        }
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let incoming = try await client.fetch(requested)
                guard !Task.isCancelled else { return }
                receive(incoming, requested: requested, at: Date())
                if isPreview {
                    let values = requested.compactMap { symbol -> String? in
                        guard let q = incoming[symbol.id] else { return nil }
                        return "\(symbol.id)=\(q.name),price:\(q.price),volumeLots:\(q.volumeLots),amountYuan:\(q.amountYuan),quote:\(q.timestamp.timeIntervalSince1970)"
                    }
                    print("received \(Date().timeIntervalSince1970) \(values.joined(separator: " | "))")
                    fflush(stdout)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if isPreview {
                    print("failure \(Date().timeIntervalSince1970) \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
            isRefreshing = false
            request = nil
        }
    }

    func receive(_ incoming: [String: Quote], requested: [StockSymbol], at receipt: Date) {
        let current = Set(symbols.map(\.id))
        let requestedIDs = Set(requested.map(\.id)).intersection(current)
        var accepted: [String: Quote] = [:]
        for (id, quote) in incoming where requestedIDs.contains(id) {
            guard quote.timestamp <= receipt.addingTimeInterval(5),
                  quotes[id].map({ quote.timestamp >= $0.timestamp }) ?? true else { continue }
            accepted[id] = quote
            quotes[id] = quote
        }
        unavailable.subtract(requestedIDs)
        unavailable.formUnion(requestedIDs.subtracting(accepted.keys))
        lastReceipt = receipt
        errorMessage = nil
        evaluateAlerts(accepted, now: receipt)
    }
}

enum DisplayFormat {
    static let chinaTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static let receiptTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func magnitude(_ value: Double, unit: String) -> String {
        if value >= 100_000_000 { return String(format: "%.2f亿%@", value / 100_000_000, unit) }
        if value >= 10_000 { return String(format: "%.2f万%@", value / 10_000, unit) }
        return String(format: "%.0f%@", value, unit)
    }
}

struct QuoteRow: View {
    let symbol: StockSymbol
    let quote: Quote?
    let failed: Bool
    let unavailable: Bool
    let configuration: StockTracking
    let invalidConfiguration: StockTracking?
    let isExpanded: Bool
    let alertMessage: String?
    let notificationNotice: String?
    let commissionRate: String
    let configure: () -> Void
    let save: (String, String, String, String, Bool, String) throws -> Void
    let rearm: () -> Void
    let remove: () -> Void

    private var profit: PositionProfit? { quote.flatMap { configuration.profit(at: $0.price) } }

    private var profitColor: Color {
        guard let profit else { return .secondary }
        return profit.amount > 0 ? Color(red: 0.85, green: 0.19, blue: 0.24)
            : profit.amount < 0 ? Color(red: 0.06, green: 0.59, blue: 0.38) : .primary
    }

    private var movement: Color {
        guard let quote else { return .secondary }
        return quote.change > 0 ? Color(red: 0.85, green: 0.19, blue: 0.24)
            : quote.change < 0 ? Color(red: 0.06, green: 0.59, blue: 0.38) : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Button(action: configure) {
                        HStack(spacing: 3) {
                            Text(quote?.name ?? symbol.code)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击名称展开或收起持仓与价格提醒")
                    .accessibilityLabel("\(isExpanded ? "收起" : "设置")\(symbol.code)持仓和提醒")
                    if failed || unavailable {
                        Text(quote == nil ? "无行情" : "上次数据")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    } else if invalidConfiguration != nil {
                        Text("配置异常").font(.system(size: 9)).foregroundStyle(.orange)
                    } else if configuration.purchaseAmountYuan != nil {
                        Text("费用预估").font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(quote.map { String(format: "%.2f", $0.price) } ?? "—")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(quote.map { String(format: "%+.2f  %+.2f%%", $0.change, $0.changePercent) } ?? "等待行情")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(movement)
            }
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(symbol.id.uppercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Button(action: remove) { Image(systemName: "xmark.circle") }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .help("删除这只股票")
                            .accessibilityLabel("删除\(symbol.code)")
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    metric("量比", value: quote.flatMap(\.volumeRatio).map { String(format: "%.2f", $0) } ?? "—")
                        .help("腾讯行情源量比，单位为倍")
                    metric("振幅", value: quote.flatMap(\.amplitudePercent).map { String(format: "%.2f%%", $0) } ?? "—")
                        .help("腾讯行情源日内振幅，单位为百分比")
                }
                HStack(spacing: 10) {
                    metric("成交量", value: quote.map { DisplayFormat.magnitude($0.volumeLots, unit: "手") } ?? "—")
                    metric("换手率", value: quote.flatMap(\.turnoverPercent).map { String(format: "%.2f%%", $0) } ?? "—")
                    metric("成交额", value: quote.map { DisplayFormat.magnitude($0.amountYuan, unit: "元") } ?? "—")
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            if configuration.hasPosition {
                HStack(spacing: 10) {
                    metric("成本", value: configuration.costPrice.map { String(format: "%.3f", $0) } ?? "—")
                        .help(configuration.totalCostYuan != nil
                              ? "\(configuration.quantity ?? 0)股；含费总成本\(configuration.totalCostText)元；单股成本自动计算"
                              : "\(configuration.quantity ?? 0)股；原手动成本，总成本\(configuration.totalCostText)元为估算")
                    metric("浮盈亏", value: profit?.amountText ?? "—")
                        .foregroundStyle(profitColor)
                    metric("盈亏率", value: profit.map { String(format: "%+.2f%%", $0.percent) } ?? "—")
                        .foregroundStyle(profitColor)
                }
                .font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                .help(configuration.purchaseAmountYuan != nil
                      ? "费用按单笔买入委托及设置的佣金率预估；费用落账后可切换为实际含费总成本"
                      : configuration.totalCostYuan != nil
                      ? "浮盈亏＝最新可用报价×持仓股数−含费总成本；不再另扣手续费"
                      : "原配置仍按单股成本×股数估算；可点击名称填写含费总成本，避免单股成本舍入偏差")
            }
            if configuration.hasAlerts {
                HStack(spacing: 6) {
                    Image(systemName: configuration.hasTriggeredAlerts ? "bell.fill" : "bell")
                    if let upper = configuration.upperPrice {
                        Text("≥\(String(format: "%.2f", upper)) \(configuration.upperTriggered ? "已提醒" : "待触达")")
                    }
                    if let lower = configuration.lowerPrice {
                        Text("≤\(String(format: "%.2f", lower)) \(configuration.lowerTriggered ? "已提醒" : "待触达")")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10)).lineLimit(1)
                .foregroundStyle(configuration.hasTriggeredAlerts ? Color.orange : Color.secondary)
                .help(alertMessage ?? "只有设置后产生的30秒内报价可以触发；每个条件只提醒一次")
            }
            if isExpanded {
                VStack(spacing: 5) {
                    Divider().opacity(0.6)
                    TrackingEditor(symbol: symbol, configuration: invalidConfiguration ?? configuration,
                                   commissionRate: commissionRate,
                                   notificationNotice: invalidConfiguration != nil
                                       ? "保存的配置不合法，提醒已暂停；请修正后保存。" : notificationNotice,
                                   save: save, rearm: rearm)
                        .frame(height: 214, alignment: .top)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(height: quoteRowHeight + (configuration.hasPosition ? 18 : 0)
               + (configuration.hasAlerts ? 18 : 0) + (isExpanded ? trackingEditorHeight : 0))
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(title).frame(width: 30, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

struct WidgetView: View {
    @ObservedObject var store: QuoteStore
    let transparency: () -> Void
    let add: () -> Void
    let pin: () -> Void
    let autoHide: () -> Void
    let hide: () -> Void
    let configure: (StockSymbol) -> Void
    @State private var newCode = ""
    @State private var additionError: String?
    @FocusState private var codeFocused: Bool

    private var status: String {
        if let additionError { return additionError }
        if let notice = store.trackingStorageNotice { return notice }
        if store.symbols.isEmpty { return "添加股票后，每3秒自动刷新" }
        let quoteTime = store.quotes.values.map(\.timestamp).min()
        if store.errorMessage != nil {
            return quoteTime.map { "连接失败 · 上次行情 \(DisplayFormat.chinaTime.string(from: $0))" }
                ?? "连接失败 · 自动重试"
        }
        if !store.unavailable.isEmpty { return "部分股票无可用行情 · 自动刷新" }
        if !store.invalidTracking.isEmpty { return "持仓或提醒配置异常 · 点击股票名称修正" }
        if let quoteTime {
            return "行情 \(DisplayFormat.chinaTime.string(from: quoteTime)) · 3秒刷新"
        }
        if let date = store.lastReceipt {
            return "请求成功 \(DisplayFormat.receiptTime.string(from: date)) · 3秒刷新"
        }
        return "正在连接行情源…"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if store.isAddingStock {
                    TextField("股票代码，回车追加", text: $newCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($codeFocused)
                        .accessibilityLabel("追加股票代码")
                        .onSubmit(addInline)
                        .onExitCommand { store.isAddingStock = false }
                        .onChange(of: newCode) { _ in additionError = nil }
                        .onAppear {
                            DispatchQueue.main.async {
                                if store.isAddingStock { codeFocused = true }
                            }
                        }
                        .frame(maxWidth: .infinity)
                } else if !store.isAdjustingTransparency {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(store.isPreview ? "A股行情 · 测试预览" : "A股桌面行情")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .overlay(WindowDraggingArea())
                }
                toolButton(store.isAddingStock ? "xmark" : "plus",
                           help: store.isAddingStock ? "收起输入框" : "追加股票") {
                    if store.isAddingStock { store.isAddingStock = false }
                    else { add() }
                }
                toolButton(store.isPinned ? "pin.fill" : "pin", help: store.isPinned ? "取消置顶" : "置顶", selected: store.isPinned, action: pin)
                toolButton("sidebar.right", help: store.autoHideEnabled ? "关闭右侧吸附隐藏" : "开启右侧吸附隐藏",
                           selected: store.autoHideEnabled, action: autoHide)
                if store.isAdjustingTransparency {
                    HStack(spacing: 6) {
                        Slider(value: $store.backgroundTransparency, in: 0...1)
                            .accessibilityLabel("背景透明度")
                            .help("0%毛玻璃，100%全透明；拖动即时生效并自动保存")
                        Text("\(Int((store.backgroundTransparency * 100).rounded()))%")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }
                toolButton(store.isAdjustingTransparency ? "xmark" : "gearshape",
                           help: store.isAdjustingTransparency ? "收起透明度滑条" : "调整背景透明度",
                           action: transparency)
                toolButton("minus", help: "隐藏浮窗（菜单栏可重新显示）", action: hide)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider().opacity(0.6)
            if store.symbols.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("添加你关注的A股")
                        .font(.system(size: 15, weight: .medium))
                    Text("输入股票代码，即可查看量价信息")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("添加股票", action: add)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 198)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.symbols) { symbol in
                            QuoteRow(symbol: symbol, quote: store.quotes[symbol.id],
                                     failed: store.errorMessage != nil,
                                     unavailable: store.unavailable.contains(symbol.id),
                                     configuration: store.tracking[symbol.id] ?? StockTracking(),
                                     invalidConfiguration: store.invalidTracking[symbol.id],
                                     isExpanded: store.expandedSymbolID == symbol.id,
                                     alertMessage: store.priceAlerts[symbol.id],
                                     notificationNotice: store.notificationNotice,
                                     commissionRate: store.buyCommissionRate,
                                     configure: { configure(symbol) },
                                     save: { amount, quantity, upper, lower, estimateFees, commissionRate in
                                         try store.savePosition(for: symbol, amount: amount, quantity: quantity, upper: upper, lower: lower,
                                                                estimateFees: estimateFees, commissionRate: commissionRate)
                                         store.expandedSymbolID = nil
                                     },
                                     rearm: { store.rearmAlerts(for: symbol) },
                                     remove: { store.removeSymbol(symbol) })
                            if symbol != store.symbols.last { Divider().padding(.horizontal, 16).opacity(0.6) }
                        }
                    }
                }
                .frame(height: store.listHeight)
            }
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                Circle()
                    .fill(additionError != nil || store.errorMessage != nil || !store.unavailable.isEmpty || !store.invalidTracking.isEmpty || store.trackingStorageNotice != nil ? Color.orange
                          : store.lastReceipt != nil ? Color.green : Color.secondary)
                    .frame(width: 5, height: 5)
                Text(status).lineLimit(1)
                Spacer(minLength: 0)
                let total = store.totalPositionProfit
                Text("总盈亏 \(total.map { yuanText($0, showSign: $0 != 0) } ?? "—")")
                    .monospacedDigit()
                    .foregroundStyle(total.map { $0 > 0 ? Color.red : $0 < 0 ? Color.green : Color.secondary } ?? Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    .help("单位：元。合计已填写持仓的股票，按各卡片最新可用报价计算；无持仓不计入。缺少持仓报价或配置异常时显示—，总成本已含费用，不重复扣费。")
                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing || store.symbols.isEmpty)
                .help("立即刷新")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 31)
            .help(additionError ?? store.trackingStorageNotice ?? store.errorMessage ?? "腾讯公开行情 · 成交量与成交额为当日累计；底部行情时间取列表最早一条，北京时间。最近接收：\(store.lastReceipt.map { DisplayFormat.chinaTime.string(from: $0) } ?? "—")")
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .onExitCommand {
            store.isAddingStock = false
            store.isAdjustingTransparency = false
            store.expandedSymbolID = nil
        }
        .onChange(of: store.isAddingStock) { adding in
            if !adding { codeFocused = false; newCode = ""; additionError = nil }
        }
    }

    private func addInline() {
        do {
            try store.addSymbols(newCode)
            newCode = ""
            additionError = nil
            codeFocused = true
        } catch { additionError = error.localizedDescription }
    }

    private func toolButton(_ symbol: String, help: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var store: QuoteStore!
    private var panel: DesktopPanel!
    private var glassView: NSVisualEffectView?
    private var statusItem: NSStatusItem!
    private var pinItem: NSMenuItem!
    private var autoHideItems: [NSMenuItem] = []
    private var subscriptions: [AnyCancellable] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previewDomain: String?
    private var notificationCenter: UNUserNotificationCenter?
    private var edgeDock: EdgeDockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let preview = arguments.firstIndex(of: "--preview").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        let defaults: UserDefaults
        if preview != nil {
            let domain = "cn.local.AShareDesktop.preview.\(UUID().uuidString)"
            previewDomain = domain
            defaults = UserDefaults(suiteName: domain)!
        } else { defaults = .standard }
        store = QuoteStore(defaults: defaults, preview: preview)
        if !store.isPreview {
            notificationCenter = UNUserNotificationCenter.current()
            notificationCenter?.delegate = self
        }
        store.onPriceAlert = { [weak self] alert in self?.postPriceAlert(alert) }
        store.onAlertSetup = { [weak self] in self?.prepareNotifications() }
        createApplicationMenu()
        createMenu()
        createPanel()
        subscriptions.append(store.$symbols.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        })
        subscriptions.append(store.$backgroundTransparency.sink { [weak self] value in
            self?.applyTransparency(value)
        })
        subscriptions.append(store.$tracking.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        })
        subscriptions.append(store.$expandedSymbolID.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        })
        if store.tracking.values.contains(where: \.hasAlerts) { prepareNotifications() }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.suspend() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.resume() }
        })
        store.start()
        panel.orderFrontRegardless()
        edgeDock?.restore()
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "A股桌面行情")
        statusItem.button?.toolTip = "A股桌面行情"
        let menu = NSMenu()
        addItem("显示浮窗", action: #selector(showPanel), to: menu)
        addItem("隐藏浮窗", action: #selector(hidePanel), to: menu)
        menu.addItem(.separator())
        addItem("添加股票…", action: #selector(addStock), to: menu)
        addItem("背景透明度", action: #selector(toggleTransparency), to: menu)
        addItem("启用提醒通知", action: #selector(prepareNotifications), to: menu)
        addItem("立即刷新", action: #selector(refresh), to: menu)
        pinItem = addItem("浮窗置顶", action: #selector(togglePin), to: menu)
        pinItem.state = store.isPinned ? .on : .off
        addAutoHideItem(to: menu)
        menu.addItem(.separator())
        addItem("退出A股桌面行情", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
    }

    private func createApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addAutoHideItem(to: appMenu)
        addItem("启用提醒通知", action: #selector(prepareNotifications), to: appMenu)
        addItem("退出A股桌面行情", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"),
                                     ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addAutoHideItem(to menu: NSMenu) {
        let item = addItem("右侧自动吸附隐藏", action: #selector(toggleAutoHide), to: menu)
        item.state = store.autoHideEnabled ? .on : .off
        autoHideItems.append(item)
    }

    private func createPanel() {
        panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 280),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "A股桌面行情"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = store.isPinned ? .floating : .normal
        let surface = DesktopHoverView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        // WindowServer skips fully transparent pixels for mouse hit testing.
        // Keep this subtle rounded hit surface independent of the glass opacity.
        surface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glassView = glass
        glass.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(glass)
        let host = TransparentHostingView(rootView: WidgetView(store: store,
                                                               transparency: { [weak self] in self?.toggleTransparency() },
                                                               add: { [weak self] in self?.addStock() },
                                                               pin: { [weak self] in self?.togglePin() },
                                                               autoHide: { [weak self] in self?.toggleAutoHide() },
                                                               hide: { [weak self] in self?.hidePanel() },
                                                               configure: { [weak self] symbol in self?.toggleTracking(symbol) }))
        host.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(host)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            glass.topAnchor.constraint(equalTo: surface.topAnchor),
            glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            host.topAnchor.constraint(equalTo: surface.topAnchor),
            host.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        panel.contentView = surface
        applyTransparency(store.backgroundTransparency)
        resizePanel()
        if let x = store.defaults.object(forKey: "positionX") as? Double,
           let y = store.defaults.object(forKey: "positionY") as? Double {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            keepOnScreen()
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24,
                                         y: frame.maxY - panel.frame.height - 24))
        }
        panel.delegate = self
        edgeDock = EdgeDockController(panel: panel, surface: surface, defaults: store.defaults,
                                     enabled: store.autoHideEnabled) { [weak self] in
            guard let store = self?.store else { return false }
            return store.isAddingStock || store.isAdjustingTransparency || store.expandedSymbolID != nil
        }
    }

    private func resizePanel() {
        guard panel != nil else { return }
        let rowsHeight = store.listHeight
        let size = NSSize(width: 370, height: 81 + rowsHeight)
        if let edgeDock { edgeDock.resize(to: size) }
        else {
            var frame = panel.frame
            let top = frame.maxY
            frame.size = size
            frame.origin.y = top - frame.height
            panel.setFrame(frame, display: true)
            keepOnScreen()
        }
        updateWindowMask()
    }

    private func applyTransparency(_ value: Double) {
        glassView?.alphaValue = 1 - value
        glassView?.isHidden = value >= 1
        panel?.invalidateShadow()
    }

    private func updateWindowMask() {
        guard let panel, let glassView else { return }
        let size = panel.frame.size
        let mask = NSImage(size: size)
        mask.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 16, yRadius: 16).fill()
        mask.unlockFocus()
        glassView.maskImage = mask
        panel.invalidateShadow()
    }

    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = max(visible.minX, min(origin.x, visible.maxX - panel.frame.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        edgeDock?.userMovedWindow()
    }

    @objc private func showPanel() { edgeDock?.show() }
    @objc private func hidePanel() { edgeDock?.hide() }
    @objc private func refresh() { store.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func addStock() {
        edgeDock?.show()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.isAdjustingTransparency = false
        store.expandedSymbolID = nil
        store.isAddingStock = true
    }

    @objc private func togglePin() {
        store.isPinned.toggle()
        panel.level = store.isPinned ? .floating : .normal
        pinItem.state = store.isPinned ? .on : .off
        edgeDock?.show()
    }

    @objc private func toggleAutoHide() {
        store.autoHideEnabled.toggle()
        for item in autoHideItems { item.state = store.autoHideEnabled ? .on : .off }
        edgeDock?.setEnabled(store.autoHideEnabled)
    }

    @objc private func toggleTransparency() {
        edgeDock?.show()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.isAddingStock = false
        store.isAdjustingTransparency.toggle()
    }

    private func toggleTracking(_ symbol: StockSymbol) {
        edgeDock?.show()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.isAddingStock = false
        store.isAdjustingTransparency = false
        store.expandedSymbolID = store.expandedSymbolID == symbol.id ? nil : symbol.id
    }

    @objc private func prepareNotifications() {
        Task { @MainActor [weak self] in
            guard let self, let notificationCenter = self.notificationCenter else { return }
            let settings = await notificationCenter.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
                    store.notificationNotice = granted ? nil
                            : "系统通知未开启；触达时仍会在浮窗标记并响铃。"
                } catch {
                    store.notificationNotice = "系统通知暂不可用；触达时仍会在浮窗标记并响铃。"
                }
            } else {
                store.notificationNotice = settings.authorizationStatus == .denied
                    ? "系统通知未开启；触达时仍会在浮窗标记并响铃。" : nil
            }
        }
    }

    private func postPriceAlert(_ alert: PriceAlert) {
        guard let notificationCenter else { return }
        NSSound.beep()
        let content = UNMutableNotificationContent()
        content.title = "\(alert.name) · \(alert.direction.title)"
        content.subtitle = "\(alert.symbolID.uppercased()) · \(DisplayFormat.chinaTime.string(from: alert.timestamp))"
        content.body = alert.message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationCenter.add(request) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.store.notificationNotice = "系统通知发送失败；浮窗触达标记和响铃仍有效。"
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                          willPresent notification: UNNotification,
                                          withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        edgeDock?.stop()
        store.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let previewDomain { store.defaults.removePersistentDomain(forName: previewDomain) }
    }
}
