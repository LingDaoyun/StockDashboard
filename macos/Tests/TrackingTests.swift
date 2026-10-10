import Foundation

@main
@MainActor
enum TrackingTests {
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
            check(error is LocalizedError, "输入错误应包含可供界面显示的说明")
            check(!error.localizedDescription.isEmpty, message)
        }
    }

    static func quote(price: Double, at timestamp: Date) -> Quote {
        Quote(symbol: StockSymbol(code: "600108", market: "sh"), name: "亚盛集团",
              price: price, previousClose: 10, change: price - 10,
              changePercent: (price - 10) * 10, volumeLots: 100,
              amountYuan: 100_000, timestamp: timestamp,
              turnoverPercent: 1, volumeRatio: 1, amplitudePercent: 1)
    }

    static func main() throws {
        let empty = try StockTracking.parse(cost: " \n ", quantity: "", upper: "", lower: " ")
        check(empty == StockTracking(), "全空输入相当于未设置")
        check(!empty.hasPosition && !empty.hasAlerts && !empty.hasTriggeredAlerts, "新配置没有持仓或提醒")
        check(empty.profit(at: 10) == nil, "没有持仓时不计算盈亏")

        let position = try StockTracking.parse(cost: " 10.50 ", quantity: " 200 ", upper: "", lower: "")
        check(position.hasPosition && !position.hasAlerts, "持仓可独立于提醒设置")
        check(position.costPrice == 10.5 && position.quantity == 200, "成本和股数去除首尾空白")
        let gain = position.profit(at: 11.55)!
        check(abs(gain.amount - 210) < 0.00001 && abs(gain.percent - 10) < 0.00001, "正收益按股数计算金额和百分比")
        let loss = position.profit(at: 9.45)!
        check(abs(loss.amount + 210) < 0.00001 && abs(loss.percent + 10) < 0.00001, "负收益保留负号")
        check(position.profit(at: 10.5)?.amount == 0 && position.profit(at: 10.5)?.percent == 0, "现价等于成本时盈亏为零")
        for price in [Double.nan, .infinity, -1, 0] {
            check(position.profit(at: price) == nil, "非法现价不能生成盈亏")
        }
        let single = try StockTracking.parse(cost: "10", quantity: "1", upper: "", lower: "")
        check(single.profit(at: 11)?.amount == 1, "数量单位为股且允许非整手数量")
        let preciseData = Data(#"{"costPrice":10.123,"quantity":500,"totalCostYuan":5062.08,"upperTriggered":false,"lowerTriggered":false}"#.utf8)
        let precisePosition = try JSONDecoder().decode(StockTracking.self, from: preciseData).validated()
        check(precisePosition.profit(at: 12).map { String(describing: $0.amount) } == "937.92",
              "精确总成本优先于三位小数成本价，避免0.58元差额")
        check(precisePosition.costPrice == 10.12416, "恢复总成本时展示均价也由实际总成本重算")
        let halfCent = try StockTracking.parse(cost: "0.005", quantity: "1", upper: "", lower: "")
        check(halfCent.profit(at: 1)?.amount == 1, "浮盈亏的半分钱按分四舍五入")
        check(halfCent.profit(at: 1)?.amountText == "+1.00", "金额显示使用十进制两位小数与显式正号")
        let totalPosition = try StockTracking.parse(cost: "", quantity: "500", upper: "", lower: "", totalCost: " 05062.08 ")
        check(totalPosition.hasPosition && totalPosition.totalCostYuan == Decimal(string: "5062.08"), "总成本与股数即可设置持仓")
        check(totalPosition.costPrice == 10.12416, "单股成本由精确总成本自动计算用于展示")
        check(totalPosition.totalCostText == "5062.08", "总成本编辑预填保留分并去掉多余前导零")
        let preciseProfit = totalPosition.profit(at: 12)!
        check(preciseProfit.amount == Decimal(string: "937.92") && preciseProfit.amountText == "+937.92", "按总成本计算精确盈亏且不重复扣除费用")
        check(abs(preciseProfit.percent - (937.92 / 5062.08 * 100)) < 0.00000001, "盈亏率分母使用精确总成本")
        let withoutAverage = StockTracking(quantity: 500, totalCostYuan: Decimal(string: "5062.08"))
        check(withoutAverage.hasPosition && withoutAverage.profit(at: 12)?.amountText == "+937.92", "已有总成本时不依赖展示均价计算盈亏")
        let validatedTotal = try withoutAverage.validated()
        check(validatedTotal == totalPosition, "恢复总成本持仓时可补出展示均价")
        let preciseRoundtrip = try JSONDecoder().decode(StockTracking.self, from: JSONEncoder().encode(totalPosition)).validated()
        check(preciseRoundtrip == totalPosition && preciseRoundtrip.totalCostText == "5062.08", "持久化和恢复保留总成本的分精度")
        let purchaseData = Data(#"{"quantity":100,"totalCostYuan":1005,"purchaseAmountYuan":1000,"upperTriggered":false,"lowerTriggered":false}"#.utf8)
        let purchaseDecoded = try JSONDecoder().decode(StockTracking.self, from: purchaseData).validated()
        let purchaseJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(purchaseDecoded)) as! [String: Any]
        check((purchaseJSON["purchaseAmountYuan"] as? NSNumber)?.stringValue == "1000", "持久化恢复保留原成交金额，避免编辑再保存重复加费")
        let purchasePosition = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005.00", purchaseAmount: " 01000.00 ")
        check(purchasePosition.purchaseAmountYuan == Decimal(1000) && purchaseDecoded == purchasePosition, "成交金额按分保存并通过恢复校验")
        check(purchasePosition.profit(at: 12)?.amountText == "+195.00", "成交金额只标记费用预估来源，不重新计算或重复增加费用")
        let rateData = Data(#"{"quantity":100,"totalCostYuan":1005,"purchaseAmountYuan":1000,"purchaseCommissionRate":2.5,"upperTriggered":false,"lowerTriggered":false}"#.utf8)
        let rateDecoded = try JSONDecoder().decode(StockTracking.self, from: rateData).validated()
        let rateJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rateDecoded)) as! [String: Any]
        check((rateJSON["purchaseCommissionRate"] as? NSNumber)?.stringValue == "2.5", "持久化恢复保留每笔持仓采用的费率，避免全局费率变化改写历史预估")
        let ratePosition = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: "1000", purchaseCommissionRate: Decimal(string: "2.5"))
        check(ratePosition.purchaseCommissionRate == Decimal(string: "2.5") && ratePosition == rateDecoded, "按每笔持仓保存传入的十进制费率")
        check(ratePosition.profit(at: 12)?.amountText == "+195.00", "费率来源仅用于恢复，不改变已保存总成本与盈亏")
        check(purchaseDecoded.purchaseCommissionRate == nil && purchasePosition.purchaseCommissionRate == nil, "旧预估持仓缺少费率字段时仍可恢复")
        let maximumRate = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: "1000", purchaseCommissionRate: Decimal(30))
        check(maximumRate.purchaseCommissionRate == Decimal(30), "每笔费率允许有效范围的上界30")
        for rate in [Decimal.nan, Decimal.zero, Decimal(-1), Decimal(string: "30.001")!] {
            rejects("每笔佣金费率必须为大于0且不超过30的有效十进制数") {
                _ = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: "1000", purchaseCommissionRate: rate)
            }
            rejects("恢复配置拒绝非法每笔佣金费率") {
                _ = try StockTracking(quantity: 100, totalCostYuan: Decimal(1005), purchaseAmountYuan: Decimal(1000), purchaseCommissionRate: rate).validated()
            }
        }
        rejects("没有成交金额时不能保存孤立费率") { _ = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseCommissionRate: Decimal(string: "2.5")) }
        rejects("没有持仓时不能保存费率") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: "", purchaseCommissionRate: Decimal(string: "2.5")) }
        rejects("恢复配置拒绝没有成交金额的孤立费率") { _ = try StockTracking(quantity: 100, totalCostYuan: Decimal(1005), purchaseCommissionRate: Decimal(string: "2.5")).validated() }
        rejects("恢复配置拒绝没有持仓的孤立费率") { _ = try StockTracking(purchaseCommissionRate: Decimal(string: "2.5")).validated() }
        let purchaseEqualTotal = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1000", purchaseAmount: "1000")
        check(purchaseEqualTotal.purchaseAmountYuan == purchaseEqualTotal.totalCostYuan, "原成交金额允许等于总成本")
        let clearedPurchase = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: " \n ")
        check(clearedPurchase.purchaseAmountYuan == nil && clearedPurchase.purchaseCommissionRate == nil && clearedPurchase.totalCostYuan == Decimal(1005), "切换实填总成本时清除成交金额与费率预估来源")
        for text in ["0", "-1", "nan", "inf", "1e3", "1.001", "1000.00abc", "１.００", "99999999999999999999999999999999999999.99"] {
            rejects("原成交金额必须是可精确表达的正金额且最多两位小数：\(text)") {
                _ = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: text)
            }
        }
        rejects("原成交金额不能大于持仓总成本") { _ = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "", totalCost: "1005", purchaseAmount: "1005.01") }
        rejects("仅有原成交金额不能保存为持仓") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: "", purchaseAmount: "1000") }
        rejects("原成交金额必须与股数一起保存") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: "", totalCost: "1005", purchaseAmount: "1000") }
        rejects("原成交金额必须有对应的实际总成本") { _ = try StockTracking.parse(cost: "10", quantity: "100", upper: "", lower: "", purchaseAmount: "1000") }
        for value in [Decimal.zero, Decimal(-1), Decimal.nan, Decimal(string: "0.001")!, Decimal(1006)] {
            rejects("恢复配置不能接受非法或大于总成本的原成交金额") {
                _ = try StockTracking(quantity: 100, totalCostYuan: Decimal(1005), purchaseAmountYuan: value).validated()
            }
        }
        rejects("恢复原成交金额时不能缺少总成本") { _ = try StockTracking(costPrice: 10, quantity: 100, purchaseAmountYuan: Decimal(1000)).validated() }
        rejects("恢复原成交金额时不能缺少股数") { _ = try StockTracking(totalCostYuan: Decimal(1005), purchaseAmountYuan: Decimal(1000)).validated() }
        let estimatedAlerts = StockTracking(quantity: 100, upperPrice: 12, upperTriggered: true,
                                           armedAt: Date(timeIntervalSince1970: 1234), totalCostYuan: Decimal(1005),
                                           purchaseAmountYuan: Decimal(1000), purchaseCommissionRate: Decimal(string: "2.5"))
        let restoredEstimatedAlerts = try JSONDecoder().decode(StockTracking.self, from: JSONEncoder().encode(estimatedAlerts)).validated()
        check(restoredEstimatedAlerts.purchaseAmountYuan == Decimal(1000) && restoredEstimatedAlerts.purchaseCommissionRate == Decimal(string: "2.5") && restoredEstimatedAlerts.upperTriggered && restoredEstimatedAlerts.armedAt == estimatedAlerts.armedAt,
              "成交金额和费率恢复验证仍保留提醒触发状态与设定时间")
        let oldData = Data(#"{"costPrice":10.123,"quantity":500,"upperTriggered":false,"lowerTriggered":false}"#.utf8)
        let oldPosition = try JSONDecoder().decode(StockTracking.self, from: oldData).validated()
        check(oldPosition.totalCostYuan == nil && oldPosition.profit(at: 12)?.amountText == "+938.50", "旧配置缺失总成本字段时仍按原成本价恢复")
        check(oldPosition.purchaseAmountYuan == nil && totalPosition.purchaseAmountYuan == nil, "旧配置和按实填写总成本的配置缺失成交金额字段时不标记为预估")
        check(oldPosition.totalCostText == "5061.50" && halfCent.totalCostText == "0.01", "旧配置总成本预填由成本价乘股数按分估算")
        check(empty.totalCostText.isEmpty, "没有持仓时总成本预填为空")
        let centLoss = try StockTracking.parse(cost: "0.015", quantity: "1", upper: "", lower: "")
        check(centLoss.profit(at: 0.01)?.amount == Decimal(string: "-0.01") && centLoss.profit(at: 0.01)?.amountText == "-0.01", "负半分钱同样按分四舍五入")
        let roundedZero = try StockTracking.parse(cost: "1.004", quantity: "1", upper: "", lower: "")
        check(roundedZero.profit(at: 1)?.amount == 0 && roundedZero.profit(at: 1)?.amountText == "+0.00", "小于半分钱的负值归零且不显示负零")
        let totalLoss = try StockTracking.parse(cost: "", quantity: "40", upper: "", lower: "", totalCost: "800.40")
        check(totalLoss.profit(at: 19)?.amountText == "-40.40", "总成本模式保留负盈亏的金额与负号")
        check(abs(totalLoss.profit(at: 19)!.percent - (-40.40 / 800.40 * 100)) < 0.00000001, "负盈亏率同样按实际总成本计算")
        let totalZero = try StockTracking.parse(cost: "", quantity: "500", upper: "", lower: "", totalCost: "5000")
        check(totalZero.profit(at: 10)?.amountText == "+0.00" && totalZero.profit(at: 10)?.percent == 0, "总成本等于市值时金额和盈亏率归零")
        let partialYuan = try StockTracking.parse(cost: "", quantity: "1", upper: "", lower: "", totalCost: ".50")
        check(partialYuan.totalCostText == "0.50", "总成本可输入不足一元的十进制金额")
        for text in ["0", "-1", "nan", "inf", "-inf", "5e3", "1e999", "1.00abc", "1,000.00", "１.２３", "1.001", "1.000", ".", "1.", "+1"] {
            rejects("总成本应是正数且最多两位小数，科学记数和局部有效输入不能通过：\(text)") {
                _ = try StockTracking.parse(cost: "", quantity: "500", upper: "", lower: "", totalCost: text)
            }
        }
        for text in ["99999999999999999999999999999999999999.99", String(repeating: "9", count: 200)] {
            rejects("不能精确表达或溢出的总成本应被拒绝") {
                _ = try StockTracking.parse(cost: "", quantity: "500", upper: "", lower: "", totalCost: text)
            }
        }
        rejects("没有股数时不能填写总成本") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: "", totalCost: "100") }
        rejects("总成本与旧成本均为空时不能只填股数") { _ = try StockTracking.parse(cost: "", quantity: "500", upper: "", lower: "", totalCost: "") }
        for value in [Decimal.zero, Decimal(-1), Decimal.nan, Decimal(string: "0.001")!] {
            let invalidTotal = StockTracking(quantity: 500, totalCostYuan: value)
            rejects("恢复配置不能接受非法总成本") { _ = try invalidTotal.validated() }
            check(invalidTotal.profit(at: 12) == nil, "非法总成本不能生成盈亏")
        }
        rejects("恢复总成本也必须有正股数") { _ = try StockTracking(totalCostYuan: Decimal(100)).validated() }
        check(StockTracking(quantity: 0, totalCostYuan: Decimal(100)).profit(at: 12) == nil, "总成本模式非正股数不能生成盈亏")
        let large = try StockTracking.parse(cost: "1e300", quantity: "100", upper: "", lower: "")
        check(large.profit(at: 1e308) == nil, "市值溢出时不能显示非有限盈亏")
        let tiny = try StockTracking.parse(cost: "1e-308", quantity: "1", upper: "", lower: "")
        check(tiny.profit(at: 1e308) == nil, "收益率溢出时不能显示非有限百分比")

        rejects("成本和数量必须同时填写") { _ = try StockTracking.parse(cost: "10", quantity: "", upper: "", lower: "") }
        rejects("数量和成本必须同时填写") { _ = try StockTracking.parse(cost: "", quantity: "100", upper: "", lower: "") }
        for price in ["0", "-1", "nan", "inf", "-inf", "1e999", "abc"] {
            rejects("无效成本应被拒绝：\(price)") { _ = try StockTracking.parse(cost: price, quantity: "100", upper: "", lower: "") }
            rejects("无效上方价应被拒绝：\(price)") { _ = try StockTracking.parse(cost: "", quantity: "", upper: price, lower: "") }
            rejects("无效下方价应被拒绝：\(price)") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: price) }
        }
        for quantity in ["0", "-1", "1.5", "1e2", "+1", "abc", "１００", "999999999999999999999999999999"] {
            rejects("股数应为可表示的正整数：\(quantity)") { _ = try StockTracking.parse(cost: "10", quantity: quantity, upper: "", lower: "") }
        }
        rejects("总成本溢出应被拒绝") { _ = try StockTracking.parse(cost: "1e308", quantity: "100", upper: "", lower: "") }
        rejects("上下阈值不能相等") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "10", lower: "10") }
        rejects("下方价必须小于上方价") { _ = try StockTracking.parse(cost: "", quantity: "", upper: "9", lower: "10") }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var upperOnly = try StockTracking.parse(cost: "", quantity: "", upper: "12", lower: "")
        check(upperOnly.hasAlerts && !upperOnly.hasPosition, "允许只设上方提醒")
        check(upperOnly.takeAlerts(for: quote(price: 11.99, at: now), now: now).isEmpty, "未达到上方价不触发")
        let upperAlerts = upperOnly.takeAlerts(for: quote(price: 12, at: now), now: now)
        check(upperAlerts.count == 1 && upperAlerts[0].direction == .upper, "等于上方价时触发")
        let alert = upperAlerts[0]
        check(alert.symbolID == "sh600108" && alert.name == "亚盛集团" && alert.price == 12 && alert.threshold == 12 && alert.timestamp == now, "提醒保留证券、现价、阈值和行情时间")
        check(alert.message.contains("亚盛集团") && alert.message.contains("12.00") && !alert.direction.title.isEmpty, "提醒文本显示名称、价格和方向")
        check(upperOnly.upperTriggered && !upperOnly.lowerTriggered && upperOnly.hasTriggeredAlerts, "上方触发后更新标记")
        check(upperOnly.takeAlerts(for: quote(price: 13, at: now), now: now).isEmpty, "连续超过上方价只提醒一次")
        check(upperOnly.takeAlerts(for: quote(price: 11, at: now), now: now).isEmpty, "回到上方价以内不自动重置")
        check(upperOnly.takeAlerts(for: quote(price: 13, at: now), now: now).isEmpty, "再次越过已触发价仍不重复提醒")

        var lowerOnly = try StockTracking.parse(cost: "", quantity: "", upper: "", lower: "8")
        check(lowerOnly.hasAlerts, "允许只设下方提醒")
        check(lowerOnly.takeAlerts(for: quote(price: 8.01, at: now), now: now).isEmpty, "未达到下方价不触发")
        let lowerAlerts = lowerOnly.takeAlerts(for: quote(price: 8, at: now), now: now)
        check(lowerAlerts.count == 1 && lowerAlerts[0].direction == .lower && lowerOnly.lowerTriggered, "等于下方价时触发并保存标记")
        check(lowerOnly.takeAlerts(for: quote(price: 7, at: now), now: now).isEmpty, "下方价也只提醒一次")

        var both = try StockTracking.parse(cost: "10", quantity: "100", upper: "12", lower: "8")
        check(both.takeAlerts(for: quote(price: 13, at: now), now: now).count == 1, "超过上方价时只触发上方")
        check(both.takeAlerts(for: quote(price: 7, at: now), now: now).count == 1, "上方触发不阻止之后的下方提醒")
        check(both.upperTriggered && both.lowerTriggered && both.hasTriggeredAlerts, "两个方向各自保留触发标记")
        var noConfig = StockTracking()
        check(noConfig.takeAlerts(for: quote(price: 13, at: now), now: now).isEmpty, "未配置提醒不能触发")

        for offset in [-31.0, 5.001] {
            var tracking = try StockTracking.parse(cost: "", quantity: "", upper: "12", lower: "8")
            check(tracking.takeAlerts(for: quote(price: 13, at: now.addingTimeInterval(offset)), now: now).isEmpty, "陈旧或超前过多的快照不提醒")
            check(!tracking.hasTriggeredAlerts, "被拒绝快照不消耗触发机会")
        }
        for offset in [-30.0, 5.0] {
            var tracking = try StockTracking.parse(cost: "", quantity: "", upper: "12", lower: "")
            check(tracking.takeAlerts(for: quote(price: 12, at: now.addingTimeInterval(offset)), now: now).count == 1, "时间边界仍可接受")
        }
        var armed = try StockTracking.parse(cost: "", quantity: "", upper: "12", lower: "")
        armed.armedAt = now
        check(armed.takeAlerts(for: quote(price: 13, at: now.addingTimeInterval(-1)), now: now).isEmpty, "设置前的快照不提醒")
        check(!armed.hasTriggeredAlerts, "设置前快照不改变标记")
        check(armed.takeAlerts(for: quote(price: 13, at: now), now: now).count == 1, "设置时刻及之后的鲜行情可提醒")

        let data = try JSONEncoder().encode(armed)
        var restored = try JSONDecoder().decode(StockTracking.self, from: data)
        check(restored == armed && restored.armedAt == now, "持久化保留配置、设定时间和触发状态")
        check(restored.takeAlerts(for: quote(price: 14, at: now), now: now).isEmpty, "重载配置后不重复响铃")

        let invertedData = Data(#"{"upperPrice":9,"lowerPrice":11,"upperTriggered":false,"lowerTriggered":false}"#.utf8)
        let inverted = try JSONDecoder().decode(StockTracking.self, from: invertedData)
        rejects("解码后的逆序阈值不能恢复为有效提醒") { _ = try inverted.validated() }
        rejects("恢复配置必须同时有成本和数量") { _ = try StockTracking(costPrice: 10).validated() }
        rejects("恢复配置必须同时有数量和成本") { _ = try StockTracking(quantity: 100).validated() }
        for quantity in [0, -1] {
            rejects("恢复配置不能接受非正数量") { _ = try StockTracking(costPrice: 10, quantity: quantity).validated() }
        }
        rejects("恢复配置不能接受总成本溢出") { _ = try StockTracking(costPrice: 1e308, quantity: 100).validated() }
        for price in [Double.nan, .infinity, -.infinity, 0, -1] {
            rejects("恢复配置不能接受非法成本") { _ = try StockTracking(costPrice: price, quantity: 100).validated() }
            rejects("恢复配置不能接受非法上方提醒价") { _ = try StockTracking(upperPrice: price).validated() }
            rejects("恢复配置不能接受非法下方提醒价") { _ = try StockTracking(lowerPrice: price).validated() }
        }
        rejects("恢复配置不能接受相等阈值") { _ = try StockTracking(upperPrice: 10, lowerPrice: 10).validated() }
        let valid = StockTracking(costPrice: 10.5, quantity: 200, upperPrice: 12, lowerPrice: 8,
                                  upperTriggered: true, lowerTriggered: true, armedAt: now)
        let validated = try valid.validated()
        check(validated == valid, "恢复验证保留合法持仓、提醒价、触发状态和设定时间")
        var validatedRestored = try restored.validated()
        check(validatedRestored == restored, "验证解码配置不重置已触达状态")
        check(validatedRestored.takeAlerts(for: quote(price: 14, at: now), now: now).isEmpty, "恢复验证后仍不重复提醒")
        let upperWithOrphan = try StockTracking(upperPrice: 12, upperTriggered: true,
                                               lowerTriggered: true, armedAt: now).validated()
        check(upperWithOrphan.upperTriggered && !upperWithOrphan.lowerTriggered && upperWithOrphan.armedAt == now,
              "只有上方提醒时清理下方孤立标记，保留上方状态和时间")
        let lowerWithOrphan = try StockTracking(lowerPrice: 8, upperTriggered: true,
                                               lowerTriggered: true, armedAt: now).validated()
        check(!lowerWithOrphan.upperTriggered && lowerWithOrphan.lowerTriggered && lowerWithOrphan.armedAt == now,
              "只有下方提醒时清理上方孤立标记，保留下方状态和时间")
        let positionWithOrphans = try StockTracking(costPrice: 10, quantity: 100, upperTriggered: true,
                                                   lowerTriggered: true, armedAt: now).validated()
        check(positionWithOrphans.hasPosition && !positionWithOrphans.hasTriggeredAlerts && positionWithOrphans.armedAt == nil,
              "完全没有提醒时保留持仓并清理孤立状态和时间")
        let emptyWithOrphans = try StockTracking(upperTriggered: true, lowerTriggered: true, armedAt: now).validated()
        check(emptyWithOrphans == StockTracking(), "空配置清理所有孤立提醒状态")
        print("PASS: \(checks) tracking assertions")
    }
}
