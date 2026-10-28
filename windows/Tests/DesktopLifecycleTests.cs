using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using StockDashboard;

internal static class DesktopLifecycleTests
{
    private static int failures;
    private static void Check(string name, bool value)
    { if (!value) failures++; Console.WriteLine((value ? "PASS " : "FAIL ") + name); }
    [STAThread]
    public static int Main()
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var surface = new Border { Child = new TextBlock { Text = "Desktop integration test", Foreground = Brushes.White } };
        var window = new Window { Width = 440, Height = 700, Left = 100, Top = 100, WindowStyle = WindowStyle.None,
            AllowsTransparency = true, Background = Brushes.Transparent, ShowActivated = false, Content = surface };
        int pinChanges = 0, dockChanges = 0, saves = 0;
        using (var desktop = new DesktopIntegration(window, delegate { }, delegate { }, delegate { dockChanges++; }, delegate { pinChanges++; }, delegate { saves++; }))
        {
            desktop.SetBackgroundSurface(surface);
            desktop.Initialize(false, false);
            window.Show();
            Window handle = app.Windows.Cast<Window>().Single(w => w.Title == "行情提示条");
            Check("initialization does not mutate preferences", pinChanges == 0 && dockChanges == 0);
            Check("normal window visible without hint", window.IsVisible && !handle.IsVisible);
            desktop.SetBackgroundTransparency(75);
            Check("transparency affects only surface", window.Opacity == 1 && ((SolidColorBrush)surface.Background).Color.A == 64 && ((SolidColorBrush)window.Background).Color.A == 0);
            desktop.SetBackgroundTransparency(100);
            Check("100 percent transparency retains a clickable one-percent surface", ((SolidColorBrush)surface.Background).Color.A == 3 && window.Opacity == 1);
            desktop.SetPinned(true);
            desktop.SetPinned(true);
            Check("pin applies and duplicate setter is idempotent", window.Topmost && desktop.Pinned && pinChanges == 1);
            desktop.HideWindow();
            desktop.SetAutoHide(true);
            Check("manual hiding never leaves hint even when docking enabled", !window.IsVisible && !handle.IsVisible);
            desktop.ShowWindow();
            Check("explicit show opens main window and hides hint", window.IsVisible && !handle.IsVisible);
            window.Close();
            Check("close hides both surfaces", !window.IsVisible && !handle.IsVisible && app.Windows.Cast<Window>().Contains(window));
            desktop.SetAutoHide(false);
            Check("disabling docking while manually hidden stays hidden", !window.IsVisible && !handle.IsVisible);
            desktop.ShowWindow();
            Check("disabling docking restores floating window", window.IsVisible && !desktop.AutoHide && !handle.IsVisible);
            Check("expanded position is persisted", saves > 0);
        }
        window.Close();
        Check("dispose permits real close and removes hint window", app.Windows.Count == 0);
        app.Shutdown();
        return failures == 0 ? 0 : 1;
    }
}
