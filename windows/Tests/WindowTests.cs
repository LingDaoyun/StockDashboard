using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using StockDashboard;

internal static class WindowTests
{
    static int count;
    static void Check(bool ok, string text) { if (!ok) throw new Exception("FAIL: " + text); count++; }
    static object Field(object target, string name) { return target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target); }
    static void Call(object target, string name, params object[] args) { target.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic).Invoke(target, args); }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    { for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) { var child = VisualTreeHelper.GetChild(root, i); if (child is T) yield return (T)child; foreach (var item in Descendants<T>(child)) yield return item; } }
    [STAThread]
    static int Main()
    {
        string path = Path.Combine(Path.GetTempPath(), "StockDashboard-WindowTests-" + Guid.NewGuid().ToString("N"), "settings.json");
        try
        {
            var app = new Application();
            var empty = new MainWindow(path);
            Check(((AppSettings)Field(empty, "settings")).Symbols.Count == 0, "first launch has no sample stocks");
            Check(((TextBlock)Field(empty, "total")).Text.Contains("0.00"), "empty portfolio total is zero");
            empty.Close();
            var settings = new AppSettings(); settings.AutoHide = false; settings.Symbols.Add("sh600000"); settings.Tracking["sh600000"] = TrackingService.Build("sh600000", "total", "1005.08", "100", "2.5", "15", "8", null, DateTimeOffset.UtcNow);
            new SettingsStore(path).Save(settings);
            var window = new MainWindow(path); var quotes = (Dictionary<string, Quote>)Field(window, "quotes");
            Check(((TextBlock)Field(window, "total")).Text.Contains("—"), "held stock without quote does not claim complete total");
            quotes["sh600000"] = new Quote { SymbolId = "sh600000", Name = "测试行情", Price = 12, PreviousClose = 10, BidPrice = 12, AskPrice = 12, Timestamp = DateTimeOffset.UtcNow };
            Call(window, "UpdateValues"); Check(((TextBlock)Field(window, "total")).Text.Contains("194.92"), "portfolio renders exact decimal P&L");
            Call(window, "ToggleEditor", "sh600000"); var root = (FrameworkElement)window.Content; root.Measure(new Size(460, 740)); root.Arrange(new Rect(0, 0, 460, 740)); root.UpdateLayout();
            var inputs = Descendants<TextBox>(root).ToList(); var amount = inputs.First(t => t.Text == "1005.08"); amount.Text = "999.99";
            quotes["sh600000"].Price = 13; quotes["sh600000"].BidPrice = 13; Call(window, "UpdateValues");
            Check(amount.Text == "999.99", "quote refresh preserves unsaved editor text");
            Check(((TextBlock)Field(window, "total")).Text.Contains("294.92"), "refresh recalculates total from saved rather than unsaved cost");
            var original = ((AppSettings)Field(window, "settings")).Tracking["sh600000"];
            Check(original.TotalCost == 1005.08m, "unsaved edits do not mutate held position");
            var time = new DateTimeOffset(2026, 10, 28, 10, 0, 0, TimeSpan.FromHours(8));
            var mixed = new MarketOverviewSnapshot { Index = new Quote { Timestamp = time.AddMinutes(-3) }, BreadthTimestamp = time, TurnoverTimestamp = time };
            Check(MainWindow.MarketStale(mixed, time, MarketClock.At(time)), "stalled index must flag entire market overview as stale");
            mixed.Index.Timestamp = time; Check(!MainWindow.MarketStale(mixed, time, MarketClock.At(time)), "fresh independent market sources remain current");
            File.Move(path, path + ".saved"); Directory.CreateDirectory(path);
            Call(window, "AddSymbols", "002580");
            Check((((string)Field(window, "notice")) ?? "").Contains("保存失败"), "adding stocks preserves storage failure warning");
            Directory.Delete(path); File.Move(path + ".saved", path);
            window.Close();
            var reload = new SettingsStore(path).Load(); Check(reload.Symbols.SequenceEqual(new[] { "sh600000" }), "watchlist survives reload"); Check(reload.Tracking["sh600000"].TotalCost == 1005.08m, "persisted position unaffected by canceled edit");
            Console.WriteLine("PASS: " + count + " WPF integration assertions"); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
        finally { if (Directory.Exists(Path.GetDirectoryName(path))) Directory.Delete(Path.GetDirectoryName(path), true); }
    }
}
