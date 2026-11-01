using System.Diagnostics;
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
        Loaded += (_, _) =>
        {
            LogPathText.Text = AppState.LogPath;
            var version = typeof(AppState).Assembly.GetName().Version;
            AboutText.Text = $"共享心率 {version?.Major}.{version?.Minor}.{version?.Build} · Windows (WPF)";
            Refresh();
        };
        Closed += (_, _) => _overlay?.Close();
    }

    // ---------------------------------------------------------------- 导航

    private void Nav_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string tag }) return;
        HeartPanel.Visibility = tag == "heart" ? Visibility.Visible : Visibility.Collapsed;
        RoomPanel.Visibility = tag == "room" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPanel.Visibility = tag == "settings" ? Visibility.Visible : Visibility.Collapsed;
        Highlight(NavHeart, NavHeartText, tag == "heart");
        Highlight(NavRoom, NavRoomText, tag == "room");
        Highlight(NavSettings, NavSettingsText, tag == "settings");
    }

    private void Highlight(Border border, TextBlock label, bool on)
    {
        border.Background = on ? (Brush)FindResource("AccentSoft") : Brushes.Transparent;
        label.Foreground = on ? (Brush)FindResource("Accent") : (Brush)FindResource("TextDim");
    }

    // ---------------------------------------------------------------- 操作

    private void Scan_Click(object sender, RoutedEventArgs e) => AppState.Current.ScanBle();

    private void Disconnect_Click(object sender, RoutedEventArgs e) => AppState.Current.Disconnect();

    private void Manual_Click(object sender, RoutedEventArgs e) =>
        _ = AppState.Current.ConnectManualAsync(ManualIp.Text);

    private void Cloud_Click(object sender, RoutedEventArgs e)
    {
        AppState.Current.Server = ServerBox.Text.Trim();
        _ = AppState.Current.ConnectCloudAsync(RoomBox.Text);
    }

    private void LanDiscover_Click(object sender, RoutedEventArgs e) => AppState.Current.StartLanDiscovery();

    private void CopyRoom_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(AppState.Current.RoomCode)) return;
        try
        {
            Clipboard.SetText(AppState.Current.RoomCode);
        }
        catch (Exception)
        {
            // 剪贴板被占用就算了
        }
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = System.IO.Path.GetDirectoryName(AppState.LogPath)!,
                UseShellExecute = true,
            });
        }
        catch (Exception)
        {
            // 打不开目录不影响使用
        }
    }

    private void CopyDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(AppState.Current.Diagnostics());
        }
        catch (Exception)
        {
            // 剪贴板被占用就算了
        }
    }

    private void Font_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_overlay is not null) _overlay.FontSize = e.NewValue;
    }

    // ---------------------------------------------------------------- 悬浮窗

    private void ToggleOverlay(bool show)
    {
        if (!(OverlayBox.IsChecked ?? true)) return;
        if (show)
        {
            _overlay ??= new OverlayWindow { FontSize = FontSlider.Value };
            _overlay.SetClickThrough(ClickThroughBox.IsChecked ?? false);
            _overlay.Refresh();
            if (!_overlay.IsVisible) _overlay.Show();
        }
        else if (_overlay is { IsVisible: true })
        {
            _overlay.Hide();
        }
    }

    // ---------------------------------------------------------------- 刷新

    private void Refresh()
    {
        var state = AppState.Current;
        var first = state.Members.FirstOrDefault();
        BpmText.Text = first?.Bpm.ToString() ?? "--";
        TransportText.Text = state.Connected
            ? $"当前通路：{state.Transport}   {state.Status}"
            : string.IsNullOrEmpty(state.Status) ? "未连接" : state.Status;
        MemberHint.Text = state.Members.Count == 0
            ? "还没有数据：先连蓝牙设备，或到「房间」页连局域网/云端"
            : "";
        RoomCodeText.Text = string.IsNullOrEmpty(state.RoomCode) ? "—" : state.RoomCode;
        RoomStatusText.Text = state.Status;
        AppState.Current.DisplayName = NameBox.Text.Trim();
        AppState.Current.ShowAllBle = ShowAllBleBox.IsChecked ?? false;
        var clickThrough = ClickThroughBox.IsChecked ?? false;
        if (clickThrough != AppState.Current.OverlayClickThrough)
        {
            AppState.Current.OverlayClickThrough = clickThrough;
            _overlay?.SetClickThrough(clickThrough);
        }
        DiagnosticsText.Text = state.Diagnostics();

        DrawChart(first);
        BuildMembers(state);
        BuildBle(state);
        BuildPeers(state);
        if (state.Members.Count > 0 && state.Connected && _overlay is not null) _overlay.Refresh();
    }

    private void BuildMembers(AppState state)
    {
        MemberList.Children.Clear();
        foreach (var row in state.Members)
        {
            var grid = new Grid { Height = 44 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });

            var name = new TextBlock
            {
                Text = row.Name,
                FontSize = 15,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("TextMain"),
            };
            Grid.SetColumn(name, 0);
            grid.Children.Add(name);

            var bpm = new TextBlock
            {
                Text = row.Bpm.ToString(),
                FontSize = 15,
                FontWeight = FontWeights.SemiBold,
                TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = row.Online ? (Brush)FindResource("Accent") : (Brush)FindResource("TextDim"),
            };
            Grid.SetColumn(bpm, 1);
            grid.Children.Add(bpm);

            var spark = BuildSpark(state.History.TryGetValue(row.Id, out var values) ? values : []);
            Grid.SetColumn(spark, 2);
            grid.Children.Add(spark);

            MemberList.Children.Add(grid);
        }
    }

    private void BuildBle(AppState state)
    {
        BleList.Children.Clear();
        foreach (var device in state.BleDevices)
        {
            var grid = new Grid { Height = 40 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });

            var name = new TextBlock
            {
                Text = string.IsNullOrEmpty(device.Name) ? "(未命名)" : device.Name,
                FontSize = 14,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("TextMain"),
            };
            Grid.SetColumn(name, 0);
            grid.Children.Add(name);

            var info = new TextBlock
            {
                Text = $"0x{device.Address:X} · {device.Rssi} dBm",
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("TextDim"),
            };
            Grid.SetColumn(info, 1);
            grid.Children.Add(info);

            var connect = new Button { Content = "连接", Padding = new Thickness(12, 2, 12, 2) };
            connect.Click += (_, _) => _ = AppState.Current.ConnectBleAsync(device);
            Grid.SetColumn(connect, 2);
            grid.Children.Add(connect);

            BleList.Children.Add(grid);
        }
    }

    private void BuildPeers(AppState state)
    {
        LanList.Children.Clear();
        LanPeers.Children.Clear();
        foreach (var peer in state.Peers)
        {
            var grid = new Grid { Height = 40 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });

            var name = new TextBlock
            {
                Text = peer.Name,
                FontSize = 14,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("TextMain"),
            };
            Grid.SetColumn(name, 0);
            grid.Children.Add(name);

            var info = new TextBlock
            {
                Text = $"{peer.Host}:{peer.Port} · {peer.Members} 人",
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = (Brush)FindResource("TextDim"),
            };
            Grid.SetColumn(info, 1);
            grid.Children.Add(info);

            var connect = new Button { Content = "连接", Padding = new Thickness(12, 2, 12, 2) };
            connect.Click += (_, _) => _ = AppState.Current.ConnectPeerAsync(peer);
            Grid.SetColumn(connect, 2);
            grid.Children.Add(connect);

            LanList.Children.Add(grid);
        }
    }

    private FrameworkElement BuildSpark(List<int> values)
    {
        var canvas = new Canvas { Height = 28, Width = 86 };
        if (values.Count >= 2)
        {
            var min = values.Min() - 5;
            var max = values.Max() + 5;
            if (max - min < 10) { min -= 5; max += 5; }
            var line = new Polyline
            {
                Stroke = (Brush)FindResource("Accent"),
                StrokeThickness = 1.6,
            };
            for (var i = 0; i < values.Count; i++)
            {
                line.Points.Add(new Point(
                    86.0 * i / (values.Count - 1),
                    28 - 28.0 * (values[i] - min) / (max - min)));
            }
            canvas.Children.Add(line);
        }
        return canvas;
    }

    private void DrawChart(MemberRow? row)
    {
        ChartCanvas.Children.Clear();
        var width = ChartCanvas.ActualWidth;
        var height = ChartCanvas.ActualHeight;
        var state = AppState.Current;
        if (row is null || width <= 1 || height <= 1) return;
        if (!state.History.TryGetValue(row.Id, out var values) || values.Count < 2) return;

        var min = values.Min() - 5;
        var max = values.Max() + 5;
        if (max - min < 10) { min -= 5; max += 5; }

        var line = new Polyline
        {
            Stroke = (Brush)FindResource("Accent"),
            StrokeThickness = 2,
            StrokeLineJoin = PenLineJoin.Round,
        };
        for (var i = 0; i < values.Count; i++)
        {
            line.Points.Add(new Point(
                width * i / (values.Count - 1),
                height - height * (values[i] - min) / (max - min)));
        }
        ChartCanvas.Children.Add(line);

        for (var i = 0; i <= 4; i++)
        {
            var value = min + (max - min) * (double)i / 4;
            var label = new TextBlock
            {
                Text = ((int)Math.Round(value)).ToString(),
                FontSize = 10,
                Foreground = (Brush)FindResource("TextDim"),
            };
            Canvas.SetLeft(label, 0);
            Canvas.SetTop(label, height - height * i / 4 - 8);
            ChartCanvas.Children.Add(label);
        }
    }
}
