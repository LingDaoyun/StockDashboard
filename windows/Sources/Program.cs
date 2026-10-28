using System;
using System.IO;
using System.Threading;
using System.Windows;

namespace StockDashboard
{
    internal static class Program
    {
        [STAThread]
        public static void Main(string[] args)
        {
            string dataPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StockDashboard", "settings.json");
            bool isolated = false;
            for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--data-dir") { dataPath = Path.Combine(Path.GetFullPath(args[++i]), "settings.json"); isolated = true; }
            bool created;
            using (var mutex = new Mutex(true, isolated ? "Local\\StockDashboard-" + dataPath.GetHashCode() : "Local\\StockDashboard-Windows", out created))
            {
                if (!created) { MessageBox.Show("程序已在运行，请从任务栏右下角托盘图标打开。", "A股桌面行情"); return; }
                var app = new Application();
                app.ShutdownMode = ShutdownMode.OnMainWindowClose;
                app.DispatcherUnhandledException += delegate(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e) {
                    try { Directory.CreateDirectory(Path.GetDirectoryName(dataPath)); File.AppendAllText(Path.Combine(Path.GetDirectoryName(dataPath), "error.log"), DateTime.Now + " " + e.Exception + Environment.NewLine); } catch { }
                    MessageBox.Show("操作失败，设置未主动清空。详情已记录到本地 error.log。\n" + e.Exception.Message, "A股桌面行情");
                    e.Handled = true;
                };
                app.Run(new MainWindow(dataPath));
            }
        }
    }
}
