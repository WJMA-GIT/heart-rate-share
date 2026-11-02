namespace HeartRateShare.Desktop;

/// 悬浮窗手动拖动的位置计算（纯函数，可单测）。
public static class OverlayDrag
{
    /// startWindow 是按下时的窗口位置（DIP），startCursor/currentCursor 是屏幕物理像素，
    /// dpiScale 是当前显示器缩放（1.25 = 125%）。返回新的窗口左上角（DIP）。
    public static (double Left, double Top) Compute(
        (double Left, double Top) startWindow,
        (double X, double Y) startCursor,
        (double X, double Y) currentCursor,
        double dpiScale)
    {
        var scale = dpiScale <= 0 ? 1.0 : dpiScale;
        return (
            startWindow.Left + (currentCursor.X - startCursor.X) / scale,
            startWindow.Top + (currentCursor.Y - startCursor.Y) / scale);
    }
}
