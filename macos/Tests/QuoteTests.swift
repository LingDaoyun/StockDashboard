import Foundation
import CoreFoundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
enum QuoteTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(description: message) }
        checks += 1
    }

    static func expectError(_ message: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() }
        catch {
            rejected = true
            try expect(error is LocalizedError, "错误应包含可供界面显示的说明：\(message)")
            try expect(!error.localizedDescription.isEmpty, "错误说明不能为空：\(message)")
        }
        try expect(rejected, message)
    }

    static func main() async {
        do {
            try runTests()
            let empty = try await QuoteClient().fetch([])
            try expect(empty.isEmpty, "空自选列表应直接返回空结果")
            if CommandLine.arguments.contains("--live") {
                let symbols = try StockSymbol.parseList("600108,002580")
                let quotes = try await QuoteClient().fetch(symbols)
                try expect(quotes.count == 2, "实时接口应返回本次指定的两只股票")
                for symbol in symbols {
                    let quote = quotes[symbol.id]!
                    try expect(quote.turnoverPercent.map { $0.isFinite && $0 >= 0 } == true, "实时行情应返回有效换手率：\(symbol.id)")
                    try expect(quote.volumeRatio.map { $0.isFinite && $0 >= 0 } == true, "实时行情应返回有效量比：\(symbol.id)")
                    try expect(quote.amplitudePercent.map { $0.isFinite && $0 >= 0 } == true, "实时行情应返回有效振幅：\(symbol.id)")
                    print("LIVE: \(symbol.id) \(quote.name) price=\(quote.price) volumeLots=\(quote.volumeLots) amountYuan=\(quote.amountYuan) timestamp=\(quote.timestamp) turnoverPercent=\(quote.turnoverPercent.map { String($0) } ?? "—") volumeRatio=\(quote.volumeRatio.map { String($0) } ?? "—") amplitudePercent=\(quote.amplitudePercent.map { String($0) } ?? "—")")
                }
            }
            print("PASS: \(checks) assertions")
        }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func fixture(_ symbol: StockSymbol, name: String = "贵州茅台", edits: [Int: String] = [:], count: Int = 58) -> String {
        var fields = Array(repeating: "", count: 58)
        fields[0] = "1"
        fields[1] = name
        fields[2] = symbol.code
        fields[3] = "1263.12"
        fields[4] = "1255.79"
        fields[6] = "34719"
        fields[30] = "20261009145653"
        fields[31] = "7.33"
        fields[32] = "0.58"
        fields[36] = "34719"
        fields[37] = "440377"
        fields[38] = "0.28"
        fields[43] = "2.12"
        fields[49] = "1.18"
        fields[57] = "440376.8903"
        for (index, value) in edits { fields[index] = value }
        return "v_\(symbol.id)=\"\(fields.prefix(count).joined(separator: "~"))\";\n"
    }

    static func encoded(_ text: String) -> Data {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return text.data(using: encoding)!
    }

    static func runTests() throws {
        let symbols = try StockSymbol.parseList("600108,002580，SH600108\n bj920002  830799\t300750 430047")
        try expect(symbols.map(\.id) == ["sh600108", "sz002580", "bj920002", "bj830799", "sz300750", "bj430047"], "应推断交易所、规范前缀、保留前导0并按顺序去重")
        try expect(try StockSymbol.parseList("sh000001").first?.id == "sh000001", "显式前缀应保留指定交易所")
        for input in ["", " ,， \n ", "12345", "1234567", "900001", "hk00700", "usAAPL", "600108;002580", "六零零一零八", "６００１０８", "sh600108x"] {
            try expectError("应拒绝无效输入：\(input)") { _ = try StockSymbol.parseList(input) }
        }
        let twenty = (0..<20).map { String(format: "600%03d", $0) }.joined(separator: ",")
        try expect(try StockSymbol.parseList(twenty).count == 20, "应接受20个不同代码")
        try expect(try StockSymbol.parseList(twenty + ",600000").count == 20, "重复代码不应占用限额")
        try expectError("应拒绝超过20个不同代码") { _ = try StockSymbol.parseList(twenty + ",600020") }
        let symbol = try StockSymbol.parseList("600519")[0]
        let quotes = try QuoteParser.parse(encoded(fixture(symbol)), symbols: [symbol])
        let quote = quotes[symbol.id]
        try expect(quote?.name == "贵州茅台", "应按GB18030解码中文名称")
        try expect(quote?.symbol == symbol, "返回行情应匹配请求的交易所和代码")
        try expect(quote?.price == 1263.12 && quote?.previousClose == 1255.79, "应读取现价和昨收")
        try expect(quote?.change == 7.33 && quote?.changePercent == 0.58, "涨跌幅字段已经是百分数，不应再乘100")
        try expect(quote?.volumeLots == 34719, "成交量单位应保留为手")
        try expect(abs((quote?.amountYuan ?? 0) - 4_403_768_903) < 0.001, "精确成交额万元应转换成元")
        try expect(quote?.timestamp.timeIntervalSince1970 == 1_791_529_013, "十四位时间应按中国时区解析")
        try expect(quote?.turnoverPercent == 0.28, "38号换手率字段已经是百分数，不应再乘100")
        try expect(quote?.volumeRatio == 1.18, "49号量比字段应保留倍数原值，不应乘100")
        try expect(quote?.amplitudePercent == 2.12, "43号振幅字段已经是百分数，不应再乘100")
        let simple = try QuoteParser.parse(encoded(fixture(symbol, count: 38)), symbols: [symbol])
        try expect(simple[symbol.id]?.amountYuan == 4_403_770_000, "只包含基础字段时应按37号万元字段转换")
        try expect(simple[symbol.id]?.turnoverPercent == nil, "缺少38号换手率字段时应保留行情，换手率为空")
        try expect(simple[symbol.id]?.volumeRatio == nil, "缺少49号量比字段时应保留行情，量比为空")
        try expect(simple[symbol.id]?.amplitudePercent == nil, "缺少43号振幅字段时应保留行情，振幅为空")
        for index in [43, 49] {
            for value in ["", "bad", "nan", "inf", "-0.01"] {
                let optionalMetrics = try QuoteParser.parse(encoded(fixture(symbol, edits: [index: value])), symbols: [symbol])[symbol.id]
                let otherMetric = index == 49 ? optionalMetrics?.amplitudePercent : optionalMetrics?.volumeRatio
                let invalidMetric = index == 49 ? optionalMetrics?.volumeRatio : optionalMetrics?.amplitudePercent
                try expect(optionalMetrics?.price == 1263.12 && otherMetric == (index == 49 ? 2.12 : 1.18), "\(index)号字段非法时应保留报价和另一观察参数：\(value)")
                try expect(invalidMetric == nil, "\(index)号字段缺失或非法时应为空：\(value)")
            }
            for value in ["0", "101.23"] {
                let validMetrics = try QuoteParser.parse(encoded(fixture(symbol, edits: [index: value])), symbols: [symbol])[symbol.id]
                let metric = index == 49 ? validMetrics?.volumeRatio : validMetrics?.amplitudePercent
                try expect(metric == Double(value), "\(index)号参数应允许零和非负有限数值：\(value)")
            }
        }
        for value in ["", "bad", "nan", "inf", "-0.01"] {
            let optionalTurnover = try QuoteParser.parse(encoded(fixture(symbol, edits: [38: value])), symbols: [symbol])
            try expect(optionalTurnover[symbol.id]?.price == 1263.12, "换手率非法时仍应保留原报价：\(value)")
            try expect(optionalTurnover[symbol.id]?.turnoverPercent == nil, "换手率缺失或非法时应为空：\(value)")
        }
        for value in ["0", "101.23"] {
            let validTurnover = try QuoteParser.parse(encoded(fixture(symbol, edits: [38: value])), symbols: [symbol])
            try expect(validTurnover[symbol.id]?.turnoverPercent == Double(value), "换手率应允许零和超过100的有限数值：\(value)")
        }
        let beijing = try StockSymbol.parseList("920002")[0]
        let beijingLine = fixture(beijing, name: "万达轴承", edits: [3: "49.92", 4: "49.14", 31: "0.78", 32: "1.59", 36: "11031", 37: "5425.07", 57: "5425.0669"])
        let batch = try QuoteParser.parse(encoded(beijingLine + fixture(symbol)), symbols: [symbol, beijing])
        try expect(batch.count == 2 && batch[beijing.id]?.name == "万达轴承", "应按变量名匹配混合批次，保留空字段并接受不同尾部长度")
        try expect(abs((batch[beijing.id]?.amountYuan ?? 0) - 54_250_669) < 0.001, "北交所成交额也应从万元转换成元")
        let partial = try QuoteParser.parse(encoded(fixture(symbol)), symbols: [symbol, beijing])
        try expect(partial[beijing.id] == nil && partial.count == 1, "缺失行情应省略，不应伪造零价格")
        let foreign = fixture(StockSymbol(code: "000001", market: "sh"))
        try expectError("不应返回未请求证券") { _ = try QuoteParser.parse(encoded(foreign), symbols: [symbol]) }
        for edits in [[1: ""], [2: "000001"], [3: ""], [3: "bad"], [3: "nan"], [3: "inf"], [3: "0"], [4: "-1"], [31: "bad"], [32: "bad"], [36: "bad"], [36: "-1"], [37: "bad", 57: ""], [57: "bad"], [57: "-1"], [30: "20260230145653"], [30: "2026100914565"], [30: "not-a-date"]] {
            try expectError("应省略无效字段：\(edits)") { _ = try QuoteParser.parse(encoded(fixture(symbol, edits: edits)), symbols: [symbol]) }
        }
        let malformed = fixture(symbol, edits: [3: "bad"])
        let mixed = try QuoteParser.parse(encoded(malformed + beijingLine), symbols: [symbol, beijing])
        try expect(mixed[symbol.id] == nil && mixed.count == 1, "一个坏行情不应影响同批次有效行情")
        let zeroTrading = try QuoteParser.parse(encoded(fixture(symbol, edits: [36: "0", 37: "0", 57: "0"])), symbols: [symbol])
        try expect(zeroTrading[symbol.id]?.volumeLots == 0 && zeroTrading[symbol.id]?.amountYuan == 0, "真实零成交量和成交额应保留")
        for data in [Data(), Data("v_pv_none_match=\"1\";".utf8), Data([0xFF, 0xFF]), encoded(fixture(symbol, count: 37)), Data("<html>error</html>".utf8)] {
            try expectError("空、损坏或不完整响应应有可读错误") { _ = try QuoteParser.parse(data, symbols: [symbol]) }
        }
    }
}
