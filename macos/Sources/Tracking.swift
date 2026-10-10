import Foundation

struct StockTracking: Codable, Equatable {
    var costPrice: Double?
    var quantity: Int?
    var totalCostYuan: Decimal?
    var purchaseAmountYuan: Decimal?
    var purchaseCommissionRate: Decimal?
    var upperPrice: Double?
    var lowerPrice: Double?
    var upperTriggered: Bool
    var lowerTriggered: Bool
    var armedAt: Date?

    init(costPrice: Double? = nil, quantity: Int? = nil,
         upperPrice: Double? = nil, lowerPrice: Double? = nil,
         upperTriggered: Bool = false, lowerTriggered: Bool = false,
         armedAt: Date? = nil, totalCostYuan: Decimal? = nil, purchaseAmountYuan: Decimal? = nil,
         purchaseCommissionRate: Decimal? = nil) {
        self.costPrice = costPrice
        self.quantity = quantity
        self.totalCostYuan = totalCostYuan
        self.purchaseAmountYuan = purchaseAmountYuan
        self.purchaseCommissionRate = purchaseCommissionRate
        self.upperPrice = upperPrice
        self.lowerPrice = lowerPrice
        self.upperTriggered = upperTriggered
        self.lowerTriggered = lowerTriggered
        self.armedAt = armedAt
    }

    var hasPosition: Bool { (costPrice != nil || totalCostYuan != nil) && quantity != nil }
    var hasAlerts: Bool { upperPrice != nil || lowerPrice != nil }
    var hasTriggeredAlerts: Bool { upperTriggered || lowerTriggered }

    var totalCostText: String {
        effectiveCostYuan.map { yuanText($0, showSign: false) } ?? ""
    }

    static func parse(cost: String, quantity: String, upper: String, lower: String, totalCost: String = "", purchaseAmount: String = "", purchaseCommissionRate: Decimal? = nil) throws -> StockTracking {
        let costText = cost.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityText = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        var costPrice = try price(costText, label: "成本价")
        let totalCostYuan = try totalCostAmount(totalCost)
        let purchaseAmountYuan = try totalCostAmount(purchaseAmount, label: "成交金额")
        var quantityValue: Int?
        if !quantityText.isEmpty {
            guard quantityText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(quantityText), value > 0 else {
                throw TrackingError.invalidInput("持仓股数请输入正整数，单位为股。")
            }
            quantityValue = value
            if let costPrice, !(costPrice * Double(value)).isFinite {
                throw TrackingError.invalidInput("总成本过大，请检查成本价和持仓股数。")
            }
        }
        guard (costPrice != nil || totalCostYuan != nil) == (quantityValue != nil) else {
            throw TrackingError.invalidInput("持仓总成本和持仓股数需同时填写，或同时留空。")
        }
        if let purchaseAmountYuan {
            guard let totalCostYuan, quantityValue != nil, purchaseAmountYuan <= totalCostYuan else {
                throw TrackingError.invalidInput("成交金额需与持仓总成本、股数一起保存，且不能大于持仓总成本。")
            }
        }
        if let purchaseCommissionRate {
            guard purchaseAmountYuan != nil, !purchaseCommissionRate.isNaN,
                  purchaseCommissionRate > 0, purchaseCommissionRate <= 30 else {
                throw TrackingError.invalidInput("预估佣金费率需与成交金额一起保存，且大于0、不超过万分之30。")
            }
        }
        if let totalCostYuan, let quantityValue {
            let average = NSDecimalNumber(decimal: totalCostYuan / Decimal(quantityValue)).doubleValue
            guard average.isFinite, average > 0 else {
                throw TrackingError.invalidInput("总成本过大，请检查持仓总成本和持仓股数。")
            }
            costPrice = average
        }
        let upperPrice = try price(upper, label: "上方提醒价")
        let lowerPrice = try price(lower, label: "下方提醒价")
        if let upperPrice, let lowerPrice, lowerPrice >= upperPrice {
            throw TrackingError.invalidInput("下方提醒价需小于上方提醒价。")
        }
        return StockTracking(costPrice: costPrice, quantity: quantityValue,
                             upperPrice: upperPrice, lowerPrice: lowerPrice,
                             totalCostYuan: totalCostYuan, purchaseAmountYuan: purchaseAmountYuan,
                             purchaseCommissionRate: purchaseCommissionRate)
    }

