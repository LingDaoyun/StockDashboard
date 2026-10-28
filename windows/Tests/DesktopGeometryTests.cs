using System;
using System.Windows;
using StockDashboard;
internal static class DesktopGeometryTests
{
    private static int failures;
    private static void Check(string name, Rect actual, Rect expected)
    {
        if (actual != expected) { failures++; Console.WriteLine("FAIL " + name + ": " + actual + " expected " + expected); }
        else Console.WriteLine("PASS " + name);
    }
    public static int Main()
    {
        Check("negative-origin monitor clamping", DesktopGeometry.Clamp(new Rect(-2100, -300, 440, 700), new Rect(-1920, -200, 1920, 1040)), new Rect(-1920, -200, 440, 700));
        Check("right docking reserves taskbar area", DesktopGeometry.DockRight(new Rect(300, 600, 440, 700), new Rect(0, 0, 1920, 1040)), new Rect(1480, 340, 440, 700));
        Check("small screen keeps title reachable", DesktopGeometry.Clamp(new Rect(100, 200, 440, 700), new Rect(0, 0, 800, 600)), new Rect(100, 0, 440, 700));
        Check("handle follows second monitor at 150 percent", DesktopGeometry.Handle(new Rect(-660, -100, 660, 1050), new Rect(-1920, -200, 1920, 1440), 1.5, 1.5), new Rect(-24, 369.5, 24, 111));
        Check("handle remains in short work area", DesktopGeometry.Handle(new Rect(0, 0, 440, 700), new Rect(0, 0, 800, 400), 1, 1), new Rect(784, 313, 16, 74));
        return failures == 0 ? 0 : 1;
    }
}
