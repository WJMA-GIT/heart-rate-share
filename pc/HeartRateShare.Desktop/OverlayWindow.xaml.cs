using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace HeartRateShare.Desktop;

/// 透明置顶悬浮窗：名称｜心率｜迷你折线，左侧 16px 拖动条，右侧 24px 断开图标。
public partial class OverlayWindow : Window
{
    private double _fontSize = 48;

    public OverlayWindow()
    {
        InitializeComponent();
        Left = SystemParameters.WorkArea.Right - 360;
        Top = 80;
    }

    public void Refresh()
    {
        Rows.Children.Clear();
        foreach (var member in AppState.Current.Members)
        {
            var row = new Grid { Height = Math.Max(28, _fontSize * 1.4), Margin = new Thickness(0, 2, 0, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_fontSize * 2.2) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });

            // 拖动条：透明但可点（拖动整窗）
            var handle = new Border { Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)) };
            handle.MouseLeftButtonDown += (_, _) => DragMove();
            Grid.SetColumn(handle, 0);
            row.Children.Add(handle);

            var name = new TextBlock
            {
                Text = member.Name,
                FontSize = Math.Max(12, _fontSize * 0.3),
                Foreground = Brushes.White,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);

            var bpm = new TextBlock
            {
                Text = member.Bpm?.ToString() ?? "--",
                FontSize = _fontSize,
                FontWeight = FontWeights.Bold,
                Foreground = (Brush)FindResource("Accent"),
                TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(bpm, 2);
            row.Children.Add(bpm);

            var spark = new Canvas { Margin = new Thickness(4, 0, 4, 0) };
            DrawSpark(spark, member);
            Grid.SetColumn(spark, 3);
            row.Children.Add(spark);

            var close = new Border
            {
                Width = 24,
                Height = 24,
                CornerRadius = new CornerRadius(12),
                BorderBrush = Brushes.White,
                BorderThickness = new Thickness(1),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock
                {
                    Text = "⏻",
                    FontSize = 11,
                    Foreground = Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            close.MouseLeftButtonDown += (_, _) => AppState.Current.Disconnect();
            Grid.SetColumn(close, 4);
            row.Children.Add(close);

            Rows.Children.Add(row);
        }
    }

    private static void DrawSpark(Canvas canvas, Member member)
    {
        canvas.SizeChanged += (_, _) => Paint(canvas, member);
    }

    private void Paint(Canvas canvas, Member member)
    {
        canvas.Children.Clear();
        var width = canvas.ActualWidth;
        var height = canvas.ActualHeight;
        if (width <= 1 || height <= 1 || member.Samples.Count < 2) return;
        var min = member.Samples.Min(s => s.Bpm) - 5;
        var max = member.Samples.Max(s => s.Bpm) + 5;
        if (max - min < 10) { min -= 5; max += 5; }
        var line = new Polyline
        {
            Stroke = (Brush)FindResource("Accent"),
            StrokeThickness = 1.6,
        };
        var samples = member.Samples.ToList();
        for (var i = 0; i < samples.Count; i++)
        {
            line.Points.Add(new Point(
                width * i / Math.Max(1, samples.Count - 1),
                height - height * (samples[i].Bpm - min) / (max - min)));
        }
        canvas.Children.Add(line);
    }
}
