import SwiftUI

struct TrackingEditor: View {
    let symbol: StockSymbol
    let configuration: StockTracking
    let notificationNotice: String?
    let save: (String, String, String, String, Bool, String) throws -> Void
    let rearm: () -> Void
    @State private var totalCost: String
    @State private var estimateFees: Bool
    @State private var commissionRate: String
    @State private var quantity: String
    @State private var upper: String
    @State private var lower: String
    @State private var error: String?
    @FocusState private var totalCostFocused: Bool

    init(symbol: StockSymbol, configuration: StockTracking, commissionRate: String, notificationNotice: String?,
         save: @escaping (String, String, String, String, Bool, String) throws -> Void,
         rearm: @escaping () -> Void) {
        self.symbol = symbol
        self.configuration = configuration
        self.notificationNotice = notificationNotice
        self.save = save
        self.rearm = rearm
        // A saved fee-inclusive cost must never become the ordinary purchase-amount input.
        _totalCost = State(initialValue: configuration.purchaseAmountYuan.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _estimateFees = State(initialValue: true)
        _commissionRate = State(initialValue: configuration.purchaseCommissionRate.map { NSDecimalNumber(decimal: $0).stringValue } ?? commissionRate)
        _quantity = State(initialValue: configuration.quantity.map(String.init) ?? "")
        _upper = State(initialValue: configuration.upperPrice.map { String($0) } ?? "")
        _lower = State(initialValue: configuration.lowerPrice.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(estimateFees ? "买入金额自动加费" : "含费总成本 · 不再加费")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(estimateFees ? Color.secondary : Color.orange)
                Spacer(minLength: 2)
                Button(estimateFees ? "校准含费总成本" : "返回买入金额") {
                    estimateFees.toggle()
                    totalCost = estimateFees
                        ? configuration.purchaseAmountYuan.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
                        : configuration.totalCostText
                    error = nil
                }
                .buttonStyle(.borderless).font(.system(size: 10))
                .accessibilityLabel("\(symbol.code)\(estimateFees ? "校准含费总成本" : "返回买入金额")")
            }
            .frame(height: 20)
            HStack(spacing: 12) {
                field(estimateFees ? "买入金额 · 不含费/元" : "总成本 · 已含费/元", placeholder: "未设置", text: $totalCost,
                      label: estimateFees ? "买入成交金额" : "持仓总成本")
                    .focused($totalCostFocused)
                    .help(estimateFees ? "输入单笔买入委托的成交金额，不含手续费；费用自动预估"
                          : "输入持仓对应的买入金额加已发生费用；不再另外扣费")
                field("持仓 · 股", placeholder: "未设置", text: $quantity, label: "持仓股数")
            }
            HStack(spacing: 12) {
                field("上方提醒 · ≥", placeholder: "留空关闭", text: $upper, label: "上方提醒价")
                field("下方提醒 · ≤", placeholder: "留空关闭", text: $lower, label: "下方提醒价")
            }
            if estimateFees {
                HStack(spacing: 5) {
                    Text("佣金 · 万分比").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("2.5", text: $commissionRate)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        .frame(width: 46).accessibilityLabel("买入佣金万分比")
                    Text("最低5元").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text("费用预估 \(feeEstimate?.feesText ?? "—")元")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.orange)
                }
            } else {
                Text("按实际含费总成本计算，不再另外扣费")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 20)
            }
            HStack {
                Button(estimateFees ? "保存" : "保存总成本", action: saveValues)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("保存\(symbol.code)持仓和提醒")
                if configuration.hasTriggeredAlerts {
                    Button("重新启用提醒", action: rearm)
                        .accessibilityLabel("重新启用\(symbol.code)提醒")
                        .help("保留已保存的提醒价，等待新的报价触达")
                }
                Spacer(minLength: 0)
                Text("留空关闭对应项目").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Text(error ?? notificationNotice ?? entryNotice)
                .font(.system(size: 10))
                .foregroundStyle(error != nil || notificationNotice != nil ? Color.orange : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { totalCostFocused = true }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("\(symbol.code)\(label)")
        }
        .frame(maxWidth: .infinity)
    }

    private func saveValues() {
        do { try save(totalCost, quantity, upper, lower, estimateFees, commissionRate); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private var feeEstimate: BuyFeeEstimate? {
        try? BuyFeeEstimate.calculate(amount: totalCost, commissionRate: commissionRate, symbol: symbol)
    }

    private var entryNotice: String {
        if !estimateFees { return "仅填写已含手续费的总成本；保存后不额外加费。" }
        if let feeEstimate {
            return "含费成本\(feeEstimate.totalCostText)元；按单笔预估，实际以交割单为准。"
        }
        if configuration.hasPosition && configuration.purchaseAmountYuan == nil {
            let costLabel = configuration.totalCostYuan == nil ? "原总成本估算" : "已保存总成本"
            return "\(costLabel)\(configuration.totalCostText)元；修改持仓请填买入金额，仅改提醒可直接保存。"
        }
        return "输入不含手续费的买入金额；程序自动加上买入费用。"
    }
}
