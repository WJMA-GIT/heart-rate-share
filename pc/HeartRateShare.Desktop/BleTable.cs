namespace HeartRateShare.Desktop;

/// 可通知的蓝牙设备项：属性原地更新（不替换列表项），WPF 才不会重建行 → 不闪。
public sealed class BleEntry : System.ComponentModel.INotifyPropertyChanged
{
    private string _name;
    private short _rssi;

    public BleEntry(ulong address, string name, short rssi, bool isHeartRate)
    {
        Address = address;
        _name = name;
        _rssi = rssi;
        IsHeartRate = isHeartRate;
        LastSeen = DateTime.UtcNow;
        LastRssiPush = DateTime.MinValue;
    }

    public ulong Address { get; }
    public bool IsHeartRate { get; private set; }
    public DateTime LastSeen { get; set; }
    public DateTime LastRssiPush { get; set; }

    public string Name
    {
        get => _name;
        set
        {
            if (_name == value) return;
            _name = value;
            Changed(nameof(Name));
        }
    }

    public short Rssi
    {
        get => _rssi;
        set
        {
            if (_rssi == value) return;
            _rssi = value;
            Changed(nameof(Rssi));
        }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

    private void Changed(string property) =>
        PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(property));

    public override string ToString() => $"0x{Address:X} {Name} {Rssi}dBm";
}

/// 蓝牙设备表（纯逻辑，可单测）。
public sealed class BleDeviceTable(TimeSpan? keepAlive = null, TimeSpan? rssiInterval = null)
{
    private readonly Dictionary<ulong, BleEntry> _entries = [];
    private readonly TimeSpan _keepAlive = keepAlive ?? TimeSpan.FromSeconds(30);
    private readonly TimeSpan _rssiInterval = rssiInterval ?? TimeSpan.FromMilliseconds(500);

    public int Count => _entries.Count;

    public IReadOnlyList<BleEntry> Snapshot() =>
        _entries.Values.OrderByDescending(entry => entry.Rssi).ToList();

    public BleEntry? Find(ulong address) => _entries.GetValueOrDefault(address);

    /// 同地址只更新同一个对象；名字只接受"更长且非空"的版本（广播分片会把全名冲成半截）；
    /// RSSI 最多每 500ms 推一次（避免高频刷新导致列表跳动）。
    public bool Observe(ulong address, string name, short rssi, bool isHeartRate, DateTime now)
    {
        if (!_entries.TryGetValue(address, out var entry))
        {
            _entries[address] = new BleEntry(address, name, rssi, isHeartRate)
            {
                LastSeen = now,
                LastRssiPush = now,
            };
            return true;   // 新设备：需要 UI 插入一行
        }

        entry.LastSeen = now;
        entry.IsHeartRate |= isHeartRate;
        var nameChanged = false;
        if (!string.IsNullOrEmpty(name) && name.Length > entry.Name.Length)
        {
            entry.Name = name;
            nameChanged = true;
        }
        var rssiChanged = false;
        if (now - entry.LastRssiPush >= _rssiInterval && entry.Rssi != rssi)
        {
            entry.Rssi = rssi;
            entry.LastRssiPush = now;
            rssiChanged = true;
        }
        return nameChanged || rssiChanged;
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
        1 => BleConnectFailure.Unreachable,
        2 => BleConnectFailure.ProtocolError,
        3 => BleConnectFailure.AccessDenied,
        4 => BleConnectFailure.AddressTypeMismatch,
        _ => BleConnectFailure.Unknown,
    };
}
