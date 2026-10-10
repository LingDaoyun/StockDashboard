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
