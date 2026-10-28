using System;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace StockDashboard
{
    internal sealed class IntradayView : FrameworkElement
    {
        public IntradaySnapshot Snapshot { get; set; }
        int hover = -1;
        public IntradayView() { Height = 196; MouseMove += delegate(object s, MouseEventArgs e) { hover = (int)Math.Round(Math.Max(0, Math.Min(240, (e.GetPosition(this).X - 8) / Math.Max(1, ActualWidth - 16) * 240))); InvalidateVisual(); }; MouseLeave += delegate { hover = -1; InvalidateVisual(); }; }
        void Label(DrawingContext dc, string text, double x, double y, Brush brush, double size)
        { dc.DrawText(new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Microsoft YaHei UI"), size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(x, y)); }
        protected override void OnRender(DrawingContext dc)
        {
            base.OnRender(dc); double w = Math.Max(1, ActualWidth - 16); double top = 25, priceHeight = 100, volumeTop = 138, volumeHeight = 30;
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight));
            if (Snapshot == null || Snapshot.Points.Count == 0) { Label(dc, "正在获取分时数据…", 8, 65, Theme.Muted, 12); return; }
            decimal close = Snapshot.PreviousClose; decimal range = Math.Max(Math.Abs(Snapshot.Points.Max(p => p.Price) - close), Math.Abs(Snapshot.Points.Min(p => p.Price) - close)); range = Math.Max(range * 1.1m, close * .003m);
            double min = (double)(close - range), max = (double)(close + range);
            Func<decimal, double> y = p => top + (max - (double)p) / Math.Max(.000001, max - min) * priceHeight;
            Func<IntradayPoint, double> x = p => 8 + p.SessionMinute / 240.0 * w;
            var reference = new Pen(Theme.Line, 1); reference.DashStyle = DashStyles.Dash;
            dc.DrawLine(reference, new Point(8, y(close)), new Point(w + 8, y(close)));
            dc.DrawLine(new Pen(Theme.Line, 1), new Point(8, volumeTop + volumeHeight), new Point(w + 8, volumeTop + volumeHeight));
            decimal maxVolume = Snapshot.Points.Max(p => p.VolumeLots ?? 0); IntradayPoint previous = null;
            foreach (var p in Snapshot.Points)
            {
                if (previous != null && (p.Minute == previous.Minute + 1 || previous.Minute == 690 && p.Minute == 780)) dc.DrawLine(new Pen(Theme.Blue, 1.6), new Point(x(previous), y(previous.Price)), new Point(x(p), y(p.Price)));
                if (p.VolumeLots.HasValue && maxVolume > 0) { double h = (double)(p.VolumeLots.Value / maxVolume) * volumeHeight; dc.DrawRectangle(previous == null || p.Price >= previous.Price ? Theme.Up : Theme.Down, null, new Rect(x(p) - .7, volumeTop + volumeHeight - h, Math.Max(1, w / 280), h)); }
                previous = p;
            }
            Label(dc, "09:30", 8, 176, Theme.Muted, 10); Label(dc, "11:30 / 13:00", w / 2 - 30, 176, Theme.Muted, 10); Label(dc, "15:00", w - 22, 176, Theme.Muted, 10);
            if (hover >= 0)
            {
                var p = Snapshot.Points.OrderBy(v => Math.Abs(v.SessionMinute - hover)).First();
                dc.DrawLine(reference, new Point(x(p), top), new Point(x(p), volumeTop + volumeHeight)); dc.DrawEllipse(Theme.Blue, null, new Point(x(p), y(p.Price)), 3, 3);
                Label(dc, p.TimeText + "    " + p.Price.ToString("0.00") + " 元    分钟量 " + Theme.Compact(p.VolumeLots) + " 手", 8, 3, Theme.Ink, 11);
            }
            else Label(dc, "分时 · " + Snapshot.Date + "    昨收 " + close.ToString("0.00") + "    量 / 手", 8, 3, Theme.Muted, 10);
        }
    }
}
