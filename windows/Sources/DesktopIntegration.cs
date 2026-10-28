using System;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace StockDashboard
{
    // Geometry is in physical desktop pixels, including monitors with negative origins.
    internal static class DesktopGeometry
    {
        internal static Rect Clamp(Rect window, Rect workArea)
        {
            return new Rect(Math.Max(workArea.Left, Math.Min(window.Left, workArea.Right - window.Width)),
                Math.Max(workArea.Top, Math.Min(window.Top, workArea.Bottom - window.Height)), window.Width, window.Height);
        }
        internal static Rect DockRight(Rect window, Rect workArea)
        {
            Rect result = Clamp(window, workArea);
            result.X = Math.Max(workArea.Left, workArea.Right - window.Width);
            return result;
        }
        internal static Rect Handle(Rect window, Rect workArea, double scaleX, double scaleY)
        {
            double width = Math.Min(16 * scaleX, workArea.Width), height = Math.Min(74 * scaleY, workArea.Height);
            return new Rect(workArea.Right - width,
                Math.Max(workArea.Top, Math.Min(window.Top + (window.Height - height) / 2, workArea.Bottom - height)), width, height);
        }
    }

    /// <summary>Owns desktop docking, the separate hover handle and the notification-area icon.</summary>
    internal sealed class DesktopIntegration : IDisposable
    {
        private enum Presentation { Shown, Collapsed, ManuallyHidden }
        private readonly Window window;
        private readonly Action refresh, addStock;
        private readonly Action<bool> autoHideChanged, pinnedChanged;
        private readonly Action<double, double> positionSaved;
        private readonly DispatcherTimer pointerTimer, collapseTimer, dockTimer;
        private Window handle;
        private IntPtr hwnd, handleHwnd;
        private HwndSource source;
        private Forms.NotifyIcon tray;
        private Forms.ToolStripMenuItem autoHideItem, pinnedItem, startupItem;
        private DependencyObject backgroundSurface;
        private Presentation presentation = Presentation.Shown;
        private Rect expanded;
        private bool hasExpanded, initialized, disposed, changingFrame, dragging, exiting, settingUp;
        private bool pendingDockCollapse;
        private NativePoint? focusLossPointer;
        private double transparency = 18;
        private const string StartupName = "StockDashboard";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public DesktopIntegration(Window window, Action refresh, Action addStock, Action<bool> autoHideChanged,
            Action<bool> pinnedChanged, Action<double, double> positionSaved)
        {
            if (window == null) throw new ArgumentNullException("window");
            this.window = window;
            this.refresh = refresh ?? delegate { };
            this.addStock = addStock ?? delegate { };
            this.autoHideChanged = autoHideChanged ?? delegate { };
            this.pinnedChanged = pinnedChanged ?? delegate { };
            this.positionSaved = positionSaved ?? delegate { };
            pointerTimer = new DispatcherTimer(DispatcherPriority.Background, window.Dispatcher) { Interval = TimeSpan.FromMilliseconds(100) };
            collapseTimer = new DispatcherTimer(DispatcherPriority.Background, window.Dispatcher) { Interval = TimeSpan.FromMilliseconds(600) };
            dockTimer = new DispatcherTimer(DispatcherPriority.Background, window.Dispatcher) { Interval = TimeSpan.FromMilliseconds(200) };
            pointerTimer.Tick += CheckPointer;
            collapseTimer.Tick += CollapseTick;
            dockTimer.Tick += DockTick;
            window.SourceInitialized += SourceInitialized;
            window.Loaded += WindowLoaded;
            window.Closing += WindowClosing;
            window.Closed += WindowClosed;
            window.Deactivated += WindowDeactivated;
            window.LocationChanged += WindowPositionChanged;
            window.SizeChanged += WindowSizeChanged;
        }

        public bool AutoHide { get; private set; }
        public bool Pinned { get; private set; }

        public void Initialize(bool autoHide, bool pinned)
        {
            if (disposed || initialized) return;
            initialized = true;
            AutoHide = autoHide;
            Pinned = pinned;
            window.Topmost = pinned;
            CreateHandle();
            CreateTray();
            SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
            AttachSource();
            if (window.IsLoaded) Ready();
        }

        public void SetAutoHide(bool value)
        {
            if (disposed || AutoHide == value) return;
            AutoHide = value;
            focusLossPointer = null;
            StopDelays();
            if (autoHideItem != null) autoHideItem.Checked = value;
            autoHideChanged(value);
            if (value && presentation != Presentation.ManuallyHidden) { pointerTimer.Start(); Dock(true); }
            else
            {
                pointerTimer.Stop();
                if (handle != null) handle.Hide();
                if (presentation != Presentation.ManuallyHidden)
                {
                    presentation = Presentation.Shown;
                    MoveWindow(DesktopGeometry.Clamp(CurrentReference(), WorkArea()));
                    window.Show();
                    SaveExpandedPosition();
                }
            }
        }

        public void SetPinned(bool value)
        {
            if (disposed || Pinned == value) return;
            Pinned = value;
            window.Topmost = value;
            if (pinnedItem != null) pinnedItem.Checked = value;
            pinnedChanged(value);
        }

        public void ShowWindow()
        {
            Reveal(true);
        }

        public void HideWindow()
        {
            if (disposed) return;
            StopDelays();
            focusLossPointer = null;
            pointerTimer.Stop();
            presentation = Presentation.ManuallyHidden;
            if (handle != null) handle.Hide();
            window.Hide();
        }

        public void Notify(string title, string body)
        {
            if (disposed) return;
            System.Media.SystemSounds.Exclamation.Play();
            if (tray == null) return;
            tray.BalloonTipTitle = title ?? "A股桌面行情";
            tray.BalloonTipText = string.IsNullOrWhiteSpace(body) ? "行情已更新" : body;
            tray.BalloonTipIcon = Forms.ToolTipIcon.Info;
            tray.ShowBalloonTip(5000);
        }

        // A Border or Panel lets the window remain transparent around its rounded corners.
        public void SetBackgroundSurface(DependencyObject surface)
        {
            backgroundSurface = surface;
            SetBackgroundTransparency(transparency);
        }

        public void SetBackgroundTransparency(double percent)
        {
            if (double.IsNaN(percent) || double.IsInfinity(percent)) percent = 0;
            transparency = Math.Max(0, Math.Min(100, percent));
            // Layered HWNDs hit-test fully transparent pixels through to windows underneath.
            // Keep the original app's approximately one-percent surface even at 100%.
            var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Max(3, Math.Round(255 * (1 - transparency / 100))), 14, 24, 42));
            brush.Freeze();
            Border border = backgroundSurface as Border;
            Panel panel = backgroundSurface as Panel;
            if (border != null) { window.Background = Brushes.Transparent; border.Background = brush; }
            else if (panel != null) { window.Background = Brushes.Transparent; panel.Background = brush; }
            else window.Background = brush;
        }

        public void BeginDrag()
        {
            if (disposed || Mouse.LeftButton != MouseButtonState.Pressed) return;
            StartMoving();
            try { window.DragMove(); }
            catch (InvalidOperationException) { /* The mouse may have been released before the move loop begins. */ }
            finally { FinishMoving(); }
        }

        private void Ready()
        {
            if (!initialized || disposed) return;
            AttachSource();
            settingUp = true;
            try { MoveWindow(DesktopGeometry.Clamp(WindowRectangle(), WorkArea())); }
            finally { settingUp = false; }
            SaveExpandedPosition();
            if (AutoHide) { pointerTimer.Start(); ScheduleDock(true); }
        }

        private void CreateHandle()
        {
            var label = new TextBlock { Text = "行\n情", Foreground = Brushes.White, FontSize = 10,
                FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            var body = new Border { Background = new SolidColorBrush(Color.FromArgb(240, 61, 135, 242)),
                CornerRadius = new CornerRadius(5, 0, 0, 5), Child = label, Cursor = Cursors.Hand,
                ToolTip = "鼠标移入展开行情；右键托盘图标可关闭自动吸附" };
            AutomationProperties.SetName(body, "行情提示条，鼠标移入展开");
            AutomationProperties.SetAutomationId(body, "edge-reveal-handle");
            handle = new Window { Title = "行情提示条", Width = 16, Height = 74, WindowStyle = WindowStyle.None,
                ResizeMode = ResizeMode.NoResize, AllowsTransparency = true, Background = Brushes.Transparent,
                ShowInTaskbar = false, ShowActivated = false, Topmost = true, Content = body };
            handleHwnd = new WindowInteropHelper(handle).EnsureHandle();
            int style = Native.GetWindowLong(handleHwnd, -20);
            Native.SetWindowLong(handleHwnd, -20, style | 0x08000000 | 0x00000080); // WS_EX_NOACTIVATE | TOOLWINDOW
            body.MouseEnter += delegate { TryHoverReveal(); };
            body.MouseLeftButtonDown += delegate { ShowWindow(); };
        }

        private void CreateTray()
        {
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add("显示行情", null, delegate { Dispatch(ShowWindow); });
            menu.Items.Add("隐藏行情", null, delegate { Dispatch(HideWindow); });
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("添加股票…", null, delegate { Dispatch(delegate { ShowWindow(); addStock(); }); });
            menu.Items.Add("刷新行情", null, delegate { Dispatch(refresh); });
            pinnedItem = new Forms.ToolStripMenuItem("窗口置顶") { Checked = Pinned };
            pinnedItem.Click += delegate { Dispatch(delegate { SetPinned(!Pinned); }); };
            autoHideItem = new Forms.ToolStripMenuItem("右侧自动吸附隐藏") { Checked = AutoHide };
            autoHideItem.Click += delegate { Dispatch(delegate { SetAutoHide(!AutoHide); }); };
            startupItem = new Forms.ToolStripMenuItem("开机启动") { Checked = IsStartupEnabled() };
            startupItem.Click += delegate { Dispatch(ToggleStartup); };
            menu.Items.Add(pinnedItem);
            menu.Items.Add(autoHideItem);
            menu.Items.Add(startupItem);
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { Dispatch(ExitApplication); });
            menu.Opening += delegate { startupItem.Checked = IsStartupEnabled(); };
            System.Drawing.Icon icon = null;
            string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "AppIcon.ico");
            try { if (File.Exists(iconPath)) icon = new System.Drawing.Icon(iconPath); } catch (Exception) { }
            if (icon == null) icon = (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
            tray = new Forms.NotifyIcon { Text = "A股桌面行情", Icon = icon, ContextMenuStrip = menu, Visible = true };
            tray.DoubleClick += delegate { Dispatch(ShowWindow); };
            tray.BalloonTipClicked += delegate { Dispatch(ShowWindow); };
        }

        private void Dispatch(Action action)
        {
            if (!disposed && !window.Dispatcher.HasShutdownStarted) window.Dispatcher.BeginInvoke(action);
        }

        private void ExitApplication()
        {
            if (disposed) return;
            exiting = true;
            SaveExpandedPosition();
            Dispose();
            window.Close();
            if (Application.Current != null) Application.Current.Shutdown();
        }

        private static string StartupCommand()
        {
            return "\"" + Assembly.GetEntryAssembly().Location + "\"";
        }

        private static bool IsStartupEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey, false))
                    return key != null && string.Equals(key.GetValue(StartupName) as string, StartupCommand(), StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception) { return false; }
        }

        private void ToggleStartup()
        {
            // This is the only registry write path, and is called only by a deliberate menu click.
            bool enable = !IsStartupEnabled();
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (key == null) throw new InvalidOperationException("无法访问当前用户的启动设置。");
                    if (enable) key.SetValue(StartupName, StartupCommand(), RegistryValueKind.String);
                    else key.DeleteValue(StartupName, false);
                }
                startupItem.Checked = IsStartupEnabled();
            }
            catch (Exception ex) { Notify("无法更改开机启动", ex.Message); }
        }

        private void Reveal(bool activate)
        {
            if (disposed) return;
            StopDelays();
            focusLossPointer = null;
            presentation = Presentation.Shown;
            if (handle != null) handle.Hide();
            Rect reference = CurrentReference();
            MoveWindow(AutoHide ? DesktopGeometry.DockRight(reference, WorkArea()) : DesktopGeometry.Clamp(reference, WorkArea()));
            if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
            bool showActivated = window.ShowActivated;
            window.ShowActivated = activate;
            try { window.Show(); }
            finally { window.ShowActivated = showActivated; }
            if (activate) window.Activate();
            SaveExpandedPosition();
            if (AutoHide) pointerTimer.Start();
        }

        private void TryHoverReveal()
        {
            if (disposed || !AutoHide || presentation != Presentation.Collapsed) return;
            NativePoint pointer;
            if (!Native.GetCursorPos(out pointer)) return;
            if (focusLossPointer.HasValue && pointer.X == focusLossPointer.Value.X && pointer.Y == focusLossPointer.Value.Y) return;
            Reveal(false);
        }

        private void Dock(bool collapse)
        {
            if (disposed || !AutoHide || presentation == Presentation.ManuallyHidden || hwnd == IntPtr.Zero) return;
            if (dragging || Mouse.LeftButton == MouseButtonState.Pressed) { ScheduleDock(collapse); return; }
            MoveWindow(DesktopGeometry.DockRight(CurrentReference(), WorkArea()));
            SaveExpandedPosition();
            UpdateHandle();
            if (collapse) Collapse();
        }

        private void Collapse()
        {
            if (disposed || !AutoHide || presentation != Presentation.Shown || dragging) return;
            if (KeepVisible()) { ScheduleCollapse(); return; }
            collapseTimer.Stop();
            SaveExpandedPosition();
            presentation = Presentation.Collapsed;
            UpdateHandle();
            window.Hide();
            if (handle != null) { handle.Show(); UpdateHandle(); }
        }

        private bool KeepVisible()
        {
            if (dragging || Mouse.LeftButton == MouseButtonState.Pressed) return true;
            foreach (Window owned in window.OwnedWindows) if (owned.IsVisible) return true;
            if (!window.IsActive) return false;
            DependencyObject focused = Keyboard.FocusedElement as DependencyObject;
            while (focused != null)
            {
                if (focused is TextBoxBase || focused is PasswordBox || focused is ComboBox) return true;
                if (focused is Visual || focused is System.Windows.Media.Media3D.Visual3D) focused = VisualTreeHelper.GetParent(focused);
                else focused = LogicalTreeHelper.GetParent(focused);
            }
            return false;
        }

        private void CheckPointer(object sender, EventArgs args)
        {
            if (disposed || !AutoHide || presentation == Presentation.ManuallyHidden || dragging) return;
            if (presentation == Presentation.Collapsed)
            {
                if (handle != null && handle.IsVisible && PointerInside(handleHwnd)) TryHoverReveal();
            }
            else if (PointerInside(hwnd) || KeepVisible()) collapseTimer.Stop();
            else ScheduleCollapse();
        }

        private static bool PointerInside(IntPtr target)
        {
            NativePoint point; NativeRect rect;
            return target != IntPtr.Zero && Native.GetCursorPos(out point) && Native.GetWindowRect(target, out rect)
                && point.X >= rect.Left && point.X < rect.Right && point.Y >= rect.Top && point.Y < rect.Bottom;
        }

        private void ScheduleCollapse() { if (!collapseTimer.IsEnabled) collapseTimer.Start(); }
        private void CollapseTick(object sender, EventArgs args)
        {
            collapseTimer.Stop();
            if (!PointerInside(hwnd) && !KeepVisible()) Collapse();
        }
        private void ScheduleDock(bool collapse)
        {
            pendingDockCollapse = collapse;
            dockTimer.Stop();
            dockTimer.Start();
        }
        private void DockTick(object sender, EventArgs args)
        {
            dockTimer.Stop();
            if (AutoHide) Dock(pendingDockCollapse);
            else if (presentation == Presentation.Shown) SaveExpandedPosition();
        }
        private void StopDelays() { collapseTimer.Stop(); dockTimer.Stop(); }

        private void StartMoving()
        {
            if (disposed || changingFrame) return;
            dragging = true;
            StopDelays();
            focusLossPointer = null;
            if (handle != null) handle.Hide();
            presentation = Presentation.Shown;
        }
        private void FinishMoving()
        {
            if (disposed) return;
            dragging = false;
            hasExpanded = false;
            SaveExpandedPosition();
            if (AutoHide) ScheduleDock(true);
        }

        private void SourceInitialized(object sender, EventArgs args) { AttachSource(); }
        private void AttachSource()
        {
            if (source != null || disposed) return;
            hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero) return;
            source = HwndSource.FromHwnd(hwnd);
            if (source != null) source.AddHook(WindowMessage);
        }
        private IntPtr WindowMessage(IntPtr target, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (message == 0x0231) StartMoving(); // WM_ENTERSIZEMOVE
            else if (message == 0x0232) FinishMoving(); // WM_EXITSIZEMOVE
            else if (message == 0x02E0 || message == 0x007E) Dispatch(RefreshGeometry); // DPI/display change; WPF processes first.
            return IntPtr.Zero;
        }
        private void WindowLoaded(object sender, RoutedEventArgs args) { Ready(); }
        private void WindowClosed(object sender, EventArgs args) { Dispose(); }
        private void WindowClosing(object sender, CancelEventArgs args)
        {
            if (exiting || disposed) return;
            args.Cancel = true;
            HideWindow();
        }
        private void WindowDeactivated(object sender, EventArgs args)
        {
            if (disposed || !AutoHide || presentation != Presentation.Shown || dragging || changingFrame) return;
            NativePoint point;
            if (Native.GetCursorPos(out point)) focusLossPointer = point;
            StopDelays();
            Dock(true);
        }
        private void WindowPositionChanged(object sender, EventArgs args)
        {
            if (disposed || changingFrame || settingUp || !initialized || dragging || presentation != Presentation.Shown) return;
            hasExpanded = false;
            ScheduleDock(AutoHide);
        }
        private void WindowSizeChanged(object sender, SizeChangedEventArgs args)
        {
            if (!initialized || changingFrame || disposed) return;
            Dispatch(RefreshGeometry);
        }
        private void DisplaySettingsChanged(object sender, EventArgs args) { Dispatch(RefreshGeometry); }
        private void RefreshGeometry()
        {
            if (disposed || hwnd == IntPtr.Zero || dragging) return;
            Rect current = WindowRectangle();
            if (hasExpanded) { current.X = expanded.X; current.Y = expanded.Y; }
            MoveWindow(AutoHide ? DesktopGeometry.DockRight(current, WorkArea()) : DesktopGeometry.Clamp(current, WorkArea()));
            SaveExpandedPosition();
            UpdateHandle();
        }

        private Rect CurrentReference() { return hasExpanded ? expanded : WindowRectangle(); }
        private Rect WindowRectangle()
        {
            NativeRect rect;
            if (hwnd != IntPtr.Zero && Native.GetWindowRect(hwnd, out rect)) return rect.ToRect();
            double width = double.IsNaN(window.Width) ? 440 : window.Width;
            double height = double.IsNaN(window.Height) ? 700 : window.Height;
            return new Rect(double.IsNaN(window.Left) ? 0 : window.Left, double.IsNaN(window.Top) ? 0 : window.Top, width, height);
        }
        private Rect WorkArea()
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
            IntPtr monitor = Native.MonitorFromWindow(hwnd, 2);
            if (monitor != IntPtr.Zero && Native.GetMonitorInfo(monitor, ref info)) return info.Work.ToRect();
            var area = Forms.Screen.PrimaryScreen.WorkingArea;
            return new Rect(area.X, area.Y, area.Width, area.Height);
        }
        private void MoveWindow(Rect rect)
        {
            changingFrame = true;
            try
            {
                if (hwnd != IntPtr.Zero) Native.SetWindowPos(hwnd, IntPtr.Zero, (int)Math.Round(rect.X), (int)Math.Round(rect.Y), 0, 0, 0x0015); // NOSIZE | NOZORDER | NOACTIVATE
                else { window.Left = rect.X; window.Top = rect.Y; }
                expanded = WindowRectangle();
                hasExpanded = true;
            }
            finally { changingFrame = false; }
        }
        private void UpdateHandle()
        {
            if (handle == null || handleHwnd == IntPtr.Zero || !hasExpanded) return;
            double scaleX = 1, scaleY = 1;
            if (source != null && source.CompositionTarget != null)
            { scaleX = source.CompositionTarget.TransformToDevice.M11; scaleY = source.CompositionTarget.TransformToDevice.M22; }
            Rect rect = DesktopGeometry.Handle(expanded, WorkArea(), scaleX, scaleY);
            Native.SetWindowPos(handleHwnd, new IntPtr(-1), (int)Math.Round(rect.X), (int)Math.Round(rect.Y), (int)Math.Round(rect.Width), (int)Math.Round(rect.Height), 0x0010);
        }
        private void SaveExpandedPosition()
        {
            if (hwnd == IntPtr.Zero || disposed || dragging) return;
            // Collapsing hides the main HWND without moving it, so collapsed geometry is never persisted.
            expanded = WindowRectangle();
            hasExpanded = true;
            if (!double.IsNaN(window.Left) && !double.IsNaN(window.Top)) positionSaved(window.Left, window.Top);
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            StopDelays();
            pointerTimer.Stop();
            pointerTimer.Tick -= CheckPointer;
            collapseTimer.Tick -= CollapseTick;
            dockTimer.Tick -= DockTick;
            SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
            window.SourceInitialized -= SourceInitialized;
            window.Loaded -= WindowLoaded;
            window.Closing -= WindowClosing;
            window.Closed -= WindowClosed;
            window.Deactivated -= WindowDeactivated;
            window.LocationChanged -= WindowPositionChanged;
            window.SizeChanged -= WindowSizeChanged;
            if (source != null) { source.RemoveHook(WindowMessage); source = null; }
            if (handle != null) { handle.Close(); handle = null; }
            if (tray != null)
            {
                tray.Visible = false;
                System.Drawing.Icon icon = tray.Icon;
                Forms.ContextMenuStrip menu = tray.ContextMenuStrip;
                tray.Dispose();
                if (icon != null) icon.Dispose();
                if (menu != null) menu.Dispose();
                tray = null;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativePoint { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect
        {
            public int Left, Top, Right, Bottom;
            public Rect ToRect() { return new Rect(Left, Top, Math.Max(0, Right - Left), Math.Max(0, Bottom - Top)); }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
        private static class Native
        {
            [DllImport("user32.dll")] internal static extern bool GetCursorPos(out NativePoint point);
            [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
            [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
            [DllImport("user32.dll")] internal static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
            [DllImport("user32.dll", CharSet = CharSet.Auto)] internal static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
            [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] internal static extern int GetWindowLong(IntPtr hwnd, int index);
            [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] internal static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        }
    }
}
