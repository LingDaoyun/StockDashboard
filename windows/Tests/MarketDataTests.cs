using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace StockDashboard
{
    public static class MarketDataTests
    {
        static int checks;
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        static void Check(bool value, string name) { if (!value) throw new Exception(name); checks++; }
        static void Reject(Action action, string name) { try { action(); } catch (InvalidOperationException) { checks++; return; } throw new Exception(name); }
        static DateTimeOffset Time(string value) { return DateTimeOffset.Parse(value + "+08:00", CultureInfo.InvariantCulture); }
        static byte[] Bytes(string value) { return Encoding.GetEncoding(54936).GetBytes(value); }
        static string QuoteText(string id = "sh600108", IDictionary<int,string> edits = null, int count = 58)
        {
            var f = Enumerable.Repeat("", 58).ToArray();
            f[1] = "亚盛集团"; f[2] = id.Substring(2); f[3] = "3.21"; f[4] = "3.23";
            f[9] = "3.22"; f[19] = "3.23"; f[30] = "20261028100000"; f[31] = "-0.02"; f[32] = "-0.62";
            f[36] = "658740"; f[37] = "21165"; f[38] = "3.38"; f[43] = "3.10";
            f[45] = "62.50"; f[46] = "1.44"; f[49] = "0.82"; f[52] = "-22.3"; f[57] = "21164.6626";
            if (edits != null) foreach (var entry in edits) f[entry.Key] = entry.Value;
            return "v_" + id + "=\"" + String.Join("~",f.Take(count)) + "\";";
        }
        static string Intraday(string[] rows, string time = "20261028100000", string id = "sh600108")
        {
            var q = Enumerable.Repeat("", 31).ToArray(); q[2] = id.Substring(2); q[3] = "3.21"; q[4] = "3.23"; q[30] = time;
            return Json.Serialize(new { code = 0, data = new Dictionary<string,object> { {id, new { data = new { date = "20261028", data = rows }, qt = new Dictionary<string,object> { { id,q }, {"other", true} } }} } });
        }
        static string Breadth(int up = 3500, int down = 1800) { return "quotebridge_v6_realhead_bk_883957_last(" + Json.Serialize(new { items = new Dictionary<string,object> { {"5","883957"}, {"name","同花顺全A(沪深京)"}, {"38",up}, {"39",down}, {"37",5574}, {"time","2026-10-28 10:00:00 北京时间"} } }) + ");"; }
        static string Turnover(decimal prior = 750000000000m, bool badDelta = false, long? overrideMilliseconds = null)
        {
            long ms = overrideMilliseconds ?? (long)(Time("2026-10-28T10:01:00").ToUniversalTime() - new DateTimeOffset(1970,1,1,0,0,0,TimeSpan.Zero)).TotalMilliseconds;
            return Json.Serialize(new { status_code=0, data=new { charts=new { mtime="2026-10-28 10:00:12", header=new object[] { new {key="turnover",val=700000000000m}, new {key="turnover_change",val=-50000000000m} }, point_key_list=new []{"timestamp","turnover","turnover_pre","turnover_change"}, point_list=new object[] {new object[]{ms,700000000000m,prior,badDelta ? 1m : -50000000000m}} } } });
        }
        public static int Run()
        {
            checks = 0;
            var symbols = Symbol.ParseList("600108，002580 sh600108 BJ920002 830799\n300750");
            Check(String.Join(",", symbols.Select(s=>s.Id)) == "sh600108,sz002580,bj920002,bj830799,sz300750", "symbol normalization/order/dedup");
            Check(Symbol.ParseList("sh000001")[0].Market == "sh", "explicit index exchange");
            foreach(var invalid in new[]{"", "12345", "900001", "600108;002580", "６００１０８", "hk00700", "sh600108x"}) Reject(()=>Symbol.ParseList(invalid), "invalid symbol "+invalid);
            Reject(()=>Symbol.ParseList(String.Join(",",Enumerable.Range(0,21).Select(i=>"600"+i.ToString("000")))),"max20");
            var one = new List<Symbol>{symbols[0]};
            var q = MarketDataParser.ParseQuotes(Bytes(QuoteText()),one)["sh600108"];
            Check(q.Name == "亚盛集团" && q.AmountYuan == 211646626m && q.VolumeLots == 658740m,"quote encoding and units");
            Check(q.ChangePercent == -0.62m && q.TurnoverPercent == 3.38m && q.VolumeRatio == .82m && q.AmplitudePercent == 3.10m,"quote percentages");
            Check(q.PeDynamic == -22.3m && q.PbRatio == 1.44m && q.MarketCapYuan == 6250000000m,"quote valuation indices");
            Check(q.Timestamp == Time("2026-10-28T10:00:00"),"China source timestamp");
            Check(q.ValuationPrice(true) == 3.22m && q.ValuationPrice(false) == 3.21m,"auction uses bid");
            var edits = new Dictionary<int,string>{{9,"0"},{19,"bad"},{45,"1e308"},{46,"0"},{52,"NaN"}};
            q = MarketDataParser.ParseQuotes(Bytes(QuoteText(edits:edits)),one)["sh600108"];
            Check(q.ValuationPrice(true)==null && q.Price==3.21m && q.PeDynamic==null && q.PbRatio==null && q.MarketCapYuan==null,"invalid optional values preserve quote");
            q = MarketDataParser.ParseQuotes(Bytes(QuoteText(count:38)),one)["sh600108"];
            Check(q.AmountYuan==211650000m && q.TurnoverPercent==null,"short quote precision fallback");
            foreach(var bad in new Dictionary<int,string>{{3,"0"},{30,"20260230100000"},{36,"-1"},{57,"bad"}}) Reject(()=>MarketDataParser.ParseQuotes(Bytes(QuoteText(edits:new Dictionary<int,string>{{bad.Key,bad.Value}})),one),"invalid required field");
            Reject(()=>MarketDataParser.ParseQuotes(Bytes(QuoteText(edits:new Dictionary<int,string>{{30,"00010101000000"}})),one),"out-of-range UTC timestamp produces readable error");
            var old = QuoteText(edits:new Dictionary<int,string>{{30,"20261028095959"},{3,"9"}});
            Check(MarketDataParser.ParseQuotes(Bytes(QuoteText()+old),one)["sh600108"].Price==3.21m,"duplicate keeps newest source time");
            Check(MarketDataParser.ParseQuotes(Bytes(QuoteText()),symbols).Count==1,"partial batch allowed");
            var search = MarketDataParser.ParseSearch("{\"stock\":[{\"code\":\"sh600108\",\"name\":\"亚盛集团\",\"type\":\"GP-A\"},{\"code\":\"hk06855\",\"name\":\"亚盛医药\",\"type\":\"GP\"},{\"code\":\"sz600108\",\"name\":\"错误\",\"type\":\"GP-A\"}]}");
            Check(search.Count==1 && MarketDataParser.AutomaticMatch(search,"亚盛").Id=="sh600108","search A share filter and automatic match");
            search.Add(new StockSearchResult {Symbol=symbols[1],Name="亚盛测试"});
            Check(MarketDataParser.AutomaticMatch(search,"亚盛")==null && MarketDataParser.AutomaticMatch(search," 亚盛集团 ").Id=="sh600108","ambiguous search requires choice");
            Reject(()=>MarketDataParser.ParseSearch("<html>error</html>"),"search not executable script");
            var chart = MarketDataParser.ParseIntraday(Intraday(new[]{"0930 3.20 100", "0931 3.21 140", "0933 3.22 200"}),symbols[0]);
            Check(chart.Points[0].VolumeLots==100m && chart.Points[1].VolumeLots==40m && chart.Points[2].VolumeLots==null,"chart minute volume gaps");
            chart=MarketDataParser.ParseIntraday(Intraday(new[]{"1130 3.2 100", "1300 3.3 100", "1301 3.4 120"},"20261028130100"),symbols[0]);
            Check(chart.Points[0].VolumeLots==null && chart.Points[1].VolumeLots==0 && chart.Points[2].VolumeLots==20 && chart.Points[1].SessionMinute==120,"compressed lunch axis");
            chart=MarketDataParser.ParseIntraday(Intraday(new[]{"0930 3.2 100", "1500 3.3 200", "1501 3.3 201", "1530 3.3 220"},"20261028161500"),symbols[0]);
            Check(chart.Points.Count==2 && chart.Points.Last().Minute==900,"trim known after-close tail");
            foreach(var rows in new[]{new[]{"0930 3.2 100","0931 3.2 99"},new[]{"0930 3.2 100","0930 3.2 120"},new[]{"1200 3.2 100"},new[]{"1002 3.2 100"},new[]{"1501 3.2 100"}}) Reject(()=>MarketDataParser.ParseIntraday(Intraday(rows),symbols[0]),"invalid intraday sequence");
            var market=MarketDataParser.ParseMarket(Bytes(QuoteText("sh000001")),Breadth(),Turnover());
            Check(market.Advancing==3500 && market.Declining==1800 && market.Total==5574,"all A breadth");
            Check(market.Comparison.PreviousYuan==750000000000m && market.Comparison.ChangeYuan==-50000000000m && market.Comparison.Minute=="10:01","validated same minute comparison");
            Check((market.LatestTimestamp-market.Timestamp).TotalSeconds==12,"retain distinct source timestamps");
            market=MarketDataParser.ParseMarket(Bytes(QuoteText("sh000001")),Breadth(),Turnover(1));
            Check(market.Comparison==null && market.ComparisonNotice!=null && market.TurnoverYuan>0,"bad comparison preserves market");
            market=MarketDataParser.ParseMarket(Bytes(QuoteText("sh000001")),Breadth(),Turnover(overrideMilliseconds:253402300799999));
            Check(market.Comparison==null && market.TurnoverYuan>0,"extreme point timestamp cannot crash market parser");
            Reject(()=>MarketDataParser.ParseMarket(Bytes(QuoteText("sh000001")),Breadth(5000,2000),Turnover()),"breadth must not exceed total");
            var boundaries=new[]{"00:00:00","09:14:00","09:15:00","09:25:00","09:30:00","11:30:00","11:31:00","12:59:00","13:00:00","14:57:00","15:00:00","15:31:00"};
            var phases=new[]{MarketPhase.Closed,MarketPhase.PreOpen,MarketPhase.Auction,MarketPhase.PreOpen,MarketPhase.Trading,MarketPhase.Lunch,MarketPhase.Lunch,MarketPhase.PreOpen,MarketPhase.Trading,MarketPhase.Auction,MarketPhase.PostClose,MarketPhase.Closed};
            var intervals=new[]{60,1,1,1,1,1,30,1,1,1,1,60};
            for(int i=0;i<boundaries.Length;i++){var at=Time("2026-10-28T"+boundaries[i]);var session=MarketClock.GetSession(at); Check(session.Phase==phases[i] && session.PollInterval==intervals[i] && session.NextChange>at,"clock boundary "+boundaries[i]);}
            Check(MarketClock.GetSession(Time("2026-10-01T10:00:00")).Phase==MarketPhase.Closed,"holiday");
            Check(MarketClock.GetSession(Time("2026-10-10T10:00:00")).Phase==MarketPhase.Closed,"adjusted work weekend closed");
            Check(MarketClock.GetSession(Time("2027-01-01T10:00:00")).Phase==MarketPhase.CalendarUnknown,"unconfirmed year");
            var now=Time("2026-10-28T10:00:00");var live=MarketClock.GetSession(now);
            Check(!MarketClock.IsStale(now.AddSeconds(-15),now,live) && MarketClock.IsStale(now.AddSeconds(-16),now,live),"stale boundary");
            Check(!MarketClock.IsStale(now.AddDays(-3),now,MarketClock.GetSession(Time("2026-10-28T12:00:00"))),"lunch snapshot not stale");
            Check(MarketClock.AgeText(now.AddSeconds(-119),now)=="1分钟前" && MarketClock.AgeText(now.AddSeconds(1),now)=="刚刚","age format");
            Transport().GetAwaiter().GetResult();
            Console.WriteLine("PASS MarketData: " + checks + " assertions"); return checks;
        }
        public static int Main(string[] args)
        {
            try { Run(); if(args.Contains("--live")) Live().GetAwaiter().GetResult(); return 0; }
            catch(Exception e) { Console.WriteLine("FAIL: "+e); return 1; }
        }
        sealed class Probe : HttpMessageHandler
        {
            public readonly List<HttpRequestMessage> Requests=new List<HttpRequestMessage>();
            public Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> Reply;
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
            {
                Requests.Add(request);return Reply(request,token);
            }
        }
        static HttpResponseMessage Response(byte[] bytes,HttpStatusCode status=HttpStatusCode.OK) {return new HttpResponseMessage(status){Content=new ByteArrayContent(bytes)};}
        static async Task Transport()
        {
            var probe=new Probe();
            probe.Reply=(request,token)=>Task.FromResult(Response(Bytes(QuoteText())));
            using(var client=new MarketDataClient(probe))
            {
                var token=CancellationToken.None;var list=Symbol.ParseList("600108");
                var quotes=await client.FetchQuotesAsync(list,token);Check(quotes.Count==1,"transport parses bytes");
                var request=probe.Requests.Last();
                Check(request.Method==HttpMethod.Get && request.RequestUri.AbsoluteUri=="https://qt.gtimg.cn/q=sh600108" && request.Headers.CacheControl.NoCache && request.Headers.CacheControl.NoStore,"transport fixed HTTPS GET and no cache");
                var empty=await client.FetchQuotesAsync(new List<Symbol>(),token);Check(empty.Count==0 && probe.Requests.Count==1,"empty quote list no network");
                probe.Reply=(r,t)=>Task.FromResult(Response(Encoding.UTF8.GetBytes("{\"stock\":[]}")));
                var results=await client.SearchAsync(" a&stockFlag=0#x+中 ",token);
                Check(results.Count==0 && probe.Requests.Last().RequestUri.AbsoluteUri.Contains("query=a%26stockFlag%3D0%23x%2B%E4%B8%AD"),"search escapes parameter injection plus and Unicode");
                int before=probe.Requests.Count;
                try {await client.SearchAsync(" ",token);throw new Exception("empty search accepted");}catch(InvalidOperationException){Check(probe.Requests.Count==before,"empty search rejected before HTTP");}
                probe.Reply=(r,t)=>Task.FromResult(Response(new byte[0],HttpStatusCode.ServiceUnavailable));
                try {await client.FetchQuotesAsync(list,token);throw new Exception("HTTP503 accepted");}catch(InvalidOperationException ex){Check(ex.Message.Contains("503"),"HTTP status retained");}
                probe.Reply=(r,t)=>{throw new HttpRequestException("offline");};
                try {await client.FetchQuotesAsync(list,token);throw new Exception("network fault accepted");}catch(InvalidOperationException ex){Check(ex.Message.Contains("offline"),"network failure readable");}
                probe.Reply=(r,t)=>{var completion=new TaskCompletionSource<HttpResponseMessage>();completion.SetCanceled();return completion.Task;};
                try {await client.FetchQuotesAsync(list,token);throw new Exception("timeout accepted");}catch(InvalidOperationException ex){Check(ex.Message.Contains("超时"),"non-user timeout is readable");}
                before=probe.Requests.Count;
                using(var canceled=new CancellationTokenSource())
                {
                    canceled.Cancel();
                    try {await client.FetchQuotesAsync(list,canceled.Token);throw new Exception("cancellation swallowed");}catch(OperationCanceledException){Check(probe.Requests.Count==before,"pre-canceled request sends nothing");}
                }
                probe.Reply=async (r,t)=>{await Task.Delay(1000,t);return Response(Bytes(QuoteText()));};
                using(var canceled=new CancellationTokenSource())
                {
                    canceled.CancelAfter(20);
                    try {await client.FetchQuotesAsync(list,canceled.Token);throw new Exception("active cancellation swallowed");}catch(OperationCanceledException){checks++;}
                }
                probe.Reply=(r,t)=>Task.FromResult(Response(Bytes(QuoteText())));
                Check((await client.FetchQuotesAsync(list,token)).Count==1,"same client recovers after HTTP network timeout cancellation");
                probe.Reply=(r,t)=>
                {
                    if(r.RequestUri.Host=="qt.gtimg.cn") return Task.FromResult(Response(Bytes(QuoteText("sh000001"))));
                    Check(r.Headers.UserAgent.ToString()=="Mozilla/5.0" && r.Headers.Referrer.AbsoluteUri=="https://www.10jqka.com.cn/","THS required ordinary request headers");
                    return Task.FromResult(Response(Encoding.UTF8.GetBytes(r.RequestUri.Host=="d.10jqka.com.cn" ? Breadth() : Turnover())));
                };
                var market=await client.FetchMarketAsync(token);Check(market.Comparison!=null,"parallel market transport aggregation");
            }
        }
        static async Task Live()
        {
            using(var client=new MarketDataClient())
            {
                var token=CancellationToken.None;var list=Symbol.ParseList("600108,002580,bj920002");
                var q=await client.FetchQuotesAsync(list,token);Check(q.Count==3,"live quotes");
                var s=await client.SearchAsync("亚盛",token);Check(s.Any(x=>x.Id=="sh600108"),"live search");
                var c=await client.FetchIntradayAsync(list[0],token);Check(c.Points.Count>0 && c.Points.Last().Minute<=900,"live intraday");
                var m=await client.FetchMarketAsync(token);Check(m.Total>0 && m.TurnoverYuan>=0,"live market");
                Console.WriteLine("PASS LIVE: 5 endpoints; "+q["sh600108"].Name+"="+q["sh600108"].Price+"; chart points="+c.Points.Count+"; total="+m.Total+"; comparison="+(m.Comparison!=null));
            }
        }
    }
}
