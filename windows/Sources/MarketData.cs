using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace StockDashboard
{
    public sealed class Symbol
    {
        public string Code { get; set; }
        public string Market { get; set; }
        public string Id { get { return Market + Code; } }

        public static List<Symbol> ParseList(string text)
        {
            var tokens = Regex.Split((text ?? "").ToLowerInvariant(), @"[\s,，]+").Where(t => t.Length > 0);
            var result = new List<Symbol>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string token in tokens)
            {
                string market = new[] { "sh", "sz", "bj" }.FirstOrDefault(m => token.StartsWith(m, StringComparison.Ordinal));
                string code = market == null ? token : token.Substring(2);
                if (!Regex.IsMatch(code, @"\A[0-9]{6}\z")) throw Invalid(token);
                if (market == null)
                {
                    if (code.StartsWith("6")) market = "sh";
                    else if (code.StartsWith("0") || code.StartsWith("3")) market = "sz";
                    else if (code.StartsWith("4") || code.StartsWith("8") || code.StartsWith("92")) market = "bj";
                    else throw Invalid(token);
                }
                var symbol = new Symbol { Code = code, Market = market };
                if (seen.Add(symbol.Id)) result.Add(symbol);
            }
            if (result.Count == 0) throw new InvalidOperationException("请输入至少一个股票代码。");
            if (result.Count > 20) throw new InvalidOperationException("最多显示20只股票，请减少代码数量。");
            return result;
        }
        static Exception Invalid(string token) { return new InvalidOperationException("股票代码“" + token + "”格式不支持，请输入六位代码或 sh、sz、bj 前缀。"); }
    }

    public sealed class Quote
    {
        public string SymbolId { get; set; }
        public string Name { get; set; }
        public decimal Price { get; set; }
        public decimal PreviousClose { get; set; }
        public decimal Change { get; set; }
        public decimal ChangePercent { get; set; }
        public decimal VolumeLots { get; set; }
        public decimal AmountYuan { get; set; }
        public DateTimeOffset Timestamp { get; set; }
        public decimal? BidPrice { get; set; }
        public decimal? AskPrice { get; set; }
        public decimal? TurnoverPercent { get; set; }
        public decimal? VolumeRatio { get; set; }
        public decimal? AmplitudePercent { get; set; }
        public decimal? PeDynamic { get; set; }
        public decimal? PbRatio { get; set; }
        public decimal? MarketCapYuan { get; set; }
        public decimal? ValuationPrice(bool isAuction) { return isAuction ? BidPrice ?? AskPrice : Price; }
    }

    public sealed class StockSearchResult
    {
        public Symbol Symbol { get; set; }
        public string Name { get; set; }
        public string Id { get { return Symbol.Id; } }
    }

    public sealed class IntradayPoint
    {
        public int Minute { get; set; }
        public decimal Price { get; set; }
        public decimal CumulativeVolumeLots { get; set; }
        public decimal? VolumeLots { get; set; }
        public int SessionMinute { get { return Minute <= 690 ? Minute - 570 : Minute - 780 + 120; } }
        public string TimeText { get { return (Minute / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (Minute % 60).ToString("00", CultureInfo.InvariantCulture); } }
    }

    public sealed class IntradaySnapshot
    {
        public string SymbolId { get; set; }
        public string Date { get; set; }
        public DateTimeOffset Timestamp { get; set; }
        public decimal PreviousClose { get; set; }
        public List<IntradayPoint> Points { get; set; }
    }

    public sealed class MarketComparison
    {
        public string Minute { get; set; }
        public string PreviousDate { get; set; }
        public decimal CurrentYuan { get; set; }
        public decimal PreviousYuan { get; set; }
        public decimal ChangeYuan { get { return CurrentYuan - PreviousYuan; } }
    }

    public sealed class MarketOverviewSnapshot
    {
        public Quote Index { get; set; }
        public int Advancing { get; set; }
        public int Declining { get; set; }
        public int Total { get; set; }
        public decimal TurnoverYuan { get; set; }
        public DateTimeOffset BreadthTimestamp { get; set; }
        public DateTimeOffset TurnoverTimestamp { get; set; }
        public DateTimeOffset Timestamp { get { return BreadthTimestamp < TurnoverTimestamp ? BreadthTimestamp : TurnoverTimestamp; } }
        public DateTimeOffset LatestTimestamp { get { return BreadthTimestamp > TurnoverTimestamp ? BreadthTimestamp : TurnoverTimestamp; } }
        public MarketComparison Comparison { get; set; }
        public string ComparisonNotice { get; set; }
    }

    public enum MarketPhase { Trading, PreOpen, Auction, Lunch, PostClose, Closed, CalendarUnknown }

    public sealed class MarketSession
    {
        public MarketPhase Phase { get; set; }
        public int PollInterval { get; set; }
        public DateTimeOffset NextChange { get; set; }
        public bool CalendarKnown { get; set; }
        public bool ExpectsFreshQuotes { get { return Phase == MarketPhase.Trading; } }
        public string Label
        {
            get
            {
                switch (Phase)
                {
                    case MarketPhase.Trading: return "报价";
                    case MarketPhase.PreOpen: return "盘前快照";
                    case MarketPhase.Auction: return "竞价快照";
                    case MarketPhase.Lunch: return "午休快照";
                    case MarketPhase.PostClose: return "盘后快照";
                    case MarketPhase.CalendarUnknown: return "日历待更新";
                    default: return "休市快照";
                }
            }
        }
    }

    public static class MarketClock
    {
        public static readonly TimeSpan ChinaOffset = TimeSpan.FromHours(8);
        public static DateTimeOffset ChinaNow { get { return DateTimeOffset.UtcNow.ToOffset(ChinaOffset); } }
        static readonly int[,] Holidays2026 = { {101,103}, {215,223}, {404,406}, {501,505}, {619,621}, {925,927}, {1001,1007} };
        static readonly int[] Boundaries = {33240,33300,33900,34200,41400,41460,46740,46800,53820,54000,55860,86400};
        static readonly MarketPhase[] Phases = { MarketPhase.Closed, MarketPhase.PreOpen, MarketPhase.Auction, MarketPhase.PreOpen, MarketPhase.Trading, MarketPhase.Lunch, MarketPhase.Lunch, MarketPhase.PreOpen, MarketPhase.Trading, MarketPhase.Auction, MarketPhase.PostClose, MarketPhase.Closed };
        static readonly int[] Intervals = {60,1,1,1,1,1,30,1,1,1,1,60};

        public static MarketSession At(DateTimeOffset now) { return GetSession(now); }
        public static MarketSession GetSession(DateTimeOffset now)
        {
            var local = now.ToOffset(ChinaOffset);
            var start = new DateTimeOffset(local.Year,local.Month,local.Day,0,0,0,ChinaOffset);
            bool known = local.Year == 2026;
            bool holiday = local.DayOfWeek == DayOfWeek.Saturday || local.DayOfWeek == DayOfWeek.Sunday;
            int md = local.Month * 100 + local.Day;
            if (known) for (int i=0;i<Holidays2026.GetLength(0);i++) holiday |= md >= Holidays2026[i,0] && md <= Holidays2026[i,1];
            if (holiday) return new MarketSession { Phase=MarketPhase.Closed, PollInterval=60, NextChange=start.AddDays(1), CalendarKnown=known };
            if (!known) return new MarketSession { Phase=MarketPhase.CalendarUnknown, PollInterval=1, NextChange=start.AddDays(1), CalendarKnown=false };
            double elapsed = (local-start).TotalSeconds;
            for (int i=0;i<Boundaries.Length;i++) if (elapsed < Boundaries[i]) return new MarketSession { Phase=Phases[i], PollInterval=Intervals[i], NextChange=start.AddSeconds(Boundaries[i]), CalendarKnown=true };
            throw new InvalidOperationException("交易时间无法识别。");
        }
        public static bool IsStale(DateTimeOffset timestamp, DateTimeOffset now, MarketSession session) { return session.ExpectsFreshQuotes && (now-timestamp).TotalSeconds > 15; }
        public static string AgeText(DateTimeOffset timestamp, DateTimeOffset now)
        {
            double age=(now-timestamp).TotalSeconds;
            if(age<1) return "刚刚";
            if(age<60) return Math.Floor(age).ToString(CultureInfo.InvariantCulture)+"秒前";
            if(age<3600) return Math.Floor(age/60).ToString(CultureInfo.InvariantCulture)+"分钟前";
            if(age<86400) return Math.Floor(age/3600).ToString(CultureInfo.InvariantCulture)+"小时前";
            return Math.Floor(age/86400).ToString(CultureInfo.InvariantCulture)+"天前";
        }
    }

    public static class MarketDataParser
    {
        static readonly Regex QuotePattern = new Regex(@"v_((?:sh|sz|bj)[0-9]{6})\s*=\s*""([^""]*)""\s*;", RegexOptions.CultureInvariant);
        static InvalidOperationException Error(string text) { return new InvalidOperationException(text); }
        static Dictionary<string,object> Map(object value) { return value as Dictionary<string,object>; }
        static object Get(Dictionary<string,object> value,string key) { object result; return value != null && value.TryGetValue(key,out result) ? result : null; }
        static IList List(object value) { return value as IList; }
        static Dictionary<string,object> ReadJson(string text,string error)
        {
            try { var map=Map(new JavaScriptSerializer { MaxJsonLength=8*1024*1024 }.DeserializeObject(text)); if(map==null) throw Error(error); return map; }
            catch(ArgumentException) { throw Error(error); }
            catch(InvalidOperationException) { throw Error(error); }
        }
        static decimal? Number(object value)
        {
            if(value==null || value is bool) return null;
            string text=value as string;
            if(text!=null && (text.Length==0 || text!=text.Trim())) return null;
            decimal number;
            return Decimal.TryParse(text ?? Convert.ToString(value,CultureInfo.InvariantCulture),NumberStyles.Float,CultureInfo.InvariantCulture,out number) ? (decimal?)number : null;
        }
        static decimal? Field(string[] fields,int index) { return index<fields.Length ? Number(fields[index]) : null; }
        static decimal? Positive(decimal? value) { return value>0 ? value : null; }
        static decimal? Nonnegative(decimal? value) { return value>=0 ? value : null; }
        static decimal? Nonzero(decimal? value) { return value!=null && value!=0 ? value : null; }
        static decimal? Multiply(decimal? value,decimal scale) { if(value==null) return null; try { return value.Value*scale; } catch(OverflowException) { return null; } }
        static int? Integer(object value) { var n=Number(value); return n!=null && n>=0 && n<=Int32.MaxValue && Decimal.Truncate(n.Value)==n ? (int?)n.Value : null; }
        static DateTimeOffset? Date(string text,string format)
        {
            DateTime date;
            if(text==null || !DateTime.TryParseExact(text,format,CultureInfo.InvariantCulture,DateTimeStyles.None,out date) || date.ToString(format,CultureInfo.InvariantCulture)!=text) return null;
            try { return new DateTimeOffset(DateTime.SpecifyKind(date,DateTimeKind.Unspecified),MarketClock.ChinaOffset); }
            catch(ArgumentOutOfRangeException) { return null; }
        }
        static bool SameDay(DateTimeOffset a,DateTimeOffset b)
        {
            try { return a.ToOffset(MarketClock.ChinaOffset).Date==b.ToOffset(MarketClock.ChinaOffset).Date; }
            catch(ArgumentOutOfRangeException) { return false; }
        }

        public static Dictionary<string,Quote> ParseQuotes(byte[] bytes,IList<Symbol> symbols)
        {
            string text;
            try { text=Encoding.GetEncoding(54936,EncoderFallback.ExceptionFallback,DecoderFallback.ExceptionFallback).GetString(bytes); }
            catch(ArgumentException) { throw Error("行情响应编码无法识别，请稍后刷新。"); }
            var wanted=symbols.GroupBy(s=>s.Id).ToDictionary(g=>g.Key,g=>g.First());
            var result=new Dictionary<string,Quote>();
            foreach(Match match in QuotePattern.Matches(text))
            {
                Symbol symbol; string id=match.Groups[1].Value;
                if(!wanted.TryGetValue(id,out symbol)) continue;
                var f=match.Groups[2].Value.Split('~');
                if(f.Length<38) continue;
                var price=Positive(Field(f,3));var previous=Nonnegative(Field(f,4));var change=Field(f,31);var percent=Field(f,32);
                var volume=Nonnegative(Field(f,36));var amount=Multiply(Nonnegative(f.Length>57 && f[57].Length>0 ? Field(f,57) : Field(f,37)),10000m);
                var timestamp=Date(f[30],"yyyyMMddHHmmss");
                if(String.IsNullOrWhiteSpace(f[1]) || f[2]!=symbol.Code || price==null || previous==null || change==null || percent==null || volume==null || amount==null || timestamp==null) continue;
                Quote cached; if(result.TryGetValue(id,out cached) && cached.Timestamp>timestamp) continue;
                result[id]=new Quote { SymbolId=id,Name=f[1].Trim(),Price=price.Value,PreviousClose=previous.Value,Change=change.Value,ChangePercent=percent.Value,VolumeLots=volume.Value,AmountYuan=amount.Value,Timestamp=timestamp.Value,
                    BidPrice=Positive(Field(f,9)),AskPrice=Positive(Field(f,19)),TurnoverPercent=Nonnegative(Field(f,38)),VolumeRatio=Nonnegative(Field(f,49)),AmplitudePercent=Nonnegative(Field(f,43)),PeDynamic=Nonzero(Field(f,52)),PbRatio=Nonzero(Field(f,46)),MarketCapYuan=Multiply(Positive(Field(f,45)),100000000m) };
            }
            if(result.Count==0) throw Error("没有获取到有效行情，请检查股票代码或稍后刷新。");
            return result;
        }

        public static List<StockSearchResult> ParseSearch(string json)
        {
            const string error="股票搜索响应无法识别，请稍后重试或输入代码。";
            var rows=List(Get(ReadJson(json,error),"stock")); if(rows==null) throw Error(error);
            var result=new List<StockSearchResult>();var seen=new HashSet<string>();
            foreach(object row in rows)
            {
                var item=Map(row);var id=Get(item,"code") as string;var name=Get(item,"name") as string;var type=Get(item,"type") as string;
                if(id==null || id.Length!=8 || String.IsNullOrWhiteSpace(name) || !(type=="GP-A" || type=="GP-A-CYB" || type=="GP-A-KCB")) continue;
                Symbol symbol;try {symbol=Symbol.ParseList(id.Substring(2))[0];} catch(InvalidOperationException) {continue;}
                name=name.Trim();if(symbol.Id!=id || name.Any(Char.IsControl) || !seen.Add(id)) continue;
                result.Add(new StockSearchResult {Symbol=symbol,Name=name});
            }
            return result;
        }
        public static StockSearchResult AutomaticMatch(IList<StockSearchResult> results,string query)
        {
            var exact=results.Where(r=>r.Name==(query??"").Trim()).ToList();
            return exact.Count==1 ? exact[0] : results.Count==1 ? results[0] : null;
        }
        static int? Minute(string text)
        {
            if(text==null || !Regex.IsMatch(text,@"\A[0-9]{4}\z")) return null;
            int h=Int32.Parse(text.Substring(0,2),CultureInfo.InvariantCulture),m=Int32.Parse(text.Substring(2,2),CultureInfo.InvariantCulture);
            return h<24 && m<60 ? (int?)(h*60+m) : null;
        }
        public static IntradaySnapshot ParseIntraday(string json,Symbol symbol)
        {
            const string error="没有获取到有效分时数据，请稍后刷新。";
            if(symbol==null || !(symbol.Market=="sh" || symbol.Market=="sz" || symbol.Market=="bj")) throw Error("该市场暂不支持分时图。");
            var root=ReadJson(json,error);var payload=Map(Get(Map(Get(root,"data")),symbol.Id));
            var qt=List(Get(Map(Get(payload,"qt")),symbol.Id));var data=Map(Get(payload,"data"));var rows=List(Get(data,"data"));
            if(Integer(Get(root,"code"))!=0 || qt==null || qt.Count<=30 || (qt[2] as string)!=symbol.Code || Positive(Number(qt[3]))==null || Positive(Number(qt[4]))==null || rows==null || rows.Count==0) throw Error(error);
            string day=Get(data,"date") as string,time=qt[30] as string;var timestamp=Date(time,"yyyyMMddHHmmss");
            if(day==null || !Regex.IsMatch(day,@"\A[0-9]{8}\z") || timestamp==null || !time.StartsWith(day,StringComparison.Ordinal)) throw Error(error);
            int sourceMinute=timestamp.Value.Hour*60+timestamp.Value.Minute;
            var points=new List<IntradayPoint>();int? previousMinute=null;decimal? previousVolume=null;
            foreach(object value in rows)
            {
                string row=value as string;if(row==null) throw Error(error);var f=Regex.Split(row.Trim(),@"\s+");
                if(f.Length<3) throw Error(error);var minute=Minute(f[0]);var price=Positive(Number(f[1]));var cumulative=Nonnegative(Number(f[2]));
                if(minute==null || !((minute>=570 && minute<=690)||(minute>=780 && minute<=930)) || minute>sourceMinute+1 || price==null || cumulative==null || (previousMinute!=null && minute<=previousMinute) || (previousVolume!=null && cumulative<previousVolume)) throw Error(error);
                previousMinute=minute;previousVolume=cumulative;
                if(minute>900) {if(points.Count==0 || points[points.Count-1].Minute!=900) throw Error(error);continue;}
                decimal? volume=null;
                if(points.Count>0) {var prev=points[points.Count-1];if(minute==prev.Minute+1 || (prev.Minute==690 && minute==780)) volume=cumulative-prev.CumulativeVolumeLots;}
                else if(minute==570) volume=cumulative;
                points.Add(new IntradayPoint {Minute=minute.Value,Price=price.Value,CumulativeVolumeLots=cumulative.Value,VolumeLots=volume});
            }
            return new IntradaySnapshot {SymbolId=symbol.Id,Date=day,Timestamp=timestamp.Value,PreviousClose=Number(qt[4]).Value,Points=points};
        }
        public static MarketOverviewSnapshot ParseMarket(byte[] index,string breadth,string turnover)
        {
            var quote=ParseQuotes(index,new List<Symbol>{new Symbol {Code="000001",Market="sh"}})["sh000001"];
            const string prefix="quotebridge_v6_realhead_bk_883957_last(";
            string text=(breadth??"").Trim();if(text.EndsWith(";")) text=text.Substring(0,text.Length-1).Trim();
            if(!text.StartsWith(prefix,StringComparison.Ordinal) || !text.EndsWith(")",StringComparison.Ordinal)) throw Error("大盘涨跌家数数据无效，请稍后刷新。");
            var items=Map(Get(ReadJson(text.Substring(prefix.Length,text.Length-prefix.Length-1),"大盘涨跌家数数据无效。"),"items"));
            var up=Integer(Get(items,"38"));var down=Integer(Get(items,"39"));var total=Integer(Get(items,"37"));var source=Get(items,"time") as string;
            const string suffix=" 北京时间";
            var breadthTime=source!=null && source.EndsWith(suffix,StringComparison.Ordinal) ? Date(source.Substring(0,source.Length-suffix.Length),"yyyy-MM-dd HH:mm:ss") : null;
            if((Get(items,"5") as string)!="883957" || (Get(items,"name") as string)!="同花顺全A(沪深京)" || up==null || down==null || total==null || total<=0 || up>total || down>total-up || breadthTime==null) throw Error("大盘涨跌家数数据无效，请稍后刷新。");
            var root=ReadJson(turnover,"大盘成交额数据无效。");var chart=Map(Get(Map(Get(root,"data")),"charts"));
            var amountTime=Date(Get(chart,"mtime") as string,"yyyy-MM-dd HH:mm:ss");var header=List(Get(chart,"header"));var amount=Nonnegative(HeaderNumber(header,"turnover"));
            if(Integer(Get(root,"status_code"))!=0 || amountTime==null || !SameDay(breadthTime.Value,amountTime.Value) || amount==null) throw Error("大盘成交额数据无效，请稍后刷新。");
            MarketComparison comparison;try {comparison=Comparison(chart,header,amount.Value,amountTime.Value);} catch(OverflowException) {comparison=null;}
            return new MarketOverviewSnapshot {Index=quote,Advancing=up.Value,Declining=down.Value,Total=total.Value,TurnoverYuan=amount.Value,BreadthTimestamp=breadthTime.Value,TurnoverTimestamp=amountTime.Value,Comparison=comparison,ComparisonNotice=comparison==null?"昨日同刻成交额暂不可用":null};
        }
        static decimal? HeaderNumber(IList header,string key)
        {
            if(header==null) return null;var matches=header.Cast<object>().Select(Map).Where(row=>(Get(row,"key") as string)==key).ToList();return matches.Count==1 ? Number(Get(matches[0],"val")) : null;
        }
        static bool Close(decimal a,decimal b) { return Math.Abs(a-b)<=.02m; }
        static MarketComparison Comparison(Dictionary<string,object> chart,IList header,decimal amount,DateTimeOffset sourceTime)
        {
            var delta=HeaderNumber(header,"turnover_change");var keys=List(Get(chart,"point_key_list"));var points=List(Get(chart,"point_list"));
            if(delta==null || keys==null || points==null || keys.Cast<object>().Any(k=>!(k is string)) || keys.Cast<object>().Distinct().Count()!=keys.Count) return null;
            var columns=keys.Cast<string>().ToList();int t=columns.IndexOf("timestamp"),c=columns.IndexOf("turnover"),p=columns.IndexOf("turnover_pre"),d=columns.IndexOf("turnover_change");
            if(t<0 || c<0 || p<0 || d<0) return null;int needed=Math.Max(Math.Max(t,c),Math.Max(p,d));
            DateTimeOffset? latest=null;decimal current=0;decimal? prior=null,pointDelta=null;
            foreach(object row in points)
            {
                var point=List(row);if(point==null || point.Count<=needed) continue;var ms=Number(point[t]);var n=Nonnegative(Number(point[c]));
                if(ms==null || ms<0 || ms>=253402300800000m || n==null) continue;
                DateTimeOffset stamp;try {stamp=new DateTimeOffset(1970,1,1,0,0,0,TimeSpan.Zero).AddTicks((long)(ms.Value*TimeSpan.TicksPerMillisecond));} catch(ArgumentOutOfRangeException) {continue;}
                if(!SameDay(stamp,sourceTime)) continue;
                if(latest==null || stamp>latest) {latest=stamp;current=n.Value;prior=Number(point[p]);pointDelta=Number(point[d]);}
            }
            if(latest==null || prior==null || prior<=0 || pointDelta==null || !Close(current,amount) || !Close(pointDelta.Value,delta.Value) || amount-delta<=0 || !Close(current-prior.Value,delta.Value) || !Close(amount-delta.Value,prior.Value)) return null;
            return new MarketComparison {Minute=latest.Value.ToOffset(MarketClock.ChinaOffset).ToString("HH:mm",CultureInfo.InvariantCulture),PreviousDate="上一交易日",CurrentYuan=amount,PreviousYuan=amount-delta.Value};
        }
    }

    public sealed class MarketDataClient : IDisposable
    {
        readonly HttpClient client;
        public MarketDataClient() : this(new HttpClientHandler {AutomaticDecompression=DecompressionMethods.GZip|DecompressionMethods.Deflate}) { }
        public MarketDataClient(HttpMessageHandler handler)
        {
            // TLS 1.2 is required by the public HTTPS endpoints on older framework defaults.
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            client=new HttpClient(handler,true) {Timeout=TimeSpan.FromSeconds(6)};
            client.DefaultRequestHeaders.CacheControl=new CacheControlHeaderValue {NoCache=true,NoStore=true};
        }
        async Task<byte[]> Load(string address,CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            using(var request=new HttpRequestMessage(HttpMethod.Get,address))
            {
                if(request.RequestUri.Host.EndsWith("10jqka.com.cn",StringComparison.OrdinalIgnoreCase)) {request.Headers.TryAddWithoutValidation("User-Agent","Mozilla/5.0");request.Headers.Referrer=new Uri("https://www.10jqka.com.cn/");}
                try
                {
                    using(var response=await client.SendAsync(request,HttpCompletionOption.ResponseContentRead,token).ConfigureAwait(false))
                    {
                        if(response.StatusCode!=HttpStatusCode.OK) throw new InvalidOperationException("行情服务返回异常状态（"+(int)response.StatusCode+"），请稍后刷新。");
                        var bytes=await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);token.ThrowIfCancellationRequested();return bytes;
                    }
                }
                catch(OperationCanceledException) {token.ThrowIfCancellationRequested();throw new InvalidOperationException("行情请求超时，请稍后刷新。");}
                catch(HttpRequestException ex) {throw new InvalidOperationException("行情请求失败："+ex.Message,ex);}
            }
        }
        public async Task<Dictionary<string,Quote>> FetchQuotesAsync(IList<Symbol> symbols,CancellationToken token)
        {
            token.ThrowIfCancellationRequested();if(symbols.Count==0) return new Dictionary<string,Quote>();
            var normalized=Symbol.ParseList(String.Join(",",symbols.Select(s=>s.Id)));
            var bytes=await Load("https://qt.gtimg.cn/q="+String.Join(",",normalized.Select(s=>s.Id)),token).ConfigureAwait(false);
            return MarketDataParser.ParseQuotes(bytes,normalized);
        }
        public async Task<List<StockSearchResult>> SearchAsync(string query,CancellationToken token)
        {
            token.ThrowIfCancellationRequested();var text=(query??"").Trim();if(text.Length==0) throw new InvalidOperationException("请输入股票名称或代码。");
            var bytes=await Load("https://proxy.finance.qq.com/cgi/cgi-bin/smartbox/search?stockFlag=1&fundFlag=1&app=official_website&c=1&query="+Uri.EscapeDataString(text),token).ConfigureAwait(false);
            return MarketDataParser.ParseSearch(Encoding.UTF8.GetString(bytes));
        }
        public async Task<IntradaySnapshot> FetchIntradayAsync(Symbol symbol,CancellationToken token)
        {
            var normalized=Symbol.ParseList(symbol.Id);if(normalized.Count!=1 || normalized[0].Id!=symbol.Id) throw new InvalidOperationException("股票代码格式不支持。");
            var bytes=await Load("https://web.ifzq.gtimg.cn/appstock/app/minute/query?code="+symbol.Id,token).ConfigureAwait(false);
            return MarketDataParser.ParseIntraday(Encoding.UTF8.GetString(bytes),symbol);
        }
        public async Task<MarketOverviewSnapshot> FetchMarketAsync(CancellationToken token)
        {
            var index=Load("https://qt.gtimg.cn/q=sh000001",token);
            var breadth=Load("https://d.10jqka.com.cn/v6/realhead/bk_883957/last.js",token);
            var turnover=Load("https://dq.10jqka.com.cn/fuyao/market_analysis_api/chart/v1/get_chart_data?chart_key=turnover_minute",token);
            await Task.WhenAll(index,breadth,turnover).ConfigureAwait(false);
            return MarketDataParser.ParseMarket(index.Result,Encoding.UTF8.GetString(breadth.Result),Encoding.UTF8.GetString(turnover.Result));
        }
        public void Dispose() {client.Dispose();}
    }
}
