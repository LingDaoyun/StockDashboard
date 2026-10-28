using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace StockDashboard
{
    internal sealed class MainWindow : Window
    {
        readonly SettingsStore storage;
        readonly AppSettings settings;
        readonly MarketDataClient client = new MarketDataClient();
        readonly Dictionary<string, Quote> quotes = new Dictionary<string, Quote>();
        readonly Dictionary<string, Card> cards = new Dictionary<string, Card>();
        readonly Dictionary<string, string> quoteIssues = new Dictionary<string, string>();
        readonly DispatcherTimer timer = new DispatcherTimer();
        readonly DispatcherTimer debounce = new DispatcherTimer();
        CancellationTokenSource lifetime = new CancellationTokenSource(), searchCancel, chartCancel;
        DesktopIntegration desktop;
        StackPanel list, addPanel, optionsPanel;
        ScrollViewer scroll;
        TextBox search;
        Popup candidates;
        StackPanel resultList;
        TextBlock status, total, indexValue, breadthValue, turnoverValue, message, modeLabel;
        Border surface;
        Button pinButton, dockButton;
        string expandedEditor, expandedChart, notice, quoteError, marketError, chartError;
        bool quoteBusy, marketBusy, chartBusy, suspended, closed;
        DateTimeOffset nextQuote, nextMarket, nextChart, lastReceipt;
        MarketPhase previousPhase;
        MarketOverviewSnapshot market;
        IntradaySnapshot chart;

        public MainWindow(string dataPath)
        {
            storage = new SettingsStore(dataPath); settings = storage.Load();
            Title = "A股桌面行情"; Width = 460; Height = Math.Min(740, SystemParameters.WorkArea.Height - 40); MinHeight = 360; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true; Background = Brushes.Transparent; FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 12; ShowInTaskbar = true;
            if (!double.IsNaN(settings.Left)) Left = settings.Left; else Left = SystemParameters.WorkArea.Right - Width - 20;
            if (!double.IsNaN(settings.Top)) Top = settings.Top; else Top = SystemParameters.WorkArea.Top + 40;
            BuildLayout(); RebuildCards();
            Loaded += delegate {
                desktop = new DesktopIntegration(this, RefreshAll, ShowAdd, delegate(bool value) { settings.AutoHide = value; Save(); UpdateButtons(); }, delegate(bool value) { settings.Pinned = value; Save(); UpdateButtons(); }, delegate(double x, double y) { settings.Left = x; settings.Top = y; Save(); });
                desktop.SetBackgroundSurface(surface); desktop.Initialize(settings.AutoHide, settings.Pinned); ApplyTransparency(); UpdateButtons(); RefreshAll(); timer.Start();
            };
            timer.Interval = TimeSpan.FromMilliseconds(500); timer.Tick += delegate { Tick(); };
            debounce.Interval = TimeSpan.FromMilliseconds(350); debounce.Tick += delegate { debounce.Stop(); SearchAsync(false); };
            SystemEvents.PowerModeChanged += PowerChanged;
            Closed += delegate { closed = true; timer.Stop(); debounce.Stop(); SystemEvents.PowerModeChanged -= PowerChanged; lifetime.Cancel(); if (searchCancel != null) searchCancel.Cancel(); if (chartCancel != null) chartCancel.Cancel(); client.Dispose(); if (desktop != null) desktop.Dispose(); };
            KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Key == Key.Escape) { addPanel.Visibility = Visibility.Collapsed; candidates.IsOpen = false; CancelSearch(); } };
        }
        void BuildLayout()
        {
            var root = new Grid(); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            surface = new Border { CornerRadius = new CornerRadius(16), BorderBrush = Theme.Line, BorderThickness = new Thickness(1), Padding = new Thickness(14), Child = root }; Content = surface;
            var header = new StackPanel(); root.Children.Add(header);
            var toolbar = new DockPanel { Margin = new Thickness(0, 0, 0, 8), Background = Brushes.Transparent };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(buttons, Dock.Right); toolbar.Children.Add(buttons);
            buttons.Children.Add(Theme.Button("＋", "添加股票", ShowAdd)); buttons.Children.Add(Theme.Button("↻", "立即刷新", RefreshAll));
            pinButton = Theme.Button("钉", "置顶", delegate { desktop.SetPinned(!desktop.Pinned); }); buttons.Children.Add(pinButton);
            dockButton = Theme.Button("⇥", "右侧自动吸附隐藏", delegate { desktop.SetAutoHide(!desktop.AutoHide); }); buttons.Children.Add(dockButton);
            buttons.Children.Add(Theme.Button("⚙", "背景透明度", delegate { optionsPanel.Visibility = optionsPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible; })); buttons.Children.Add(Theme.Button("−", "隐藏到系统托盘", delegate { desktop.HideWindow(); }));
            var title = Theme.Text("A股桌面行情", 16, Theme.Ink); title.FontWeight = FontWeights.SemiBold; toolbar.Children.Add(title);
            title.MouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { if (e.ButtonState == MouseButtonState.Pressed && desktop != null) desktop.BeginDrag(); };
            header.Children.Add(toolbar);
            optionsPanel = new StackPanel { Orientation = Orientation.Horizontal, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 8) }; optionsPanel.Children.Add(Theme.Text("背景透明度", 11, Theme.Muted));
            var slider = new Slider { Minimum = 0, Maximum = 100, Value = settings.Transparency, Width = 220, Margin = new Thickness(12, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
            var percent = Theme.Text(settings.Transparency.ToString("0") + "%", 11, Theme.Ink); slider.ValueChanged += delegate { settings.Transparency = slider.Value; percent.Text = slider.Value.ToString("0") + "%"; ApplyTransparency(); Save(); }; optionsPanel.Children.Add(slider); optionsPanel.Children.Add(percent); header.Children.Add(optionsPanel);
            addPanel = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 0, 0, 8) };
            search = Theme.Input("", "中文简称或6位代码；代码可用逗号批量添加，按回车确认"); search.Margin = new Thickness(0); search.TextChanged += delegate { CancelSearch(); debounce.Stop(); candidates.IsOpen = false; if (!string.IsNullOrWhiteSpace(search.Text)) debounce.Start(); }; search.KeyDown += delegate(object s, KeyEventArgs e) { if (e.Key == Key.Enter) { debounce.Stop(); SearchAsync(true); e.Handled = true; } };
            addPanel.Children.Add(search); header.Children.Add(addPanel);
            resultList = new StackPanel(); candidates = new Popup { PlacementTarget = search, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true, Child = new Border { Width = 428, Background = Theme.Hex("#18283E"), BorderBrush = Theme.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = new ScrollViewer { MaxHeight = 240, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = resultList } } };
            var overview = new StackPanel(); var indexLine = new DockPanel(); modeLabel = Theme.Text("", 10, Theme.Muted); DockPanel.SetDock(modeLabel, Dock.Right); indexLine.Children.Add(modeLabel); indexValue = Theme.Text("上证指数   —", 15, Theme.Ink); indexValue.FontWeight = FontWeights.SemiBold; indexLine.Children.Add(indexValue); overview.Children.Add(indexLine);
            breadthValue = Theme.Text("全A    上涨 —    下跌 —", 11, Theme.Muted); breadthValue.Margin = new Thickness(0, 8, 0, 4); overview.Children.Add(breadthValue); turnoverValue = Theme.Text("成交额 —    较昨日同刻 —", 11, Theme.Muted); overview.Children.Add(turnoverValue);
            var overviewPanel = Theme.Panel(overview, new Thickness(12)); overviewPanel.Margin = new Thickness(0, 0, 0, 12); Grid.SetRow(overviewPanel, 1); root.Children.Add(overviewPanel);
            list = new StackPanel(); scroll = new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(0, 0, 2, 0) }; Grid.SetRow(scroll, 2); root.Children.Add(scroll);
            var footer = new StackPanel { Margin = new Thickness(0, 10, 0, 0) }; var footerLine = new DockPanel(); total = Theme.Text("总盈亏  0.00", 12, Theme.Ink); DockPanel.SetDock(total, Dock.Right); footerLine.Children.Add(total); status = Theme.Text("正在连接…", 10, Theme.Muted); footerLine.Children.Add(status); footer.Children.Add(footerLine);
            message = Theme.Text("", 10, Theme.Amber); message.Margin = new Thickness(0, 6, 0, 0); message.TextWrapping = TextWrapping.Wrap; message.MaxHeight = 44; footer.Children.Add(message); Grid.SetRow(footer, 3); root.Children.Add(footer);
        }
        void ApplyTransparency() { if (surface == null) return; surface.Background = new SolidColorBrush(Color.FromArgb((byte)Math.Max(3, Math.Round(255 * (1 - settings.Transparency / 100))), 12, 23, 40)); if (desktop != null) desktop.SetBackgroundTransparency(settings.Transparency); }
        void UpdateButtons() { pinButton.Foreground = settings.Pinned ? Theme.Blue : Theme.Muted; dockButton.Foreground = settings.AutoHide ? Theme.Blue : Theme.Muted; }
        bool Save() { try { storage.Save(settings); return true; } catch (Exception e) { notice = "设置保存失败：" + e.Message; return false; } }
        void ShowAdd() { addPanel.Visibility = Visibility.Visible; if (desktop != null) desktop.ShowWindow(); search.Focus(); }
        void CancelSearch() { if (searchCancel != null) { searchCancel.Cancel(); searchCancel = null; } }
        async void SearchAsync(bool submit)
        {
            string text = search.Text.Trim(); if (text.Length == 0) return;
            if (System.Text.RegularExpressions.Regex.IsMatch(text, "^[a-zA-Z0-9,，\\s]+$")) { if (submit) AddSymbols(text); return; }
            CancelSearch(); var cts = new CancellationTokenSource(); searchCancel = cts;
            try
            {
                var results = await client.SearchAsync(text, cts.Token); if (cts.IsCancellationRequested || search.Text.Trim() != text) return;
                var match = MarketDataParser.AutomaticMatch(results, text); if (submit && match != null) { AddSymbols(match.Id); return; }
                resultList.Children.Clear(); foreach (var result in results) { var item = result; var button = Theme.Button(item.Name + "     " + item.Symbol.Code + " · " + item.Symbol.Market.ToUpperInvariant(), "添加自选股", delegate { AddSymbols(item.Id); }); button.HorizontalContentAlignment = HorizontalAlignment.Left; resultList.Children.Add(button); }
                candidates.IsOpen = results.Count > 0; notice = results.Count == 0 ? "未找到匹配A股，可改用6位代码。" : submit ? "存在多个结果，请选择要添加的股票。" : null; UpdateValues();
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { if (!cts.IsCancellationRequested) { notice = "搜索失败：" + e.Message; UpdateValues(); } }
        }
        void AddSymbols(string text)
        {
            try { var added = Symbol.ParseList(text); var ids = settings.Symbols.Concat(added.Select(s => s.Id)).Distinct().ToList(); if (ids.Count > 20) throw new InvalidOperationException("最多添加20只自选股。"); settings.Symbols = ids; if (Save()) notice = null; search.Text = ""; candidates.IsOpen = false; RebuildCards(); RefreshAll(); }
            catch (Exception e) { notice = e.Message; UpdateValues(); }
        }
        void Remove(string id) { settings.Symbols.Remove(id); settings.Tracking.Remove(id); quotes.Remove(id); quoteIssues.Remove(id); if (expandedChart == id) { expandedChart = null; CancelChart(); } if (expandedEditor == id) expandedEditor = null; Save(); RebuildCards(); RefreshAll(); }
        void ToggleChart(string id) { expandedChart = expandedChart == id ? null : id; expandedEditor = null; chart = null; chartError = null; CancelChart(); RebuildCards(); nextChart = DateTimeOffset.MinValue; Tick(); }
        void ToggleEditor(string id) { expandedEditor = expandedEditor == id ? null : id; expandedChart = null; CancelChart(); RebuildCards(); }
        void CancelChart() { if (chartCancel != null) chartCancel.Cancel(); chartCancel = null; chartBusy = false; }
        void RebuildCards()
        {
            list.Children.Clear(); cards.Clear();
            if (settings.Symbols.Count == 0)
            {
                var empty = new StackPanel { Margin = new Thickness(28, 75, 28, 40), HorizontalAlignment = HorizontalAlignment.Center };
                empty.Children.Add(Theme.Text("自选，从关注开始", 21, Theme.Ink)); var subtitle = Theme.Text("添加A股，随时查看行情、持仓与价格提醒", 11, Theme.Muted); subtitle.Margin = new Thickness(0, 12, 0, 20); empty.Children.Add(subtitle); var add = Theme.Button("＋  添加第一只股票", "输入中文简称或股票代码", ShowAdd); add.Background = Theme.Hex("#244778"); empty.Children.Add(add); list.Children.Add(empty);
            }
            foreach (string id in settings.Symbols) { var card = new Card(this, id); cards[id] = card; list.Children.Add(card.Root); }
            UpdateValues(); if (expandedEditor != null && cards.ContainsKey(expandedEditor)) cards[expandedEditor].Root.BringIntoView(); if (expandedChart != null && cards.ContainsKey(expandedChart)) cards[expandedChart].Root.BringIntoView();
        }
        void RefreshAll() { nextQuote = nextMarket = nextChart = DateTimeOffset.MinValue; Tick(); }
        void PowerChanged(object sender, PowerModeChangedEventArgs e) { Dispatcher.BeginInvoke(new Action(delegate { if (e.Mode == PowerModes.Suspend) { suspended = true; lifetime.Cancel(); CancelChart(); } else if (e.Mode == PowerModes.Resume) { suspended = false; lifetime = new CancellationTokenSource(); RefreshAll(); } })); }
        void Tick()
        {
            if (closed || suspended) return; var now = DateTimeOffset.UtcNow; var session = MarketClock.GetSession(now);
            if (session.Phase != previousPhase) { nextQuote = nextMarket = nextChart = DateTimeOffset.MinValue; previousPhase = session.Phase; }
            if (!quoteBusy && settings.Symbols.Count > 0 && now >= nextQuote) FetchQuotes();
            if (!marketBusy && now >= nextMarket) FetchMarket();
            if (!chartBusy && expandedChart != null && now >= nextChart) FetchChart();
            UpdateValues();
        }
        async void FetchQuotes()
        {
            quoteBusy = true; var token = lifetime.Token; var ids = settings.Symbols.ToList(); nextQuote = DateTimeOffset.UtcNow.AddSeconds(MarketClock.GetSession(DateTimeOffset.UtcNow).PollInterval);
            try {
                var data = await client.FetchQuotesAsync(Symbol.ParseList(string.Join(",", ids)), token); if (token.IsCancellationRequested) return;
                var now = DateTimeOffset.UtcNow; bool changed = false; quoteError = null;
                foreach (string id in ids) {
                    if (!settings.Symbols.Contains(id)) continue; Quote q, old;
                    if (!data.TryGetValue(id, out q)) { quoteIssues[id] = "本轮未返回有效报价，保留快照"; continue; }
                    if (q.Timestamp > now.AddSeconds(5) || quotes.TryGetValue(id, out old) && q.Timestamp < old.Timestamp) { quoteIssues[id] = "源时间异常，已保留上次报价"; continue; }
                    quotes[id] = q; quoteIssues.Remove(id); TrackingRecord record;
                    if (settings.Tracking.TryGetValue(id, out record)) {
                        bool auction = MarketClock.GetSession(now).Phase == MarketPhase.Auction || MarketClock.GetSession(q.Timestamp).Phase == MarketPhase.Auction;
                        var alerts = record.TakeAlerts(q.Price, q.Timestamp, now, auction); foreach (var alert in alerts) { changed = true; if (desktop != null) desktop.Notify(q.Name + " 价格提醒", alert); }
                    }
                }
                lastReceipt = now; if (changed) Save();
            } catch (OperationCanceledException) { } catch (Exception e) { quoteError = "行情连接失败，正在自动重试：" + e.Message; }
            finally { quoteBusy = false; if (!closed) UpdateValues(); }
        }
        async void FetchMarket()
        {
            marketBusy = true; var token = lifetime.Token; nextMarket = DateTimeOffset.UtcNow.AddSeconds(Math.Max(3, MarketClock.GetSession(DateTimeOffset.UtcNow).PollInterval));
            try { var result = await client.FetchMarketAsync(token); if (token.IsCancellationRequested) return; var now = DateTimeOffset.UtcNow; if (result.Index.Timestamp > now.AddSeconds(5) || result.LatestTimestamp > now.AddSeconds(5) || market != null && (result.Index.Timestamp < market.Index.Timestamp || result.BreadthTimestamp < market.BreadthTimestamp || result.TurnoverTimestamp < market.TurnoverTimestamp)) throw new InvalidOperationException("大盘源时间异常，保留上次数据"); market = result; marketError = null; }
            catch (OperationCanceledException) { } catch (Exception e) { marketError = "大盘：" + e.Message; }
            finally { marketBusy = false; if (!closed) UpdateValues(); }
        }
        async void FetchChart()
        {
            string id = expandedChart; var cts = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); chartCancel = cts; chartBusy = true; nextChart = DateTimeOffset.UtcNow.AddSeconds(Math.Max(3, MarketClock.GetSession(DateTimeOffset.UtcNow).PollInterval));
            try { var result = await client.FetchIntradayAsync(Symbol.ParseList(id)[0], cts.Token); if (cts.IsCancellationRequested || id != expandedChart) return; if (result.Timestamp > DateTimeOffset.UtcNow.AddSeconds(5) || chart != null && result.Timestamp < chart.Timestamp) throw new InvalidOperationException("分时源时间异常"); chart = result; chartError = null; }
            catch (OperationCanceledException) { } catch (Exception e) { if (!cts.IsCancellationRequested && id == expandedChart) chartError = e.Message; }
            finally { if (chartCancel == cts) { chartBusy = false; chartCancel = null; } cts.Dispose(); if (!closed) UpdateValues(); }
        }
        internal static bool MarketStale(MarketOverviewSnapshot snapshot, DateTimeOffset now, MarketSession session)
        { return snapshot != null && session.ExpectsFreshQuotes && ((now - snapshot.Timestamp).TotalSeconds > 15 || (now - snapshot.Index.Timestamp).TotalSeconds > 15); }
        void UpdateValues()
        {
            if (status == null) return; var now = DateTimeOffset.UtcNow; var session = MarketClock.GetSession(now); modeLabel.Text = session.Label;
            if (market != null) { indexValue.Text = "上证  " + market.Index.Price.ToString("0.00") + "   " + Theme.Number(market.Index.ChangePercent, "+0.00;-0.00;0.00") + "%"; indexValue.Foreground = Theme.Direction(market.Index.ChangePercent); breadthValue.Text = "沪深京全A    涨 " + market.Advancing + "    跌 " + market.Declining + "    共 " + market.Total; turnoverValue.Text = "成交 " + Theme.Compact(market.TurnoverYuan) + "    同刻 " + (market.Comparison == null ? "—" : (market.Comparison.ChangeYuan >= 0 ? "放量 " : "缩量 ") + Theme.Compact(Math.Abs(market.Comparison.ChangeYuan))); turnoverValue.Foreground = market.Comparison == null ? Theme.Muted : Theme.Direction(market.Comparison.ChangeYuan); indexValue.ToolTip = "源时间：" + market.Index.Timestamp.ToString("yyyy-MM-dd HH:mm:ss") + "\n" + (marketError ?? "") + "\n广度：" + market.BreadthTimestamp.ToString("yyyy-MM-dd HH:mm:ss") + "\n成交额：" + market.TurnoverTimestamp.ToString("yyyy-MM-dd HH:mm:ss"); }
            foreach (var card in cards.Values) card.Update(session);
            decimal sum = 0; bool unknown = settings.HasInvalidPositions;
            foreach (var id in settings.Symbols) { TrackingRecord record; if (!settings.Tracking.TryGetValue(id, out record) || !record.HasPosition) continue; Quote q; if (!quotes.TryGetValue(id, out q)) { unknown = true; continue; } var p = q.ValuationPrice(session.Phase == MarketPhase.Auction); var profit = p.HasValue ? record.Profit(p.Value) : null; if (profit == null) unknown = true; else { try { sum = checked(sum + profit.Amount); } catch (OverflowException) { unknown = true; } } }
            total.Text = "总盈亏  " + (unknown ? "—" : Theme.Money(sum)); total.Foreground = unknown ? Theme.Muted : Theme.Direction(sum);
            bool stale = quotes.Values.Any(q => MarketClock.IsStale(q.Timestamp, now, session)); status.Text = settings.Symbols.Count == 0 ? session.Label + " · 空自选" : stale ? "● 报价过旧" : session.Label + (quotes.Count == 0 ? " · 等待数据" : " · " + MarketClock.AgeText(quotes.Values.Min(q => q.Timestamp), now)); status.Foreground = stale || quoteError != null ? Theme.Amber : Theme.Muted;
            status.ToolTip = string.Join("\n", quotes.Values.Select(q => q.Name + " " + q.Timestamp.ToString("yyyy-MM-dd HH:mm:ss"))) + "\n最近接收：" + (lastReceipt == default(DateTimeOffset) ? "—" : lastReceipt.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss")) + "\n竞价使用买一优先、卖一兜底；无有效盘口价格时显示—。";
            string warning = notice ?? storage.Notice ?? quoteError ?? quoteIssues.Values.FirstOrDefault() ?? marketError ?? (stale ? "报价源已超过15秒，当前显示保留快照。" : null);
            if (warning == null && MarketStale(market, now, session)) warning = "大盘数据过旧，当前显示保留快照。";
            message.Text = warning ?? "公开行情 · 仅本机保存持仓"; message.Foreground = warning == null ? Theme.Muted : Theme.Amber; message.ToolTip = warning;
        }

        sealed class Card
        {
            readonly MainWindow owner; readonly string id;
            public readonly Border Root;
            readonly TextBlock price, change, position, alertState;
            readonly Dictionary<string, TextBlock> metrics = new Dictionary<string, TextBlock>();
            readonly Button name;
            IntradayView chartView; TextBlock chartNotice;
            public Card(MainWindow owner, string id)
            {
                this.owner = owner; this.id = id; var stack = new StackPanel(); Root = Theme.Panel(stack, new Thickness(10)); Root.Margin = new Thickness(0, 0, 0, 9);
                var title = new DockPanel(); var controls = new StackPanel { Orientation = Orientation.Horizontal }; DockPanel.SetDock(controls, Dock.Right); title.Children.Add(controls); controls.Children.Add(Theme.Button("⌁", "展开/收起分时图", delegate { owner.ToggleChart(id); })); controls.Children.Add(Theme.Button("×", "删除股票及其持仓、提醒", delegate { owner.Remove(id); }));
                name = Theme.Button(id.Substring(2), "点击名称编辑持仓和价格提醒", delegate { owner.ToggleEditor(id); }); name.HorizontalContentAlignment = HorizontalAlignment.Left; name.FontWeight = FontWeights.SemiBold; name.FontSize = 14; name.Padding = new Thickness(0, 2, 4, 2); title.Children.Add(name); stack.Children.Add(title);
                var quoteLine = new DockPanel(); change = Theme.Text("—", 13, Theme.Muted); DockPanel.SetDock(change, Dock.Right); quoteLine.Children.Add(change); price = Theme.Text("—", 28, Theme.Ink); price.FontFamily = new FontFamily("Segoe UI"); price.FontWeight = FontWeights.SemiBold; quoteLine.Children.Add(price); stack.Children.Add(quoteLine);
                var grid = new UniformGrid { Columns = 3, Margin = new Thickness(0, 7, 0, 2) };
                foreach (string label in new[] { "量比", "振幅", "换手", "成交量", "成交额", "总市值", "动态PE", "PB", "代码" }) { var t = Theme.Text(label + "  —", 10, Theme.Muted); t.Margin = new Thickness(0, 2, 1, 2); grid.Children.Add(t); metrics[label] = t; } stack.Children.Add(grid);
                position = Theme.Text("", 11, Theme.Muted); position.TextWrapping = TextWrapping.Wrap; position.Margin = new Thickness(0, 6, 0, 0); stack.Children.Add(position); alertState = Theme.Text("", 10, Theme.Amber); stack.Children.Add(alertState);
                if (owner.expandedEditor == id) stack.Children.Add(BuildEditor());
                if (owner.expandedChart == id) { chartView = new IntradayView(); stack.Children.Add(chartView); chartNotice = Theme.Text("", 10, Theme.Amber); chartNotice.TextWrapping = TextWrapping.Wrap; stack.Children.Add(chartNotice); }
            }
            public void Update(MarketSession session)
            {
                Quote q; bool available = owner.quotes.TryGetValue(id, out q); var p = available ? q.ValuationPrice(session.Phase == MarketPhase.Auction) : null;
                name.Content = available ? q.Name : id.Substring(2); metrics["代码"].Text = id.ToUpperInvariant();
                if (available) {
                    decimal? delta = p.HasValue ? p.Value - q.PreviousClose : (decimal?)null; decimal? pct = p.HasValue && q.PreviousClose > 0 ? delta / q.PreviousClose * 100 : null;
                    price.Text = Theme.Number(p, "0.00"); price.Foreground = change.Foreground = Theme.Direction(delta); change.Text = Theme.Number(delta, "+0.00;-0.00;0.00") + "   " + Theme.Number(pct, "+0.00;-0.00;0.00") + "%";
                    price.ToolTip = session.Phase == MarketPhase.Auction ? "集合竞价参考价：买一优先，卖一兜底；价格提醒暂停。" : "最新成交价 · 源时间 " + q.Timestamp.ToString("yyyy-MM-dd HH:mm:ss");
                    Metric("量比", Theme.Number(q.VolumeRatio, "0.00")); Metric("振幅", Theme.Number(q.AmplitudePercent, "0.00") + "%"); Metric("换手", Theme.Number(q.TurnoverPercent, "0.00") + "%"); Metric("成交量", Theme.Compact(q.VolumeLots) + "手"); Metric("成交额", Theme.Compact(q.AmountYuan)); Metric("总市值", Theme.Compact(q.MarketCapYuan)); Metric("动态PE", Theme.Number(q.PeDynamic, "0.00")); Metric("PB", Theme.Number(q.PbRatio, "0.00"));
                }
                TrackingRecord r; owner.settings.Tracking.TryGetValue(id, out r);
                var profit = r != null && p.HasValue ? r.Profit(p.Value) : null;
                position.Text = r != null && r.HasPosition ? "持仓 " + r.Quantity + " 股    盈亏 " + (profit == null ? "—" : Theme.Money(profit.Amount) + "  (" + Theme.Number(profit.Percent, "+0.00;-0.00;0.00") + "%)") + (r.IsEstimated ? " · 费用预估" : "") : "点击名称设置持仓与提醒"; position.Foreground = profit == null ? Theme.Muted : Theme.Direction(profit.Amount);
                if (r != null && r.HasPosition && r.EffectiveCost.HasValue) position.ToolTip = "含费成本：" + r.EffectiveCost.Value.ToString(CultureInfo.InvariantCulture) + " 元\n每股成本：" + (r.PerShareCost ?? r.EffectiveCost / r.Quantity).Value.ToString(CultureInfo.InvariantCulture) + " 元\n" + (r.IsEstimated ? "费用为单笔买入预估，以实际交割单为准。" : "按已填写成本计算，不重复加费。");
                if (available && q.PeDynamic < 0) { Metric("动态PE", "亏损"); metrics["动态PE"].ToolTip = "动态PE " + q.PeDynamic; }
                alertState.Text = owner.settings.InvalidTracking.ContainsKey(id) ? "配置异常 · 点击名称修正" : r == null || !r.HasAlerts ? "" : (r.Upper.HasValue ? "↑ " + r.Upper + (r.UpperTriggered ? " 已提醒" : " 等待") + "  " : "") + (r.Lower.HasValue ? "↓ " + r.Lower + (r.LowerTriggered ? " 已提醒" : " 等待") : "");
                if (chartView != null) { chartView.Snapshot = owner.chart; chartView.InvalidateVisual(); chartNotice.Text = owner.chartError ?? (owner.chart != null && owner.chart.Timestamp.ToOffset(TimeSpan.FromHours(8)).Date != DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromHours(8)).Date ? "最近交易日分时快照" : ""); chartView.ToolTip = owner.chart == null ? "等待数据" : "分时源时间 " + owner.chart.Timestamp.ToString("yyyy-MM-dd HH:mm:ss") + "\n分钟量由累计量差分，缺失分钟不绘制假量柱。"; }
            }
            void Metric(string key, string value) { metrics[key].Text = key + "  " + value; metrics[key].ToolTip = metrics[key].Text; }
            UIElement BuildEditor()
            {
                TrackingRecord prior; owner.settings.Tracking.TryGetValue(id, out prior);
                var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
                var raw = owner.storage.ReadRawTracking(id); Func<string,string> rawField = key => raw.ContainsKey(key) ? raw[key] : "";
                var alertPrior = prior ?? TrackingService.AlertStateFromRaw(raw);
                var mode = new ComboBox { ItemsSource = new[] { "买入金额（预估费用）", "含费总成本", "每股成本（做T后）" }, SelectedIndex = prior != null && prior.PerShareCost.HasValue || prior == null && rawField("PerShareCost") != "" ? 2 : prior != null && !prior.PurchaseAmount.HasValue && prior.HasPosition || prior == null && rawField("TotalCost") != "" && rawField("PurchaseAmount") == "" ? 1 : 0, FontSize = 12, Padding = new Thickness(5), Margin = new Thickness(0, 0, 0, 6) }; panel.Children.Add(mode);
                var inputs = new UniformGrid { Columns = 2 }; var amount = Theme.Input("", "当前模式的成本金额"); var quantity = Theme.Input(prior != null && prior.Quantity.HasValue ? prior.Quantity.Value.ToString() : "", "持仓数量，单位股，正整数"); var rate = Theme.Input(prior != null && prior.CommissionRate.HasValue ? prior.CommissionRate.Value.ToString(CultureInfo.InvariantCulture) : owner.settings.CommissionRate, "佣金万分比；最低5元，仅用于单笔买入预估"); var rateLabel = Theme.Text("佣金（万分比）", 10, Theme.Muted);
                var amountLabel = Theme.Text("成本金额（元）", 10, Theme.Muted); AddField(inputs, amountLabel, amount); AddField(inputs, Theme.Text("持仓数量（股）", 10, Theme.Muted), quantity); AddField(inputs, rateLabel, rate);
                if (prior == null && raw.Count > 0) { quantity.Text = rawField("Quantity"); if (rawField("CommissionRate") != "") rate.Text = rawField("CommissionRate"); }
                Action fill = delegate { int selected = mode.SelectedIndex; amount.Text = prior == null ? rawField(selected == 2 ? "PerShareCost" : selected == 1 ? "TotalCost" : "PurchaseAmount") : selected == 2 ? DecimalText(prior.PerShareCost) : selected == 1 ? prior.EffectiveCost.HasValue ? TrackingService.Money(prior.EffectiveCost.Value, false) : "" : DecimalText(prior.PurchaseAmount); rate.IsEnabled = selected == 0; amountLabel.Text = selected == 2 ? "每股成本（可为负）" : selected == 1 ? "含费总成本（元）" : "买入成交金额（元）"; }; mode.SelectionChanged += delegate { fill(); }; fill(); panel.Children.Add(inputs);
                var alerts = new UniformGrid { Columns = 2 }; var upper = Theme.Input(prior == null ? "" : DecimalText(prior.Upper), "现价达到或高于此值提醒一次，留空关闭"); var lower = Theme.Input(prior == null ? "" : DecimalText(prior.Lower), "现价达到或低于此值提醒一次，留空关闭"); AddField(alerts, Theme.Text("上方提醒价", 10, Theme.Muted), upper); AddField(alerts, Theme.Text("下方提醒价", 10, Theme.Muted), lower); panel.Children.Add(alerts);
                if (prior == null && raw.Count > 0) { upper.Text = rawField("Upper"); lower.Text = rawField("Lower"); }
                var help = Theme.Text(raw.Count > 0 ? "原配置异常，已回填可读取字段，请核对后保存。" : "买入金额按单笔预估费用；实际费用请核对交割单。", 10, Theme.Muted); help.TextWrapping = TextWrapping.Wrap; help.Margin = new Thickness(0, 6, 0, 6); panel.Children.Add(help);
                Action estimate = delegate {
                    if (raw.Count > 0) return;
                    if (mode.SelectedIndex != 0) { help.Text = mode.SelectedIndex == 2 ? "保留最多8位小数，可填写零或负成本，不再加费。" : "填写实际含费总成本，不再额外加费。"; return; }
                    try { var fees = TrackingService.EstimateFees(id, amount.Text, rate.Text); help.Text = "预估：佣金 " + fees.Commission.ToString("0.00") + " + 过户费 " + fees.TransferFee.ToString("0.00") + "，含费成本 " + fees.TotalCost.ToString("0.00") + " 元。仅适用单笔委托。"; }
                    catch { help.Text = "买入金额按单笔预估，最低佣金5元；实际费用请核对交割单。"; }
                }; amount.TextChanged += delegate { estimate(); }; rate.TextChanged += delegate { estimate(); }; mode.SelectionChanged += delegate { estimate(); }; estimate();
                var error = Theme.Text("", 10, Theme.Amber); error.TextWrapping = TextWrapping.Wrap; panel.Children.Add(error);
                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                var save = Theme.Button("保存", "保存到本机", delegate {
                    try { var record = TrackingService.Build(id, mode.SelectedIndex == 2 ? "perShare" : mode.SelectedIndex == 1 ? "total" : "purchase", amount.Text, quantity.Text, rate.Text, upper.Text, lower.Text, alertPrior, DateTimeOffset.UtcNow, owner.settings.CommissionRate); owner.settings.Tracking[id] = record; if (mode.SelectedIndex == 0 && record.CommissionRate.HasValue && (prior == null || rate.Text != DecimalText(prior.CommissionRate))) owner.settings.CommissionRate = DecimalText(record.CommissionRate); owner.Save(); owner.expandedEditor = null; owner.RebuildCards(); }
                    catch (Exception e) { error.Text = e.Message; }
                }); save.Background = Theme.Hex("#244778"); actions.Children.Add(save);
                actions.Children.Add(Theme.Button("取消", "不保存当前编辑", delegate { owner.expandedEditor = null; owner.RebuildCards(); }));
                if (prior != null && prior.HasTriggeredAlerts) actions.Children.Add(Theme.Button("重新启用提醒", "重新等待下一次价格触达", delegate { prior.Rearm(DateTimeOffset.UtcNow); owner.Save(); owner.UpdateValues(); })); panel.Children.Add(actions); return panel;
            }
            static string DecimalText(decimal? value) { return value.HasValue ? value.Value.ToString(CultureInfo.InvariantCulture) : ""; }
            static void AddField(Panel parent, TextBlock label, TextBox input) { var p = new StackPanel(); p.Children.Add(label); p.Children.Add(input); parent.Children.Add(p); }
        }
    }
}
