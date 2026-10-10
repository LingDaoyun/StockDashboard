import Foundation

@main
@MainActor
enum FeeTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do {
            try body()
            preconditionFailure(message)
        } catch {
            check(error is LocalizedError && !error.localizedDescription.isEmpty,
                  "非法输入应提供可显示的错误：\(message)")
        }
    }

    static func main() throws {
        let sh = StockSymbol(code: "600000", market: "sh")
        let sz = StockSymbol(code: "000001", market: "sz")
        let bj = StockSymbol(code: "920000", market: "bj")
        let shEstimate = try BuyFeeEstimate.calculate(amount: "40000", commissionRate: "2.5", symbol: sh)
        check(shEstimate.purchaseAmountYuan == 40000, "买入成交金额保留十进制金额")
        check(shEstimate.commissionRatePerTenThousand == Decimal(string: "2.5"), "单笔估算保留使用的佣金万分比")
        check(shEstimate.commissionYuan == 10, "万2.5佣金按成交金额计算")
        check(shEstimate.transferFeeYuan == Decimal(string: "0.40"), "沪市按成交金额十万分之一估算过户费")
        check(shEstimate.totalFeesYuan == Decimal(string: "10.40"), "总费用相加各项已按分取整的费用")
        check(shEstimate.totalCostYuan == Decimal(string: "40010.40"), "总成本为成交金额加买入费用")
        check(shEstimate.feesText == "10.40" && shEstimate.totalCostText == "40010.40", "费用与总成本显示两位小数且不含符号")

        let szEstimate = try BuyFeeEstimate.calculate(amount: "10000", commissionRate: "2.5", symbol: sz)
        check(szEstimate.commissionYuan == 5, "单笔佣金不足5元按5元估算")
        check(szEstimate.transferFeeYuan == 0 && szEstimate.totalFeesYuan == 5, "深圳公开收费口径不另列过户费，买入不收印花税")
        check(szEstimate.totalCostText == "10005.00", "最低佣金计入总成本")
        let bjEstimate = try BuyFeeEstimate.calculate(amount: "10000", commissionRate: "2.5", symbol: bj)
        check(bjEstimate.transferFeeYuan == 0 && bjEstimate.totalCostText == "10005.00", "未明确的北交所过户费不额外估算")

        let rounded = try BuyFeeEstimate.calculate(amount: "20020", commissionRate: "2.5", symbol: sh)
        check(rounded.commissionYuan == Decimal(string: "5.01"), "佣金半分钱向上四舍五入")
        check(rounded.transferFeeYuan == Decimal(string: "0.20"), "过户费单独按分四舍五入")
        check(rounded.feesText == "5.21" && rounded.totalCostText == "20025.21", "分别取整后相加，避免总费一次取整差额")
        let transferBoundary = try BuyFeeEstimate.calculate(amount: "500", commissionRate: "2.5", symbol: sh)
        check(transferBoundary.transferFeeYuan == Decimal(string: "0.01"), "沪市过户费半分钱向上取整")
        let transferBelowBoundary = try BuyFeeEstimate.calculate(amount: "499.99", commissionRate: "2.5", symbol: sh)
        check(transferBelowBoundary.transferFeeYuan == 0 && transferBelowBoundary.feesText == "5.00", "不足半分钱过户费显示零")

        let trimmed = try BuyFeeEstimate.calculate(amount: " 00040000.10 \n", commissionRate: " 02.50 ", symbol: sh)
        check(trimmed.purchaseAmountYuan == Decimal(string: "40000.10") && trimmed.totalCostText == "40010.50", "金额和费率支持首尾空白与前导零")
        let fractionalAmount = try BuyFeeEstimate.calculate(amount: ".50", commissionRate: ".25", symbol: sz)
        check(fractionalAmount.totalCostText == "5.50", "小于1元金额与小数费率仍精确计算")
        let changedRate = try BuyFeeEstimate.calculate(amount: "40000", commissionRate: "3", symbol: sz)
        check(changedRate.feesText == "12.00", "佣金万分比可编辑")
        let maximumRate = try BuyFeeEstimate.calculate(amount: "40000", commissionRate: "30", symbol: sh)
        check(maximumRate.totalCostText == "40120.40", "佣金费率允许公开上限3‰")
        let preciseRate = try BuyFeeEstimate.calculate(amount: "40000", commissionRate: "2.5125", symbol: sz)
        check(preciseRate.feesText == "10.05", "费率小数精确计算，不转换二进制浮点数")
        check(preciseRate.commissionRatePerTenThousand == Decimal(string: "2.5125"), "单笔费率保留全部有效小数用于编辑恢复")
        let tracking = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: shEstimate.totalCostText)
        check(tracking.totalCostYuan == shEstimate.totalCostYuan, "估算总成本可直接用于现有持仓总成本字段")

        for amount in ["", "0", "-1", "+1", "1.001", "1.000", "1.", ".", "1e4", "NaN", "inf", "1,000", "１", "2abc", "2 0"] {
            rejects("拒绝无效或不能精确到分的成交金额：\(amount)") {
                _ = try BuyFeeEstimate.calculate(amount: amount, commissionRate: "2.5", symbol: sh)
            }
        }
        for rate in ["", "0", "-1", "+2.5", "30.0001", "31", "1e1", "NaN", "inf", "2.5abc", "2,5", "２.５", ".", "2."] {
            rejects("拒绝无效或超过公开上限的万分比：\(rate)") {
                _ = try BuyFeeEstimate.calculate(amount: "10000", commissionRate: rate, symbol: sz)
            }
        }
        for amount in ["99999999999999999999999999999999999999.99", String(repeating: "9", count: 200)] {
            rejects("金额溢出或超过Decimal精度时拒绝，不能静默截断") {
                _ = try BuyFeeEstimate.calculate(amount: amount, commissionRate: "2.5", symbol: sh)
            }
        }
        rejects("费率超过Decimal有效位数不能静默截断") {
            _ = try BuyFeeEstimate.calculate(amount: "10000", commissionRate: "2.12345678901234567890123456789012345678901234567890", symbol: sz)
        }
        rejects("成交金额可表达但费用相加损失分精度时拒绝") {
            _ = try BuyFeeEstimate.calculate(amount: String(repeating: "9", count: 37) + "8", commissionRate: "30", symbol: sh)
        }
        print("PASS: \(checks) fee assertions")
    }
}
