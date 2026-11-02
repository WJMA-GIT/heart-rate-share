namespace HeartRateShare.Desktop;

public enum OverlayHit
{
    /// 按在名称/心率/折线上：可拖动整窗
    Drag,
    /// 行间空隙、四周留白、窗口透明像素：鼠标穿透到下层
    PassThrough,
}

/// 悬浮窗命中规则（纯函数，CI 可断言）：
/// 行内容带 = 可拖；行与行之间的 2 DIP 间隙、窗口 4 DIP 留白 = 穿透。
public static class OverlayHitTest
{
    public const double Padding = 4;   // 窗口内边距（透明，穿透）
    public const double RowGap = 2;    // 每行上下的透明间隙（穿透）

    public static OverlayHit Compute(double x, double y, int rows, double rowHeight)
    {
        if (x < 0 || y < 0) return OverlayHit.PassThrough;
        for (var index = 0; index < rows; index++)
        {
            var top = Padding + index * (rowHeight + RowGap * 2) + RowGap;
            if (y >= top && y < top + rowHeight) return OverlayHit.Drag;
        }
        return OverlayHit.PassThrough;
    }
}
