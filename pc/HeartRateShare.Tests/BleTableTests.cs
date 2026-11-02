using HeartRateShare.Desktop;
using Xunit;

namespace HeartRateShare.Tests;

public class BleTableTests
{
    [Fact]
    public void SameAddressTenAdvertsStaysOneEntry()
    {
        var table = new BleDeviceTable();
        var now = DateTime.UtcNow;
        for (var i = 0; i < 10; i++)
            table.Observe(0xAABB, "心率带", -60, true, now.AddMilliseconds(i * 100));
        Assert.Single(table.Snapshot());
    }

    [Fact]
    public void ShorterNamesNeverOverwriteLongerOnes()
    {
        var table = new BleDeviceTable();
        var now = DateTime.UtcNow;
        var entry = table.Find(0xAABB);
        table.Observe(0xAABB, "", -60, true, now);
        table.Observe(0xAABB, "Polar", -60, true, now.AddMilliseconds(100));
        table.Observe(0xAABB, "Po", -60, true, now.AddMilliseconds(200));
        table.Observe(0xAABB, "Polar H10", -60, true, now.AddMilliseconds(300));
        entry = table.Find(0xAABB);
        Assert.Equal("Polar H10", entry!.Name);
    }

    [Fact]
    public void RssiUpdatesKeepTheSameInstance()
    {
        var table = new BleDeviceTable(rssiInterval: TimeSpan.FromMilliseconds(500));
        var now = DateTime.UtcNow;
        table.Observe(1, "a", -60, true, now);
        var first = table.Find(1);
        for (var i = 1; i <= 10; i++)
            table.Observe(1, "a", (short)(-60 - i), true, now.AddMilliseconds(i * 600));
        var again = table.Find(1);
        Assert.Same(first, again);                 // 列表项实例不变 → 不重建模板 → 不闪
        Assert.Equal(-70, again!.Rssi);
    }

    [Fact]
    public void ExpiresOnlyAfterKeepAlive()
    {
        var table = new BleDeviceTable();
        var now = DateTime.UtcNow;
        table.Observe(2, "b", -50, true, now);
        Assert.Empty(table.Expire(now.AddSeconds(20)));
        Assert.Single(table.Expire(now.AddSeconds(31)));
        Assert.Empty(table.Snapshot());
    }
}

public class BleErrorTests
{
    [Theory]
    [InlineData(BleConnectFailure.Unreachable, "被手机 App 占用")]
    [InlineData(BleConnectFailure.AccessDenied, "配对")]
    [InlineData(BleConnectFailure.AddressTypeMismatch, "地址类型")]
    [InlineData(BleConnectFailure.ProtocolError, "GATT")]
    public void DescribesEachFailure(BleConnectFailure failure, string keyword) =>
        Assert.Contains(keyword, BleErrors.Describe(failure));
}

public class OverlayDragTests
{
    [Fact]
    public void MovesByCursorDeltaOverDpiScale()
    {
        var (left, top) = OverlayDrag.Compute((100, 200), (500, 500), (560, 540), 1.25);
        Assert.Equal(148, left, 3);   // (560-500)/1.25 = 48
        Assert.Equal(232, top, 3);    // (540-500)/1.25 = 32
    }

    [Fact]
    public void HandlesZeroScale()
    {
        var (left, top) = OverlayDrag.Compute((0, 0), (10, 10), (20, 30), 0);
        Assert.Equal(10, left, 3);
        Assert.Equal(20, top, 3);
    }
}
