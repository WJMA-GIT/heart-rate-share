using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Threading;

namespace HeartRateShare.Desktop;

/// 全局状态：三条通路往这里写，界面只读。
public sealed class AppState
{
    public static AppState Current { get; } = new();

    public ObservableCollection<MemberRow> Members { get; } = [];
    public ObservableCollection<BleEntry> BleDevices { get; } = [];
    public ObservableCollection<Beacon> Peers { get; } = [];
    public Dictionary<string, List<int>> History { get; } = [];

    public string Transport { get; private set; } = "未连接";
    public string Status { get; private set; } = "";
    public string DisplayName { get; set; } = Environment.MachineName;
    public string RoomCode { get; private set; } = "";
    public string Server { get; set; } = Protocol.OfficialServer;
    public bool ShowAllBle { get; set; }
    public bool OverlayClickThrough { get; set; }
    public DateTime? LastSampleAt { get; private set; }
    public string? LastError { get; private set; }
    public string BleAdapterText { get; private set; } = "未扫描";

    public event Action? Changed;
    public event Action<bool>? OverlayRequested;

    private IHeartRateSource? _source;
    private LanSource? _lan;
    private BleSource? _ble;
    private DispatcherTimer? _mock;
    private readonly Random _random = new();

    public bool Connected => _source?.Connected == true || Members.Count > 0;

    public void Start()
    {
        Log($"app start mock={App.MockMode} version={typeof(AppState).Assembly.GetName().Version}");
        if (!App.MockMode) return;
        // CI 截图/冒烟：没有设备也要有数据（真实通路在下面，mock 只在 --mock 时启用）
        RoomCode = "MOCK01";
        Transport = "演示";
        var names = new[] { "小明", "小红", "阿强" };
        for (var i = 0; i < names.Length; i++)
        {
            Members.Add(new MemberRow($"mock-{i}", names[i], 0, true));
            History[$"mock-{i}"] = [];
        }
        _mock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _mock.Tick += (_, _) =>
        {
            for (var i = 0; i < Members.Count; i++)
            {
                var bpm = 62 + _random.Next(0, 25);
                Update(new MemberRow(Members[i].Id, Members[i].Name, bpm, true));
            }
            Changed?.Invoke();
        };
        _mock.Start();
        RequestOverlay(true);
    }

