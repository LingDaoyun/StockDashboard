import Foundation
private struct OverviewFailure: Error { let message: String }
private enum Fixtures {
 static let index: Data = {
  var f=Array(repeating:"",count:58)
  for(i,v)in [1:"index",2:"000001",3:"4000",4:"3990",30:"20261020103940",31:"10",32:"0.25",36:"200",37:"300"]{f[i]=v}
  return Data("v_sh000001=\"\(f.joined(separator:"~"))\";".utf8)
 }()
 static func breadth(_ changes:[String:Any]=[:],callback:String="quotebridge_v6_realhead_bk_883957_last")->Data {
  var items:[String:Any]=["38":"3500","39":"1800","37":"5574","5":"883957","name":"同花顺全A(沪深京)","time":"2026-10-20 10:39:28 北京时间"]
  changes.forEach{items[$0.key]=$0.value}
  return Data((callback+"("+String(data:try! JSONSerialization.data(withJSONObject:["items":items]),encoding:.utf8)!+")").utf8)
 }
 static func chart(_ changes:[String:Any]=[:])->Data {
  var c:[String:Any]=["mtime":"2026-10-20 10:39:40","point_key_list":["turnover_pre","timestamp","turnover_change","turnover"],"header":[["key":"turnover_pre","val":1_500_000_000_000],["key":"turnover_change","val":-50_000_000_000],["key":"turnover","val":700_000_000_000]],"point_list":[[750_000_000_000,1_792_464_000_000,-50_000_000_000,700_000_000_000],[800_000_000_000,1_792_464_060_000,NSNull(),NSNull()]]]
  changes.forEach{c[$0.key]=$0.value}
  return try! JSONSerialization.data(withJSONObject:["status_code":0,"data":["charts":c]])
 }
}
private final class OverviewTransport:URLProtocol,@unchecked Sendable {
 private static let lock=NSLock()
 nonisolated(unsafe) private static var mode=0
 nonisolated(unsafe) private static var requests:[URLRequest]=[]
 static func configure(_ n:Int){lock.lock();mode=n;lock.unlock()}
 static func seen()->[URLRequest]{lock.lock();defer{lock.unlock()};return requests}
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading(){
  Self.lock.lock();Self.requests.append(request);let mode=Self.mode;Self.lock.unlock()
  if mode==2{return}
  if mode==3{client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost));return}
  let u=request.url!.absoluteString
  let d=u.contains("gtimg") ? Fixtures.index : u.contains("realhead") ? Fixtures.breadth() : Fixtures.chart()
  let r=HTTPURLResponse(url:request.url!,statusCode:mode==1 ? 503:200,httpVersion:nil,headerFields:nil)!
  client?.urlProtocol(self,didReceive:r,cacheStoragePolicy:.allowed);client?.urlProtocol(self,didLoad:d);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}
