using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Shapes;

namespace HeartRateShare.Desktop;

/// 透明置顶悬浮窗：名称｜心率｜迷你折线，左侧 16px 拖动条，右侧 24px 断开图标。
public partial class OverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExTransparent = 0x20;
    private const int WsExNoActivate = 0x08000000;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy,
        uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);

    private double _fontSize = 48;
    private bool _dragging;
    private POINT _dragStartCursor;
    private (double Left, double Top) _dragStartWindow;

    public OverlayWindow()
    {
        InitializeComponent();
        Left = SystemParameters.WorkArea.Right - 380;
        Top = 90;
    }

    public double FontSize
    {
        get => _fontSize;
        set
        {
            _fontSize = Math.Clamp(value, 24, 96);
            Refresh();
        }
    }

    /// 点击穿透：鼠标事件直接落到下层（游戏）里，窗口不再接收拖动/断开点击。
    /// 解除方式：主窗口「设置 → 悬浮窗点击穿透」取消勾选（主窗口永远可点）。
    public void SetClickThrough(bool enabled)
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        var exStyle = GetWindowLong(handle, GwlExStyle);
        exStyle = enabled
            ? exStyle | WsExTransparent | WsExNoActivate
            : exStyle & ~WsExTransparent;
        SetWindowLong(handle, GwlExStyle, exStyle);
        SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0,
            SwpNoMove | SwpNoSize | SwpNoZOrder | SwpFrameChanged | SwpNoActivate);
        AppState.Log($"overlay click-through={enabled}");
    }

    public void Refresh()
    {
        Rows.Children.Clear();
        var state = AppState.Current;
        foreach (var member in state.Members)
        {
            var row = new Grid
            {
                Height = Math.Max(28, _fontSize * 1.4),
                Margin = new Thickness(0, 2, 0, 2),
            };
            for (var i = 0; i < 4; i++) row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions[0].Width = new GridLength(18);          // 拖动条 18 DIP
            row.ColumnDefinitions[1].Width = new GridLength(_fontSize * 4.6);
            row.ColumnDefinitions[2].Width = new GridLength(_fontSize * 2.2);
            row.ColumnDefinitions[3].Width = new GridLength(90);

            // 拖动条：Brushes.Transparent（不是 null）才收得到命中；拖动走 Win32，
            // 因为 ShowActivated=false 时 WPF 的 DragMove() 不生效。
            var handle = new Border
            {
                Background = Brushes.Transparent,
                IsHitTestVisible = true,
            };
            handle.MouseLeftButtonDown += (_, _) => BeginDrag();
            handle.MouseMove += (_, _) => DragMoveStep();
            handle.MouseLeftButtonUp += (_, _) => EndDrag();
            Grid.SetColumn(handle, 0);
            row.Children.Add(handle);

            var name = new TextBlock
            {
                Text = member.Name,
                // 名称与心率同字号（用户要求），行高按 1.4 倍留白
                FontSize = _fontSize,
                Foreground = Brushes.White,
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);

            var bpm = new TextBlock
            {
                Text = member.Bpm.ToString(),
                FontSize = _fontSize,
                FontWeight = FontWeights.Bold,
                Foreground = (Brush)FindResource("Accent"),
                TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(bpm, 2);
            row.Children.Add(bpm);

            var spark = new Canvas { Margin = new Thickness(4, 0, 4, 0) };
            DrawSpark(spark, state.History.TryGetValue(member.Id, out var values) ? values : []);
            Grid.SetColumn(spark, 3);
            row.Children.Add(spark);

            Rows.Children.Add(row);
        }
    }

    /// 手动拖动：不依赖 WPF 的 DragMove，也不依赖 WM_NCLBUTTONDOWN
    /// （ShowActivated=false 时那两个都不灵）。位移换算在 OverlayDrag 里（可单测）。
    private void BeginDrag()
    {
        if (!GetCursorPos(out _dragStartCursor)) return;
        _dragStartWindow = (Left, Top);
        _dragging = true;
        ((UIElement)Rows.Parent).CaptureMouse();
        AppState.Log($"overlay: drag start ({_dragStartCursor.X},{_dragStartCursor.Y})");
    }

    private void DragMoveStep()
    {
        if (!_dragging || !GetCursorPos(out var current)) return;
        var scale = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        var (left, top) = OverlayDrag.Compute(_dragStartWindow,
            (_dragStartCursor.X, _dragStartCursor.Y), (current.X, current.Y), scale);
        Left = left;
        Top = top;
        AppState.Log($"overlay: drag move left={left:F0} top={top:F0}");
    }

    private void EndDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        ((UIElement)Rows.Parent).ReleaseMouseCapture();
    }

    private void DrawSpark(Canvas canvas, List<int> values)
    {
        canvas.SizeChanged += (_, _) => Paint(canvas, values);
        Paint(canvas, values);
    }

    private void Paint(Canvas canvas, List<int> values)
    {
        canvas.Children.Clear();
        var width = canvas.ActualWidth;
        var height = canvas.ActualHeight;
        if (width <= 1 || height <= 1 || values.Count < 2) return;
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
                width * i / (values.Count - 1),
                height - height * (values[i] - min) / (max - min)));
        }
        canvas.Children.Add(line);
    }
}
