import Foundation
import CoreGraphics

@main
@MainActor
enum DailyChartWorkspaceTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func hitTests() {
        let plot = CGRect(x: 10, y: 20, width: 200, height: 100)
        let xs: [String: CGFloat] = ["a": 50, "b": 150, "left": -20, "right": 250, "outside": 5]
        func position(_ anchor: DailyChartAnchor) -> CGPoint? {
            xs[anchor.date].map { CGPoint(x: $0, y: anchor.price) }
        }
        func hit(_ point: CGPoint, _ annotations: [DailyChartAnnotation]) -> UUID? {
            DailyChartAnnotationHitTest.hit(at: point, annotations: annotations, plot: plot,
                                            position: position, priceY: { CGFloat($0) })
        }
        let a = DailyChartAnchor(date: "a", price: 50)
        let b = DailyChartAnchor(date: "b", price: 50)
        let marker = DailyChartAnnotation(kind: .marker, start: a)
        let line = DailyChartAnnotation(kind: .trendLine, start: a, end: b)
        let zero = DailyChartAnnotation(kind: .trendLine, start: a, end: a)
        let horizontal = DailyChartAnnotation(kind: .horizontalLine, start: DailyChartAnchor(date: "missing", price: 80))
        check(hit(CGPoint(x: 58, y: 50), [marker]) == marker.id, "标记八点容差边界可以命中")
        check(hit(CGPoint(x: 58.01, y: 50), [marker]) == nil, "标记超过八点不命中")
        check(hit(CGPoint(x: 56, y: 56), [marker]) == nil, "标记按欧氏距离而非方框命中")
        check(hit(CGPoint(x: 100, y: 58), [line]) == line.id, "趋势线八点法向距离可以命中")
        check(hit(CGPoint(x: 100, y: 58.01), [line]) == nil, "趋势线超过八点不命中")
        check(hit(CGPoint(x: 42, y: 50), [line]) == line.id, "趋势线端点附近可以命中")
        check(hit(CGPoint(x: 40, y: 50), [line]) == nil, "趋势线不把端点外无限延长线当作线段")
        check(hit(CGPoint(x: 55, y: 50), [zero]) == zero.id, "零长度趋势线按端点距离命中")
        check(hit(CGPoint(x: 20, y: 88), [horizontal]) == horizontal.id
              && hit(CGPoint(x: 200, y: 80), [horizontal]) == horizontal.id,
              "水平线横跨绘图区，原日期缺失仍按价格投影命中")
        check(hit(CGPoint(x: 100, y: 88.01), [horizontal]) == nil, "水平线超过八点不命中")
        let overlapping = DailyChartAnnotation(kind: .marker, start: a)
        check(hit(CGPoint(x: 50, y: 50), [marker, line, overlapping]) == overlapping.id,
              "重叠时优先选择最后绘制的条目")
        check(hit(CGPoint(x: 50, y: 50), [overlapping, line, marker]) == marker.id,
              "绘制顺序变化后命中同步变化")
        let crossing = DailyChartAnnotation(kind: .trendLine, start: DailyChartAnchor(date: "left", price: 50),
                                             end: DailyChartAnchor(date: "right", price: 50))
        check(hit(CGPoint(x: 11, y: 50), [crossing]) == crossing.id, "端点在视野外但穿过绘图区的线段可选")
        check(hit(CGPoint(x: 9, y: 50), [crossing]) == nil, "点击绘图区裁剪范围之外不能命中")
        let diagonal = DailyChartAnnotation(kind: .trendLine, start: DailyChartAnchor(date: "left", price: 10),
                                             end: DailyChartAnchor(date: "b", price: 95))
        check(hit(CGPoint(x: 12, y: 26), [diagonal]) == diagonal.id
              && hit(CGPoint(x: 50, y: 51), [diagonal]) == diagonal.id,
              "只有一端在视野外的斜线裁剪后按最短法向距离选择")
        check(hit(CGPoint(x: 50, y: 55), [diagonal]) == nil, "斜线法向距离超过八点不命中")
        let vertical = DailyChartAnnotation(kind: .trendLine, start: DailyChartAnchor(date: "a", price: 10),
                                             end: DailyChartAnchor(date: "a", price: 90))
        check(hit(CGPoint(x: 57, y: 30), [vertical]) == vertical.id, "垂直线可裁剪且不会除零")
        let offscreen = DailyChartAnnotation(kind: .trendLine, start: DailyChartAnchor(date: "left", price: 50),
                                              end: DailyChartAnchor(date: "outside", price: 50))
        check(hit(CGPoint(x: 11, y: 50), [offscreen]) == nil, "整条线段在裁剪区外，即使距点击点不到八点也不命中")
        let outsideHorizontal = DailyChartAnnotation(kind: .horizontalLine, start: DailyChartAnchor(date: "a", price: 18))
        check(hit(CGPoint(x: 50, y: 21), [outsideHorizontal]) == nil, "水平线价格在可视区外不能命中")
        let outsideMarker = DailyChartAnnotation(kind: .marker, start: DailyChartAnchor(date: "outside", price: 50))
        check(hit(CGPoint(x: 11, y: 50), [outsideMarker]) == nil, "裁剪区外的标记不能命中")
        let missing = DailyChartAnnotation(kind: .marker, start: horizontal.start)
        check(hit(CGPoint(x: 50, y: 80), [missing]) == nil, "非水平标记缺少日期投影时跳过")
        check(DailyChartAnnotationHitTest.hit(at: CGPoint(x: 50, y: 50), annotations: [line], plot: plot,
                                               position: { _ in CGPoint(x: CGFloat.nan, y: 50) }, priceY: { CGFloat($0) }) == nil,
              "无效投影坐标不能命中")
        check(DailyChartAnnotationHitTest.hit(at: CGPoint(x: 50, y: 80), annotations: [horizontal], plot: plot,
                                               position: position, priceY: { _ in CGFloat.infinity }) == nil,
              "无效水平价格投影不能命中")
        check(hit(CGPoint(x: CGFloat.nan, y: 50), [marker]) == nil, "无效点击坐标不能命中")
        for invalidPlot in [CGRect.zero, CGRect.null, CGRect.infinite] {
            check(DailyChartAnnotationHitTest.hit(at: CGPoint(x: 50, y: 50), annotations: [marker], plot: invalidPlot,
                                                   position: position, priceY: { CGFloat($0) }) == nil,
                  "空或非有限绘图区不能命中")
        }
        let zoomed = DailyChartAnnotationHitTest.hit(at: CGPoint(x: 100, y: 60), annotations: [marker], plot: plot,
                                                    position: { anchor in position(anchor).map { CGPoint(x: $0.x * 2, y: $0.y + 10) } },
                                                    priceY: { CGFloat($0) + 10 })
        check(zoomed == marker.id, "缩放后使用新投影命中同一个持久标注ID")
    }

    static func main() throws {
        hitTests()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: "2026-01-01")!
        let dates = (0..<120).map { formatter.string(from: start.addingTimeInterval(Double($0) * 86400)) }
        let appended = (0..<130).map { formatter.string(from: start.addingTimeInterval(Double($0) * 86400)) }

        var viewport = DailyChartViewport()
        check(viewport.visibleCount == 60 && viewport.endDate == nil && viewport.range(in: dates) == 60..<120,
              "默认显示最新六十根并跟随最新日期")
        viewport.zoom(by: 0.5, anchor: 0.5, dates: dates)
        check(viewport.range(in: dates) == 75..<105 && viewport.visibleCount == 30,
              "中心放大保留鼠标所指第九十根K线")
        check(viewport.endDate == dates[104], "缩放落在历史范围时固定尾日")
        viewport.zoom(by: 2, anchor: 0.5, dates: dates)
        check(viewport.range(in: dates) == 60..<120 && viewport.endDate == nil,
              "中心缩小回到最新尾端后恢复跟随")
        viewport.zoom(by: 0.5, anchor: 1, dates: dates)
        check(viewport.range(in: dates) == 90..<120 && viewport.endDate == nil,
              "在最右侧放大锚定最新日期")
        viewport.zoom(by: 0.001, anchor: 1, dates: dates)
        check(viewport.visibleCount == 10 && viewport.range(in: dates) == 110..<120,
              "放大最多到十根K线")
        for _ in 0..<5 { viewport.zoom(by: 1.01, anchor: 1, dates: dates) }
        check(viewport.visibleCount == 15 && viewport.range(in: dates) == 105..<120,
              "连续轻微缩小手势逐步增加可见根数，不被整数舍入吞掉")
        for _ in 0..<5 { viewport.zoom(by: 0.99, anchor: 1, dates: dates) }
        check(viewport.visibleCount == 10 && viewport.range(in: dates) == 110..<120,
              "连续轻微放大手势逐步减少可见根数")
        viewport.zoom(by: 1, anchor: 0, dates: dates)
        check(viewport.visibleCount == 10 && viewport.range(in: dates) == 110..<120 && viewport.endDate == nil,
              "缩放因子恰为一时范围与跟随状态不变")
        viewport.zoom(by: Double.greatestFiniteMagnitude, anchor: 0.5, dates: dates)
        check(viewport.range(in: dates) == 0..<120 && viewport.visibleCount == 120,
              "极大缩小因子最多显示全部日期且不溢出")
        let unchangedRange = viewport.range(in: dates)
        for factor in [0.0, -1, Double.nan, .infinity] {
            viewport.zoom(by: factor, anchor: 0.5, dates: dates)
            check(viewport.range(in: dates) == unchangedRange, "非法缩放因子不改变视窗")
        }
        viewport.reset()
        viewport.pan(by: -60, dates: dates)
        viewport.zoom(by: 0.5, anchor: 0, dates: dates)
        check(viewport.range(in: dates) == 0..<30, "最左侧放大锚定首日且不越界")
        viewport.zoom(by: 2, anchor: -10, dates: dates)
        check(viewport.range(in: dates) == 0..<60, "鼠标锚点超出左侧时按左边界处理")

        viewport.reset()
        viewport.pan(by: -20, dates: dates)
        check(viewport.range(in: dates) == 40..<100 && viewport.endDate == dates[99], "负拖动前往历史并固定尾日")
        check(viewport.range(in: appended) == 40..<100 && viewport.endDate == dates[99],
              "追加行情日期不挪动历史视图")
        check(viewport.range(in: Array(dates.prefix(70))) == 10..<70 && viewport.endDate == dates[99],
              "序列变短时范围收敛到合法区间但不改写历史锚点")
        check(viewport.range(in: Array(dates.dropFirst(40))) == 0..<60,
              "删除早期历史后仍以日期而非旧数组位置定位")
        var missingEnd = dates
        missingEnd.remove(at: 99)
        check(viewport.range(in: missingEnd) == 39..<99, "原尾日缺失时选择此前最近日期")
        viewport.pan(by: 10, dates: appended)
        check(viewport.range(in: appended) == 50..<110 && viewport.endDate == dates[109], "正拖动前往更新日期")
        viewport.pan(by: Int.max, dates: appended)
        check(viewport.range(in: appended) == 70..<130 && viewport.endDate == nil,
              "拖至最新端恢复跟随且大位移不溢出")
        viewport.pan(by: Int.min, dates: dates)
        check(viewport.range(in: dates) == 0..<60 && viewport.endDate == dates[59], "拖至最旧端不越界")
        viewport.reset()
        check(viewport.visibleCount == 60 && viewport.endDate == nil && viewport.range(in: appended) == 70..<130,
              "重置恢复默认六十根和最新跟随")
        check(viewport.range(in: []) == 0..<0, "空序列返回空范围")
        viewport.zoom(by: 0.5, anchor: 0.5, dates: [])
        viewport.pan(by: Int.min, dates: [])
        check(viewport.visibleCount == 60 && viewport.endDate == nil, "空序列缩放拖动不改变状态")
        let short = Array(dates.prefix(5))
        viewport.zoom(by: 0.5, anchor: 1, dates: short)
        check(viewport.range(in: short) == 0..<5, "数据不足十根时显示实际数量")

        let domain = "cn.local.AShareDesktop.daily-chart-workspace-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let holdings = Data(#"{"sh600108":{"quantity":4500,"totalCostYuan":18763.07}}"#.utf8)
        defaults.set(holdings, forKey: "stockTracking")
        defaults.set("600108,002580", forKey: "symbols")
        let initialKeys = Set(defaults.persistentDomain(forName: domain)!.keys)
        let store = DailyChartAnnotationStore(defaults: defaults)
        check(store.load(symbol: "sh600108", adjustment: "前复权").isEmpty, "未保存的证券标注为空")
        let first = DailyChartAnchor(date: dates[40], price: 10.12345678)
        let last = DailyChartAnchor(date: dates[70], price: 12.5)
        let marker = DailyChartAnnotation(kind: .marker, start: first)
        let trend = DailyChartAnnotation(kind: .trendLine, start: first, end: last)
        let horizontal = DailyChartAnnotation(kind: .horizontalLine, start: last)
        check(marker.id != trend.id && marker.end == nil && trend.end == last, "标注有独立ID并保存可选终点")
        let annotations = [marker, trend, horizontal]
        let restored = try JSONDecoder().decode([DailyChartAnnotation].self, from: JSONEncoder().encode(annotations))
        check(restored == annotations, "标注ID、类型、日期和价格可完整编码恢复")
        store.save(annotations, symbol: "sh600108", adjustment: "前复权")
        let savedKeys = Set(defaults.persistentDomain(forName: domain)!.keys).subtracting(initialKeys)
        check(savedKeys.count == 1, "标注只写入独立存储键")
        let savedKey = savedKeys.first!
        let reloaded = DailyChartAnnotationStore(defaults: defaults)
        check(reloaded.load(symbol: "sh600108", adjustment: "前复权") == annotations, "新实例可读取完整本地标注")
        store.save([horizontal], symbol: "sh600108", adjustment: "不复权")
        store.save([marker], symbol: "sz002580", adjustment: "前复权")
        check(store.load(symbol: "sh600108", adjustment: "前复权") == annotations
              && store.load(symbol: "sh600108", adjustment: "不复权") == [horizontal]
              && store.load(symbol: "sz002580", adjustment: "前复权") == [marker], "证券与复权口径分别隔离")
        defaults.set(Data("damaged-json".utf8), forKey: savedKey)
        check(store.load(symbol: "sh600108", adjustment: "前复权").isEmpty, "损坏标注返回空数组")
        check(store.load(symbol: "sh600108", adjustment: "不复权") == [horizontal], "损坏一组标注不影响其他复权口径")
        store.save([], symbol: "sz002580", adjustment: "前复权")
        check(store.load(symbol: "sz002580", adjustment: "前复权").isEmpty, "可保存空标注数组")
        check(defaults.data(forKey: "stockTracking") == holdings && defaults.string(forKey: "symbols") == "600108,002580",
              "所有标注读写保持持仓与股票设置不变")
        print("PASS: \(checks) daily chart workspace assertions")
    }
}
