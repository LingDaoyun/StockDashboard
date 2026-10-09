import SwiftUI

struct TrackingEditor: View {
    let symbol: StockSymbol
    let configuration: StockTracking
    let notificationNotice: String?
    let save: (String, String, String, String) throws -> Void
    let rearm: () -> Void
    @State private var cost: String
    @State private var quantity: String
    @State private var upper: String
    @State private var lower: String
    @State private var error: String?
    @FocusState private var costFocused: Bool

    init(symbol: StockSymbol, configuration: StockTracking, notificationNotice: String?,
         save: @escaping (String, String, String, String) throws -> Void,
         rearm: @escaping () -> Void) {
        self.symbol = symbol
        self.configuration = configuration
        self.notificationNotice = notificationNotice
        self.save = save
        self.rearm = rearm
        _cost = State(initialValue: configuration.costPrice.map { String($0) } ?? "")
        _quantity = State(initialValue: configuration.quantity.map(String.init) ?? "")
        _upper = State(initialValue: configuration.upperPrice.map { String($0) } ?? "")
        _lower = State(initialValue: configuration.lowerPrice.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                field("成本 · 元/股", placeholder: "未设置", text: $cost, label: "成本价")
                    .focused($costFocused)
                field("持仓 · 股", placeholder: "未设置", text: $quantity, label: "持仓股数")
            }
            HStack(spacing: 12) {
                field("上方提醒 · ≥", placeholder: "留空关闭", text: $upper, label: "上方提醒价")
                field("下方提醒 · ≤", placeholder: "留空关闭", text: $lower, label: "下方提醒价")
            }
            HStack {
                Button("保存", action: saveValues)
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
            Text(error ?? notificationNotice ?? "浮盈亏按成本与股数估算；每个提醒价只提示一次。")
                .font(.system(size: 10))
                .foregroundStyle(error != nil || notificationNotice != nil ? Color.orange : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { costFocused = true }
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
        do { try save(cost, quantity, upper, lower); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
