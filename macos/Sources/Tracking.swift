import Foundation

struct StockTracking: Codable, Equatable {
    var costPrice: Double?
    var quantity: Int?
    var upperPrice: Double?
    var lowerPrice: Double?
    var upperTriggered: Bool
    var lowerTriggered: Bool
    var armedAt: Date?

    init(costPrice: Double? = nil, quantity: Int? = nil,
         upperPrice: Double? = nil, lowerPrice: Double? = nil,
         upperTriggered: Bool = false, lowerTriggered: Bool = false,
         armedAt: Date? = nil) {
        self.costPrice = costPrice
        self.quantity = quantity
        self.upperPrice = upperPrice
        self.lowerPrice = lowerPrice
        self.upperTriggered = upperTriggered
        self.lowerTriggered = lowerTriggered
        self.armedAt = armedAt
    }

    var hasPosition: Bool { costPrice != nil && quantity != nil }
    var hasAlerts: Bool { upperPrice != nil || lowerPrice != nil }
    var hasTriggeredAlerts: Bool { upperTriggered || lowerTriggered }

    static func parse(cost: String, quantity: String, upper: String, lower: String) throws -> StockTracking {
        let costText = cost.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityText = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard costText.isEmpty == quantityText.isEmpty else {
            throw TrackingError.invalidInput("成本价和持仓股数需同时填写，或同时留空。")
        }
        let costPrice = try price(costText, label: "成本价")
        var quantityValue: Int?
        if !quantityText.isEmpty {
            guard quantityText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(quantityText), value > 0 else {
                throw TrackingError.invalidInput("持仓股数请输入正整数，单位为股。")
            }
            quantityValue = value
            guard let costPrice, (costPrice * Double(value)).isFinite else {
                throw TrackingError.invalidInput("总成本过大，请检查成本价和持仓股数。")
            }
        }
        let upperPrice = try price(upper, label: "上方提醒价")
        let lowerPrice = try price(lower, label: "下方提醒价")
        if let upperPrice, let lowerPrice, lowerPrice >= upperPrice {
            throw TrackingError.invalidInput("下方提醒价需小于上方提醒价。")
        }
        return StockTracking(costPrice: costPrice, quantity: quantityValue,
                             upperPrice: upperPrice, lowerPrice: lowerPrice)
    }

    func validated() throws -> StockTracking {
        var value = try Self.parse(cost: costPrice.map { String($0) } ?? "",
                                   quantity: quantity.map(String.init) ?? "",
                                   upper: upperPrice.map { String($0) } ?? "",
                                   lower: lowerPrice.map { String($0) } ?? "")
        value.upperTriggered = value.upperPrice != nil && upperTriggered
        value.lowerTriggered = value.lowerPrice != nil && lowerTriggered
        value.armedAt = value.hasAlerts ? armedAt : nil
        return value
    }

    func profit(at price: Double) -> PositionProfit? {
        guard let costPrice, let quantity, costPrice.isFinite, costPrice > 0,
              quantity > 0, price.isFinite, price > 0 else { return nil }
        let cost = costPrice * Double(quantity)
        let value = price * Double(quantity)
        let amount = value - cost
        let percent = ((price - costPrice) / costPrice) * 100
        guard cost.isFinite, value.isFinite, amount.isFinite, percent.isFinite else { return nil }
        return PositionProfit(amount: amount, percent: percent)
    }

    mutating func takeAlerts(for quote: Quote, now: Date) -> [PriceAlert] {
        let age = now.timeIntervalSince(quote.timestamp)
        guard age >= -5, age <= 30, quote.price.isFinite, quote.price > 0,
              armedAt.map({ quote.timestamp >= $0 }) ?? true else { return [] }
        var alerts: [PriceAlert] = []
        if let upperPrice, upperPrice.isFinite, upperPrice > 0,
           !upperTriggered, quote.price >= upperPrice {
            upperTriggered = true
            alerts.append(PriceAlert(symbolID: quote.symbol.id, name: quote.name,
                                     direction: .upper, price: quote.price,
                                     threshold: upperPrice, timestamp: quote.timestamp))
        }
        if let lowerPrice, lowerPrice.isFinite, lowerPrice > 0,
           !lowerTriggered, quote.price <= lowerPrice {
            lowerTriggered = true
            alerts.append(PriceAlert(symbolID: quote.symbol.id, name: quote.name,
                                     direction: .lower, price: quote.price,
                                     threshold: lowerPrice, timestamp: quote.timestamp))
        }
        return alerts
    }

    private static func price(_ text: String, label: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite, value > 0 else {
            throw TrackingError.invalidInput("\(label)请输入大于0的有效价格。")
        }
        return value
    }
}

struct PositionProfit {
    let amount: Double
    let percent: Double
}

enum AlertDirection {
    case upper
    case lower

    var title: String {
        switch self {
        case .upper: "上方提醒"
        case .lower: "下方提醒"
        }
    }
}

struct PriceAlert {
    let symbolID: String
    let name: String
    let direction: AlertDirection
    let price: Double
    let threshold: Double
    let timestamp: Date

    var message: String {
        "\(name)\(direction == .upper ? "升至" : "跌至")\(String(format: "%.2f", price))，\(direction.title)价\(String(format: "%.2f", threshold))。"
    }
}

enum TrackingError: LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        }
    }
}
