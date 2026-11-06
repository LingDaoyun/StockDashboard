import Foundation
import CoreGraphics

struct DailyChartViewport {
    var visibleCount: Int = 60
    var endDate: String? = nil

    func range(in dates: [String]) -> Range<Int> {
        guard !dates.isEmpty else { return 0..<0 }
        let count = min(dates.count, max(10, visibleCount))
        let requestedEnd = endDate.map { end in
            (dates.lastIndex(where: { $0 <= end }) ?? 0) + 1
        } ?? dates.count
        let end = min(dates.count, max(count, requestedEnd))
        return (end - count)..<end
    }

    mutating func zoom(by factor: Double, anchor: Double, dates: [String]) {
        guard !dates.isEmpty, factor.isFinite, factor > 0 else { return }
        let current = range(in: dates)
        let minimum = min(10, dates.count)
        let scaled = (Double(current.count) * factor).rounded(factor > 1 ? .up : .down)
        let count = Int(min(Double(dates.count), max(Double(minimum), scaled)))
        guard count != current.count else { return }
        let position = anchor.isFinite ? min(1, max(0, anchor)) : 0.5
        // Keep the candle beneath the pointer in the same relative slot when boundaries permit.
        let selected = current.lowerBound + min(current.count - 1, Int(Double(current.count) * position))
        let offset = min(count - 1, Int(Double(count) * position))
        let start = min(dates.count - count, max(0, selected - offset))
        visibleCount = count
        endDate = start + count == dates.count ? nil : dates[start + count - 1]
    }

    mutating func pan(by candles: Int, dates: [String]) {
        guard !dates.isEmpty, candles != 0 else { return }
        let current = range(in: dates)
        let shift = max(-current.lowerBound, min(dates.count - current.upperBound, candles))
        let end = current.upperBound + shift
        endDate = end == dates.count ? nil : dates[end - 1]
    }

    mutating func reset() {
        visibleCount = 60
        endDate = nil
    }
}

enum DailyChartTool: String, CaseIterable {
    case browse, marker, trendLine, horizontalLine
}

struct DailyChartAnchor: Codable, Equatable {
    let date: String
    let price: Double
}

struct DailyChartAnnotation: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case marker, trendLine, horizontalLine }

    let id: UUID
    let kind: Kind
    let start: DailyChartAnchor
    let end: DailyChartAnchor?

    init(kind: Kind, start: DailyChartAnchor, end: DailyChartAnchor? = nil) {
        id = UUID()
        self.kind = kind
        self.start = start
        self.end = end
    }
}

enum DailyChartAnnotationHitTest {
    static func hit(at point: CGPoint, annotations: [DailyChartAnnotation], plot: CGRect,
                    position: (DailyChartAnchor) -> CGPoint?, priceY: (Double) -> CGFloat) -> UUID? {
        guard finite(point), !plot.isNull, !plot.isInfinite, plot.width > 0, plot.height > 0,
              plot.minX.isFinite, plot.maxX.isFinite, plot.minY.isFinite, plot.maxY.isFinite,
              plot.contains(point) else { return nil }
        for annotation in annotations.reversed() {
            switch annotation.kind {
            case .horizontalLine:
                let y = priceY(annotation.start.price)
                guard y.isFinite, y >= plot.minY, y <= plot.maxY else { continue }
                if abs(point.y - y) <= 8 { return annotation.id }
            case .marker:
                guard let anchor = position(annotation.start), finite(anchor), plot.contains(anchor) else { continue }
                if hypot(point.x - anchor.x, point.y - anchor.y) <= 8 { return annotation.id }
            case .trendLine:
                guard let start = position(annotation.start), let end = annotation.end.flatMap(position),
                      finite(start), finite(end), let segment = clipped(start, end, to: plot) else { continue }
                if distance(point, from: segment.0, to: segment.1) <= 8 { return annotation.id }
            }
        }
        return nil
    }

    private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    private static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projected = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        guard projected.isFinite else { return .infinity }
        let amount = min(1, max(0, projected))
        return hypot(point.x - (start.x + amount * dx), point.y - (start.y + amount * dy))
    }

    private static func clipped(_ start: CGPoint, _ end: CGPoint, to plot: CGRect) -> (CGPoint, CGPoint)? {
        let dx = end.x - start.x, dy = end.y - start.y
        var lower: CGFloat = 0, upper: CGFloat = 1
        // Clip the finite segment first so an invisible nearby extension cannot be selected.
        for (direction, margin) in [(-dx, start.x - plot.minX), (dx, plot.maxX - start.x),
                                    (-dy, start.y - plot.minY), (dy, plot.maxY - start.y)] {
            guard direction.isFinite, margin.isFinite else { return nil }
            if direction == 0 {
                if margin < 0 { return nil }
            } else {
                let boundary = margin / direction
                if direction < 0 { lower = max(lower, boundary) }
                else { upper = min(upper, boundary) }
                if lower > upper { return nil }
            }
        }
        return (CGPoint(x: start.x + lower * dx, y: start.y + lower * dy),
                CGPoint(x: start.x + upper * dx, y: start.y + upper * dy))
    }
}

final class DailyChartAnnotationStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(symbol: String, adjustment: String) -> [DailyChartAnnotation] {
        guard let data = defaults.data(forKey: key(symbol: symbol, adjustment: adjustment)) else { return [] }
        return (try? JSONDecoder().decode([DailyChartAnnotation].self, from: data)) ?? []
    }

    func save(_ annotations: [DailyChartAnnotation], symbol: String, adjustment: String) {
        guard let data = try? JSONEncoder().encode(annotations) else { return }
        defaults.set(data, forKey: key(symbol: symbol, adjustment: adjustment))
    }

    private func key(symbol: String, adjustment: String) -> String {
        "dailyChartAnnotations.\(symbol.utf8.count):\(symbol)\(adjustment)"
    }
}