@main @MainActor enum MarketOverviewTests {
 static var checks=0
 static func expect(_ b:@autoclosure()->Bool,_ message:String)throws{guard b()else{throw OverviewFailure(message:message)};checks+=1}
 static func parse(_ b:Data=Fixtures.breadth(),_ c:Data=Fixtures.chart())throws->MarketOverviewSnapshot{try MarketOverviewParser.parse(index:Fixtures.index,breadth:b,turnover:c)}
 static func reject(_ b:Data,_ c:Data=Fixtures.chart())throws{
  do{_=try parse(b,c)}catch{checks+=1;return};throw OverviewFailure(message:"malformed response accepted")
 }
 static func main()async{
  do{
   let f=try parse()
   try expect(f.market.advancing==3500 && f.market.declining==1800 && f.market.total==5574,"全A广度")
   try expect(f.market.turnoverYuan==700_000_000_000,"按key取今日额")
   try expect(f.comparison?.previousYuan==750_000_000_000 && f.comparison?.changeYuan == -50_000_000_000,"同刻差额基数")
   try expect(f.comparison?.minute=="10:40" && f.comparison?.previousDate=="上一交易日","桶可向上取整不造日期")
   try expect(f.comparisonNotice==nil,"正确配对")
   try expect(f.market.latestTimestamp.timeIntervalSince(f.market.timestamp)==12,"保留最晚源时刻，最早时间不能遮住较新源")
   let futureBreadth = try parse(Fixtures.breadth(["time":"2026-10-20 10:40:40 北京时间"]))
   try expect(futureBreadth.market.latestTimestamp.timeIntervalSince(futureBreadth.market.timestamp)==60,"广度超前时记录最大源时间")
   let futureChart = try parse(Fixtures.breadth(),Fixtures.chart(["mtime":"2026-10-20 10:41:28"]))
   try expect(futureChart.market.latestTimestamp.timeIntervalSince(futureChart.market.timestamp)==120,"金额超前时记录最大源时间")
   let compatible = AllAMarketQuote(timestamp:f.market.timestamp,advancing:1,declining:1,total:2,turnoverYuan:0)
   try expect(compatible.latestTimestamp==compatible.timestamp,"现有构造默认最大时间")
   try expect(f.market.breadthTimestamp.timeIntervalSince1970 + 12 == f.market.turnoverTimestamp.timeIntervalSince1970,"保留两个真实源时间")
   let switched = try parse(Fixtures.breadth(["time":"2026-10-20 10:39:40 北京时间"]),Fixtures.chart(["mtime":"2026-10-20 10:39:28"]))
   try expect(switched.market.timestamp==f.market.timestamp && switched.market.latestTimestamp==f.market.latestTimestamp,"交叉交换时聚合最值相同")
   try expect(switched.market.turnoverTimestamp < f.market.turnoverTimestamp && switched.market.breadthTimestamp > f.market.breadthTimestamp,"独立源时间暴露成交额倒退")
   try reject(Fixtures.breadth(callback:"evil"));try reject(Fixtures.breadth() + Data(";evil()".utf8))
   for d:[String:Any] in [["38":"-1"],["39":"NaN"],["37":"9999999999999999999999"],["38":"5000","39":"2000"],["5":"883958"],["name":"other"],["time":"2026-02-30 10:39:28 北京时间"],["time":"2026-10-19 10:39:28 北京时间"],["38":true]]{try reject(Fixtures.breadth(d))}
   try reject(Fixtures.breadth(),Fixtures.chart(["mtime":"missing"]))
   for v:Any in [NSNull(),"NaN","1e999",-1]{try reject(Fixtures.breadth(),Fixtures.chart(["header":[["key":"turnover","val":v]]]))}
   let missing=try parse(Fixtures.breadth(),Fixtures.chart(["header":[["key":"turnover","val":700_000_000_000]]]))
   try expect(missing.comparison==nil && missing.comparisonNotice != nil && missing.market.turnoverYuan>0,"缺比较保留金额")
   let bad=try parse(Fixtures.breadth(),Fixtures.chart(["header":[["key":"turnover","val":700_000_000_000],["key":"turnover_change","val":-1]]]))
   try expect(bad.comparison==nil && bad.comparisonNotice != nil,"禁止不一致比较")
   let z=try parse(Fixtures.breadth(),Fixtures.chart(["header":[["key":"turnover","val":0],["key":"turnover_change","val":0]],"point_list":[[0,1_792_464_000_000,0,0]]]))
   try expect(z.market.turnoverYuan==0 && z.comparison==nil,"零额有效但零基数不可比")
   var sessions=0;var config:URLSessionConfiguration?
   let client=MarketOverviewClient(makeSession:{c in sessions+=1;config=c;c.protocolClasses=[OverviewTransport.self];return URLSession(configuration:c)})
   _=try await client.fetch();_=try await client.fetch()
   try expect(sessions==1 && OverviewTransport.seen().count==6,"三源请求会话复用")
   try expect(config?.urlCache==nil && config?.requestCachePolicy == .reloadIgnoringLocalCacheData && config?.timeoutIntervalForResource==6,"无缓存6秒")
   for r in OverviewTransport.seen(){
    try expect(r.timeoutInterval==6 && r.cachePolicy == .reloadIgnoringLocalCacheData,"请求无缓存6秒")
    try expect(r.httpMethod=="GET" && r.url?.scheme=="https","只读HTTPS")
    if r.url?.host?.contains("10jqka")==true{try expect(r.value(forHTTPHeaderField:"Referer")=="https://www.10jqka.com.cn/" && r.value(forHTTPHeaderField:"User-Agent")=="Mozilla/5.0","普通同花顺请求头")}
   }
   OverviewTransport.configure(1)
   do{_=try await client.fetch();throw OverviewFailure(message:"HTTP swallowed")}catch QuoteError.httpStatus(let s){try expect(s==503,"HTTP错误")}
   OverviewTransport.configure(3)
   do{_=try await client.fetch();throw OverviewFailure(message:"disconnect swallowed")}catch is OverviewFailure{throw OverviewFailure(message:"disconnect swallowed")}catch{checks+=1}
   OverviewTransport.configure(0);_=try await client.fetch();try expect(sessions==1,"断线后下轮恢复")
   OverviewTransport.configure(2);let t=Task{try await client.fetch()};try await Task.sleep(nanoseconds:20_000_000);t.cancel()
   do{_=try await t.value;throw OverviewFailure(message:"cancel swallowed")}catch is CancellationError{checks+=1}
   print("PASS MarketOverviewTests: \(checks) assertions")
  }catch{print("FAIL MarketOverviewTests: \(error)");exit(1)}
 }
}