    func validated() throws -> StockTracking {
        var value = try Self.parse(cost: costPrice.map { String($0) } ?? "",
                                   quantity: quantity.map(String.init) ?? "",
                                   upper: upperPrice.map { String($0) } ?? "",
                                   lower: lowerPrice.map { String($0) } ?? "",
                                   totalCost: totalCostYuan.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
                                   purchaseAmount: purchaseAmountYuan.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
                                   purchaseCommissionRate: purchaseCommissionRate)
        value.upperTriggered = value.upperPrice != nil && upperTriggered
        value.lowerTriggered = value.lowerPrice != nil && lowerTriggered
        value.armedAt = value.hasAlerts ? armedAt : nil
        return value
    }

    func profit(at price: Double) -> PositionProfit? {
        guard let quantity, quantity > 0, price.isFinite, price > 0,
              var decimalPrice = Decimal(string: String(price), locale: Locale(identifier: "en_US_POSIX")),
              var cost = effectiveCostYuan else { return nil }
        var shares = Decimal(quantity)
        var value = Decimal()
        guard NSDecimalMultiply(&value, &decimalPrice, &shares, .plain) == .noError else { return nil }
        var unroundedAmount = Decimal()
        guard NSDecimalSubtract(&unroundedAmount, &value, &cost, .plain) == .noError else { return nil }
        var amount = Decimal()
        NSDecimalRound(&amount, &unroundedAmount, 2, .plain)
        let percent = NSDecimalNumber(decimal: (unroundedAmount / cost) * 100).doubleValue
        guard !amount.isNaN, percent.isFinite else { return nil }
        return PositionProfit(amount: amount, percent: percent)
    }

    private var effectiveCostYuan: Decimal? {
        guard let quantity, quantity > 0 else { return nil }
        if let totalCostYuan {
            guard (try? Self.totalCostAmount(NSDecimalNumber(decimal: totalCostYuan).stringValue)) == totalCostYuan else { return nil }
            return totalCostYuan
        }
        guard let costPrice, costPrice.isFinite, costPrice > 0,
              var cost = Decimal(string: String(costPrice), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var shares = Decimal(quantity)
        var total = Decimal()
        guard NSDecimalMultiply(&total, &cost, &shares, .plain) == .noError, total > 0 else { return nil }
        return total
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

    private static func totalCostAmount(_ text: String, label: String = "持仓总成本") throws -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"^(?:[0-9]+(?:\.[0-9]{1,2})?|\.[0-9]{1,2})$"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression),
              range == trimmed.startIndex..<trimmed.endIndex,
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0 else {
            throw TrackingError.invalidInput("\(label)请输入大于0、最多2位小数的金额，不支持科学记数法。")
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0].drop(while: { $0 == "0" }))
        let fraction = parts.count > 1 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let canonical = (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        guard NSDecimalNumber(decimal: value).stringValue == canonical else {
            throw TrackingError.invalidInput("\(label)过大，无法精确保存到分，请检查金额。")
        }
        return value
    }
}

struct PositionProfit {
    let amount: Decimal
    let percent: Double

    var amountText: String { yuanText(amount, showSign: true) }
}

func yuanText(_ value: Decimal, showSign: Bool) -> String {
    var value = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 2, .plain)
    guard !rounded.isNaN else { return "" }
    let magnitude = rounded < 0 ? -rounded : rounded
    let parts = NSDecimalNumber(decimal: magnitude).stringValue.split(separator: ".", omittingEmptySubsequences: false)
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    let sign = rounded < 0 ? "-" : showSign ? "+" : ""
    return sign + String(parts[0]) + "." + fraction.padding(toLength: 2, withPad: "0", startingAt: 0)
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
