import Foundation

/// Estimates one buy order. Separate orders can each incur the minimum commission.
struct BuyFeeEstimate {
    let purchaseAmountYuan: Decimal
    let commissionRatePerTenThousand: Decimal
    let commissionYuan: Decimal
    let transferFeeYuan: Decimal
    let totalFeesYuan: Decimal
    let totalCostYuan: Decimal

    var feesText: String { Self.moneyText(totalFeesYuan) }
    var totalCostText: String { Self.moneyText(totalCostYuan) }

    static func calculate(amount: String, commissionRate: String, symbol: StockSymbol) throws -> BuyFeeEstimate {
        var purchase = try exactDecimal(amount, fractionLimit: 2,
                                        message: "买入成交金额请输入大于0、最多2位小数的金额。")
        var rate = try exactDecimal(commissionRate, fractionLimit: nil,
                                    message: "佣金费率请输入大于0且不超过30的万分比。")
        guard rate <= 30 else {
            throw BuyFeeError.invalidInput("佣金费率不能超过万分之30（3‰）。")
        }

        var fractionalRate = Decimal()
        var rawCommission = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&fractionalRate, &rate, -4, .plain) == .noError,
              NSDecimalMultiply(&rawCommission, &purchase, &fractionalRate, .plain) == .noError else {
            throw BuyFeeError.invalidInput("金额或费率过大，无法精确计算费用，请检查输入。")
        }
        var commission = roundedCents(max(rawCommission, 5))
        var transfer = Decimal.zero
        if symbol.market == "sh" {
            var rawTransfer = Decimal()
            guard NSDecimalMultiplyByPowerOf10(&rawTransfer, &purchase, -5, .plain) == .noError else {
                throw BuyFeeError.invalidInput("金额过大，无法精确计算过户费，请检查输入。")
            }
            transfer = roundedCents(rawTransfer)
        }

        var fees = Decimal()
        var total = Decimal()
        guard NSDecimalAdd(&fees, &commission, &transfer, .plain) == .noError,
              NSDecimalAdd(&total, &purchase, &fees, .plain) == .noError,
              !fees.isNaN, !total.isNaN else {
            throw BuyFeeError.invalidInput("总成本过大，无法精确保存到分，请检查金额。")
        }
        return BuyFeeEstimate(purchaseAmountYuan: purchase, commissionRatePerTenThousand: rate, commissionYuan: commission,
                              transferFeeYuan: transfer, totalFeesYuan: fees, totalCostYuan: total)
    }

    private static func exactDecimal(_ text: String, fractionLimit: Int?, message: String) throws -> Decimal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fraction = fractionLimit.map { "{1,\($0)}" } ?? "+"
        let pattern = "^(?:[0-9]+(?:\\.[0-9]\(fraction))?|\\.[0-9]\(fraction))$"
        guard let range = trimmed.range(of: pattern, options: .regularExpression),
              range == trimmed.startIndex..<trimmed.endIndex,
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0 else {
            throw BuyFeeError.invalidInput(message)
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0].drop(while: { $0 == "0" }))
        let fractional = parts.count > 1 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        let canonical = (integer.isEmpty ? "0" : integer) + (fractional.isEmpty ? "" : "." + fractional)
        guard NSDecimalNumber(decimal: value).stringValue == canonical else {
            throw BuyFeeError.invalidInput("金额或费率无法精确表示，请检查输入。")
        }
        return value
    }

    private static func roundedCents(_ value: Decimal) -> Decimal {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }

    private static func moneyText(_ value: Decimal) -> String {
        let parts = NSDecimalNumber(decimal: value).stringValue.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        return String(parts[0]) + "." + fraction.padding(toLength: 2, withPad: "0", startingAt: 0)
    }
}

enum BuyFeeError: LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        }
    }
}
