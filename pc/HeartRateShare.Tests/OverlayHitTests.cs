using HeartRateShare.Desktop;
using Xunit;

namespace HeartRateShare.Tests;

/// 悬浮窗命中规则：按在名称/心率/折线上可拖，行间空隙与四周留白穿透。
public class OverlayHitTests
{
    private const int Rows = 3;
    private const double RowHeight = 60;

    [Theory]
    // 第 1 行内容带（padding 4 + gap 2 → 6..66）
    [InlineData(20, 30, OverlayHit.Drag)]
    [InlineData(200, 8, OverlayHit.Drag)]
    // 行间空隙：第 1/2 行之间 66..70
    [InlineData(20, 68, OverlayHit.PassThrough)]
    // 顶部留白 0..6
    [InlineData(20, 2, OverlayHit.PassThrough)]
    // 第 3 行内容带：4+2*(62)+2 = 130..190
    [InlineData(20, 150, OverlayHit.Drag)]
    // 最后一行之后的留白
    [InlineData(20, 200, OverlayHit.PassThrough)]
    // 窗口外
    [InlineData(-1, 30, OverlayHit.PassThrough)]
    public void ClassifiesPoints(double x, double y, OverlayHit expected) =>
        Assert.Equal(expected, OverlayHitTest.Compute(x, y, Rows, RowHeight));

    [Fact]
    public void FirstRowStartsAfterPaddingAndGap()
    {
        Assert.Equal(OverlayHit.PassThrough, OverlayHitTest.Compute(10, 5, Rows, RowHeight));
        Assert.Equal(OverlayHit.Drag, OverlayHitTest.Compute(10, 6, Rows, RowHeight));
    }
}
