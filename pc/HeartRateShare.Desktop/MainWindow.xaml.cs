using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace HeartRateShare.Desktop;

public partial class MainWindow : Window
{
    private readonly DispatcherTimer _render;
    private OverlayWindow? _overlay;

    public MainWindow()
    {
        InitializeComponent();
        AppState.Current.Changed += Refresh;
        AppState.Current.OverlayRequested += ToggleOverlay;
        _render = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _render.Tick += (_, _) => Refresh();
        _render.Start();
        Loaded += (_, _) => Refresh();
        Closed += (_, _) => _overlay?.Close();
    }

    private void Nav_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string tag }) return;
        foreach (var (border, label) in new[]
                 {
                     (NavHeart, (TextBlock)NavHeart.Child),
                     (NavRoom, (TextBlock)NavRoom.Child),
                     (NavSettings, (TextBlock)NavSettings.Child),
                 })
        {
            var on = ReferenceEquals(border, sender);
            border.Background = on
                ? (Brush)FindResource("AccentSoft")
                : Brushes.Transparent;
            label.Foreground = on
                ? (Brush)FindResource("Accent")
                : (Brush)FindResource("TextDim");
        }
        PageTitle.Text = tag switch
        {
            "room" => "房间",
            "settings" => "设置",
            _ => "当前心率",
        };
    }

    private void Scan_Click(object sender, RoutedEventArgs e) => BleHint.Text = "扫描中…（Phase 1 接 BLE）";
    private void Disconnect_Click(object sender, RoutedEventArgs e) => AppState.Current.Disconnect();
    private void Manual_Click(object sender, RoutedEventArgs e) { }

    private void ToggleOverlay(bool show)
    {
        if (show)
        {
            _overlay ??= new OverlayWindow();
            if (!_overlay.IsVisible) _overlay.Show();
        }
        else if (_overlay is not null)
        {
            _overlay.Hide();
        }
    }

    private void Refresh()
    {
        var state = AppState.Current;
        var first = state.Members.FirstOrDefault(m => m.Online);
        BpmText.Text = first?.Bpm?.ToString() ?? "--";
        PageSubtitle.Text = state.Connected ? $"当前通路：{state.Transport}" : "未连接";
        BleHint.Text = state.Connected
            ? $"已连接 {state.Members.Count} 个成员"
            : "未发现心率设备：确认蓝牙已开、设备没被手机占用、戴上唤醒后再扫描";
        DrawChart(first);
        if (state.Connected && _overlay is not null && !_overlay.IsVisible) _overlay.Show();
        _overlay?.Refresh();
        if (!state.Connected && _overlay is { IsVisible: true }) _overlay.Hide();
    }

    private void DrawChart(Member? member)
    {
        ChartCanvas.Children.Clear();
        var width = ChartCanvas.ActualWidth;
        var height = ChartCanvas.ActualHeight;
        if (width <= 1 || height <= 1 || member is null || member.Samples.Count < 2) return;

        var samples = member.Samples.ToList();
        var min = samples.Min(s => s.Bpm) - 5;
        var max = samples.Max(s => s.Bpm) + 5;
        if (max - min < 10) { min -= 5; max += 5; }

        var line = new Polyline
        {
            Stroke = (Brush)FindResource("Accent"),
            StrokeThickness = 2,
            StrokeLineJoin = PenLineJoin.Round,
        };
        for (var i = 0; i < samples.Count; i++)
        {
            var x = width * i / Math.Max(1, samples.Count - 1);
            var y = height - (height * (samples[i].Bpm - min) / (max - min));
            line.Points.Add(new Point(x, y));
        }
        ChartCanvas.Children.Add(line);

        // 左轴动态刻度（3–5 档整数）
        var steps = 4;
        for (var i = 0; i <= steps; i++)
        {
            var value = min + (max - min) * i / steps;
            var label = new TextBlock
            {
                Text = ((int)Math.Round(value)).ToString(),
                FontSize = 10,
                Foreground = (Brush)FindResource("TextDim"),
            };
            Canvas.SetLeft(label, 0);
            Canvas.SetTop(label, height - (height * i / steps) - 8);
            ChartCanvas.Children.Add(label);
        }
    }
}
