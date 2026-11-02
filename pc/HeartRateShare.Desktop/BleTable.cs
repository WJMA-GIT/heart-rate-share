namespace HeartRateShare.Desktop;

public sealed record BleEntry(ulong Address, string Name, short Rssi, bool IsHeartRate, DateTime LastSeen);

/// 蓝牙设备表（纯逻辑，可单测）：同一地址只更新、不新增；30 秒没再听到才过期。
public sealed class BleDeviceTable(TimeSpan? keepAlive = null)
{
    private readonly Dictionary<ulong, BleEntry> _entries = [];
    private readonly TimeSpan _keepAlive = keepAlive ?? TimeSpan.FromSeconds(30);

    public IReadOnlyList<BleEntry> Snapshot() =>
        _entries.Values.OrderByDescending(entry => entry.Rssi).ToList();

    public int Count => _entries.Count;

    /// 返回 true 表示"值得刷新 UI"（新设备，或 RSSI 动了 ≥3 dBm）。
    /// 同一条广播 10 次只会更新 LastSeen，不会触发整表重绘——这就是列表不闪的关键。
    public bool Observe(ulong address, string name, short rssi, bool isHeartRate, DateTime now)
    {
        if (_entries.TryGetValue(address, out var existing))
        {
            var moved = Math.Abs(existing.Rssi - rssi) >= 3 || existing.Name != name;
            _entries[address] = existing with
            {
                Name = string.IsNullOrEmpty(name) ? existing.Name : name,
                Rssi = rssi,
                IsHeartRate = isHeartRate || existing.IsHeartRate,
                LastSeen = now,
            };
            return moved;
        }
        _entries[address] = new BleEntry(address, name, rssi, isHeartRate, now);
        return true;
    }

    public IReadOnlyList<BleEntry> Expire(DateTime now)
    {
        var stale = _entries.Values.Where(entry => now - entry.LastSeen > _keepAlive).ToList();
        foreach (var entry in stale) _entries.Remove(entry.Address);
        return stale;
    }
}

public enum BleConnectFailure
{
    Unreachable,
    AccessDenied,
    ProtocolError,
    AddressTypeMismatch,
    Unknown,
}

/// GATT 失败 → 用户能看懂的话（纯逻辑，单测覆盖）。
public static class BleErrors
{
    public static string Describe(BleConnectFailure failure) => failure switch
    {
        BleConnectFailure.Unreachable =>
            "设备不可达：通常是被手机 App 占用（心率带一般只能同时连一台），先在手机上断开",
        BleConnectFailure.AccessDenied =>
            "系统拒绝访问：先去 Windows 设置里配对一次，并确认蓝牙权限已开",
        BleConnectFailure.ProtocolError => "GATT 协议错误：设备可能不支持标准心率服务",
        BleConnectFailure.AddressTypeMismatch =>
            "地址类型不匹配：设备用的是随机地址，已自动重试仍失败",
        _ => "未知错误：重试一次，或换一支心率带验证",
    };

    public static BleConnectFailure FromStatus(int status) => status switch
    {
        0 => // Success
            BleConnectFailure.Unknown,
        1 => BleConnectFailure.Unreachable,
        2 => BleConnectFailure.ProtocolError,
        3 => BleConnectFailure.AccessDenied,
        4 => BleConnectFailure.AddressTypeMismatch,
        _ => BleConnectFailure.Unknown,
    };
}
