using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace StockDashboard
{
    internal static class Theme
    {
        public static readonly Brush Ink = Hex("#EDF3FF"), Muted = Hex("#8E9FB8"), Blue = Hex("#6FA8FF"), Up = Hex("#FF737C"), Down = Hex("#4BD8AA"), Line = Hex("#263950"), Amber = Hex("#F5BC6B");
        public static Brush Hex(string value) { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(value)); }
        public static Brush Direction(decimal? value) { return !value.HasValue || value.Value == 0 ? Ink : value > 0 ? Up : Down; }
        public static TextBlock Text(string text, double size, Brush color)
        { return new TextBlock { Text = text, FontSize = size, Foreground = color, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis }; }
        public static Button Button(string text, string tip, Action action)
        {
            var b = new Button { Content = text, ToolTip = tip, Padding = new Thickness(7, 4, 7, 4), Margin = new Thickness(2), Cursor = System.Windows.Input.Cursors.Hand, Foreground = Ink, Background = Brushes.Transparent, BorderThickness = new Thickness(0), FontSize = 14, MinHeight = 28 };
            var template = new ControlTemplate(typeof(Button));
            var border = new FrameworkElementFactory(typeof(Border)); border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6)); border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
            var content = new FrameworkElementFactory(typeof(ContentPresenter)); content.SetValue(ContentPresenter.HorizontalAlignmentProperty, new TemplateBindingExtension(Control.HorizontalContentAlignmentProperty)); content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center); content.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(Control.PaddingProperty)); border.AppendChild(content); template.VisualTree = border;
            var over = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true }; over.Setters.Add(new Setter(Control.BackgroundProperty, Hex("#30435E"))); template.Triggers.Add(over); b.Template = template;
            b.Click += delegate { action(); }; return b;
        }
        public static TextBox Input(string value, string tip)
        { return new TextBox { Text = value ?? "", ToolTip = tip, FontSize = 12, Foreground = Ink, Background = Hex("#101D30"), BorderBrush = Line, BorderThickness = new Thickness(1), Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 3, 6, 3), CaretBrush = Ink, SelectionBrush = Blue, MinHeight = 30 }; }
        public static Border Panel(UIElement child, Thickness padding)
        { return new Border { Child = child, Padding = padding, CornerRadius = new CornerRadius(10), BorderBrush = Line, BorderThickness = new Thickness(1), Background = Brushes.Transparent }; }
        public static string Number(decimal? value, string format) { return value.HasValue ? value.Value.ToString(format, System.Globalization.CultureInfo.InvariantCulture) : "—"; }
        public static string Money(decimal? value) { return Number(value, "+0.00;-0.00;0.00"); }
        public static string Compact(decimal? value)
        {
            if (!value.HasValue) return "—"; decimal n = value.Value;
            return Math.Abs(n) >= 1000000000000m ? (n / 1000000000000m).ToString("0.00") + "万亿" : Math.Abs(n) >= 100000000m ? (n / 100000000m).ToString("0.00") + "亿" : Math.Abs(n) >= 10000m ? (n / 10000m).ToString("0.00") + "万" : n.ToString("0.##");
        }
    }
}