    public static string LogPath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "HeartRateShare", "logs");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "app.log");
        }
    }

    private const long MaxLogBytes = 1024 * 1024;   // 1 MB 轮转，留 3 份

    public static void Log(string message)
    {
        try
        {
            var path = LogPath;
            var info = new FileInfo(path);
            if (info.Exists && info.Length > MaxLogBytes)
            {
                File.Move(path + ".1", path + ".2", true);
                File.Move(path, path + ".1", true);
            }
            File.AppendAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}");
        }
        catch (IOException)
        {
            // 日志写不进去不能影响使用
        }
    }

    // ---------------------------------------------------------------- 蓝牙

    public void ScanBle()
    {
        _ble ??= CreateBle();
        _ble.StartScan();
        Status = "扫描中…";
        Changed?.Invoke();
    }

    private BleSource CreateBle()
    {
        var ble = new BleSource();
        ble.Diagnostic += text => UiDispatch.Post(() => Log(text));
        ble.DevicesChanged += () => UiDispatch.Post(() => SyncDevices(ble.Devices));
        ble.MembersChanged += rows => UiDispatch.Post(() => Adopt(ble, "蓝牙", rows));
        ble.Status += text => UiDispatch.Post(() => { Status = text; Changed?.Invoke(); });
        ble.Failed += text => UiDispatch.Post(() => Fail(text));
        return ble;
    }

    public async Task ConnectBleAsync(BleDevice device)
    {
        _ble ??= CreateBle();
        await SwitchTo(_ble);
        await _ble.ConnectAsync(device.Address, DisplayName);
    }

    // ---------------------------------------------------------------- 局域网

    public void StartLanDiscovery()
    {
        _lan ??= CreateLan();
        _lan.StartDiscovery();
        Status = "正在发现手机…";
        Changed?.Invoke();
    }

    private LanSource CreateLan()
    {
        var lan = new LanSource();
        lan.PeersChanged += () => UiDispatch.Post(() => SyncPeers(lan.Peers));
        lan.MembersChanged += rows => UiDispatch.Post(() => Adopt(lan, "局域网", rows));
        lan.Status += text => UiDispatch.Post(() => { Status = text; Changed?.Invoke(); });
        lan.Failed += text => UiDispatch.Post(() => Fail(text));
        return lan;
    }

    public async Task ConnectPeerAsync(Beacon peer)
    {
        _lan ??= CreateLan();
        await SwitchTo(_lan);
        // 手机侧的局域网服务不校验房间号：不带 ?room=，只连 ws://ip:8770/ws
        Log($"lan connect {peer.Host}:{peer.Port} (no room param)");
        await _lan.ConnectAsync(peer, DisplayName);
    }

    public async Task ConnectManualAsync(string hostPort)
    {
        _lan ??= CreateLan();
        await SwitchTo(_lan);
        await _lan.ConnectManualAsync(hostPort, DisplayName);
    }

    // ---------------------------------------------------------------- 云端

    private CloudSource? _cloud;

    public async Task ConnectCloudAsync(string room)
    {
        var code = Protocol.IsValidRoomCode(room) ? room.Trim() : Protocol.GenerateRoomCode();
        if (!CloudSource.TryParseServer(Server, out _, out _, out _, out var reason))
        {
            Fail(reason);
            return;
        }
        _cloud ??= CreateCloud();
        await SwitchTo(_cloud);
        RoomCode = code;
        Log($"cloud connect {Server} room={code}");
        await _cloud.ConnectAsync(Server, code, DisplayName);
    }

    private CloudSource CreateCloud()
    {
        var cloud = new CloudSource();
        cloud.MembersChanged += rows => UiDispatch.Post(() => Adopt(cloud, "云端", rows));
        cloud.Status += text => UiDispatch.Post(() => { Status = text; Changed?.Invoke(); });
        cloud.Failed += text => UiDispatch.Post(() => Fail(text));
        return cloud;
    }

    private async Task SwitchTo(IHeartRateSource source)
    {
        if (!ReferenceEquals(_source, source))
        {
            if (_source is not null) await _source.DisconnectAsync();
            _source = source;
        }
        Members.Clear();
        History.Clear();
    }

    private void Adopt(IHeartRateSource source, string transport, IReadOnlyList<MemberRow> rows)
    {
        _source = source;
        Transport = transport;
        Members.Clear();
        foreach (var row in rows) Members.Add(row);
        if (rows.Count > 0) LastSampleAt = DateTime.Now;
        foreach (var row in rows)
        {
            if (!History.TryGetValue(row.Id, out var values))
            {
                values = [];
                History[row.Id] = values;
            }
            values.Add(row.Bpm);
            while (values.Count > 60) values.RemoveAt(0);
        }
        foreach (var stale in History.Keys.Where(key => rows.All(row => row.Id != key)).ToList())
        {
            History.Remove(stale);
        }
        LastError = null;
        Status = rows.Count == 0 ? "已连接，等待成员数据…" : $"已连接 {rows.Count} 人";
        if (rows.Count > 0) RequestOverlay(true);
        Changed?.Invoke();
    }

    private void Update(MemberRow row)
    {
        if (!History.TryGetValue(row.Id, out var values))
        {
            values = [];
            History[row.Id] = values;
        }
        values.Add(row.Bpm);
        while (values.Count > 60) values.RemoveAt(0);
        var index = Members.ToList().FindIndex(member => member.Id == row.Id);
        if (index >= 0) Members[index] = row; else Members.Add(row);
    }

    /// 蓝牙列表增量更新：只加/删/改，不 Clear（避免 UI 闪一下并且保住选中态）。
    /// 只增删，不替换（BleEntry 自己是 INotifyPropertyChanged，属性更新会通知 UI）。
    private void SyncDevices(IReadOnlyList<BleEntry> devices)
    {
        var wanted = devices.Where(entry => ShowAllBle || entry.IsHeartRate).ToList();
        for (var i = BleDevices.Count - 1; i >= 0; i--)
        {
            if (wanted.All(entry => entry.Address != BleDevices[i].Address)) BleDevices.RemoveAt(i);
        }
        foreach (var entry in wanted)
        {
            if (BleDevices.All(existing => existing.Address != entry.Address)) BleDevices.Add(entry);
        }
        Changed?.Invoke();
    }

    private void SyncPeers(IReadOnlyList<Beacon> peers)
    {
        for (var i = Peers.Count - 1; i >= 0; i--)
        {
            if (peers.All(peer => peer.Host != Peers[i].Host || peer.Port != Peers[i].Port))
                Peers.RemoveAt(i);
        }
        foreach (var peer in peers)
        {
            var index = Peers.ToList().FindIndex(existing => existing.Host == peer.Host && existing.Port == peer.Port);
            if (index >= 0) Peers[index] = peer; else Peers.Add(peer);
        }
        Changed?.Invoke();
    }

    /// 改名：立刻改自身成员行，并（已连云端/局域网时）重新发 hello 广播新名字。
    public async Task RenameSelfAsync(string name)
    {
        var trimmed = (name ?? string.Empty).Trim();
        if (trimmed.Length == 0) trimmed = Environment.MachineName;
        DisplayName = trimmed;
        UiDispatch.Post(() =>
        {
            for (var i = 0; i < Members.Count; i++)
            {
                if (Members[i].Id == "ble-own" || Members[i].Id.StartsWith("win-", StringComparison.Ordinal))
                {
                    Members[i] = Members[i] with { Name = trimmed };
                }
            }
            Changed?.Invoke();
        });
        switch (_source)
        {
            case LanSource lan: await lan.ResendHelloAsync(trimmed); break;
            case CloudSource cloud: await cloud.ResendHelloAsync(trimmed); break;
        }
        Log($"name -> {trimmed}");
    }

    /// 蓝牙自己那一路也用用户设置的名字（别再硬编码"蓝牙设备"）。
    public string SelfName => DisplayName;

    /// 蓝牙适配器状态文案（诊断区块显示用）。
    public void NoteBleAdapter(string text) => UiDispatch.Post(() =>
    {
        BleAdapterText = text;
        Changed?.Invoke();
    });

    private void Fail(string message)
    {
        Status = message;
        LastError = message;
        Log($"error: {message}");
        Changed?.Invoke();
    }

    /// 诊断区块用：一眼能看出版本、通路、设备数、最后一次采样、错误分类。
    public string Diagnostics()
    {
        var last = LastSampleAt is null ? "无" : LastSampleAt.Value.ToString("HH:mm:ss");
        return string.Join(Environment.NewLine,
            $"版本：{typeof(AppState).Assembly.GetName().Version}",
            $"构建：1.0.15 (PC/WPF)",
            $"通路：{Transport}",
            $"状态：{Status}",
            $"蓝牙：{BleAdapterText}，已发现 {BleDevices.Count} 台",
            $"局域网：{Peers.Count} 台手机",
            $"成员：{Members.Count} 人",
            $"最近采样：{last}",
            $"最近错误：{LastError ?? "无"}",
            $"日志：{LogPath}");
    }

    public async void Disconnect()
    {
        _mock?.Stop();
        _mock = null;
        if (_source is not null) await _source.DisconnectAsync();
        _source = null;
        // await 之后可能已经不在 UI 线程：集合清理同样要 Post 回去
        UiDispatch.Post(() =>
        {
            Members.Clear();
            History.Clear();
            Transport = "未连接";
            Status = "已断开";
            RequestOverlay(false);
            Changed?.Invoke();
        });
    }

    public void RequestOverlay(bool show) => OverlayRequested?.Invoke(show);
}
