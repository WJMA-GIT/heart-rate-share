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
        var refreshes = 0;
        for (var i = 0; i < 10; i++)
        {
            if (table.Observe(0xAABB, "心率带", (short)-60, true, now.AddMilliseconds(i * 100)))
                refreshes++;
        }
        var rows = table.Snapshot();
        Assert.Single(rows);
        Assert.Equal("心率带", rows[0].Name);
        // 只有第一条算"值得刷新"，后面同一 RSSI 不刷新 UI（列表不闪）
        Assert.Equal(1, refreshes);
    }

    [Fact]
    public void RssiChangeTriggersRefresh()
    {
        var table = new BleDeviceTable();
        var now = DateTime.UtcNow;
        table.Observe(1, "a", -60, true, now);
        Assert.True(table.Observe(1, "a", -70, true, now.AddSeconds(1)));
    }

    [Fact]
    public void ExpiresOnlyAfterKeepAlive()
    {
        var table = new BleDeviceTable();
        var now = DateTime.UtcNow;
        table.Observe(2, "b", -50, true, now);
        Assert.Empty(table.Expire(now.AddSeconds(20)));
        Assert.Single(table.Snapshot());
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

    [Theory]
    [InlineData(1, BleConnectFailure.Unreachable)]
    [InlineData(3, BleConnectFailure.AccessDenied)]
    [InlineData(4, BleConnectFailure.AddressTypeMismatch)]
    [InlineData(2, BleConnectFailure.ProtocolError)]
    public void MapsGattStatus(int status, BleConnectFailure expected) =>
        Assert.Equal(expected, BleErrors.FromStatus(status));
}
