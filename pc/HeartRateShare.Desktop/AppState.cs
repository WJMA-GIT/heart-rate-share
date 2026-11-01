using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Threading;

namespace HeartRateShare.Desktop;

/// 全局状态：三条通路往这里写，界面只读。
public sealed class AppState
{
    public static AppState Current { get; } = new();

    public ObservableCollection<MemberRow> Members { get; } = [];
    public ObservableCollection<BleDevice> BleDevices { get; } = [];
    public ObservableCollection<Beacon> Peers { get; } = [];
    public Dictionary<string, List<int>> History { get; } = [];

    public string Transport { get; private set; } = "未连接";
    public string Status { get; private set; } = "";
    public string DisplayName { get; set; } = "Windows";
    public string RoomCode { get; private set; } = "";
    public string Server { get; set; } = Protocol.OfficialServer;
    public bool ShowAllBle { get; set; }

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

    public static void Log(string message)
    {
        try
        {
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}{Environment.NewLine}");
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
        ble.DevicesChanged += () =>
        {
            BleDevices.Clear();
            foreach (var device in ble.Devices)
            {
                if (ShowAllBle || device.IsHeartRate) BleDevices.Add(device);
            }
            Changed?.Invoke();
        };
        ble.MembersChanged += rows => Adopt(ble, "蓝牙", rows);
        ble.Status += text => { Status = text; Changed?.Invoke(); };
        ble.Failed += Fail;
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
        lan.PeersChanged += () =>
        {
            Peers.Clear();
            foreach (var peer in lan.Peers) Peers.Add(peer);
            Changed?.Invoke();
        };
        lan.MembersChanged += rows => Adopt(lan, "局域网", rows);
        lan.Status += text => { Status = text; Changed?.Invoke(); };
        lan.Failed += Fail;
        return lan;
    }

    public async Task ConnectPeerAsync(Beacon peer)
    {
        _lan ??= CreateLan();
        await SwitchTo(_lan);
        RoomCode = peer.Room;
        Log($"lan connect {peer.Host}:{peer.Port} room={peer.Room}");
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
        cloud.MembersChanged += rows => Adopt(cloud, "云端", rows);
        cloud.Status += text => { Status = text; Changed?.Invoke(); };
        cloud.Failed += Fail;
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

    private void Fail(string message)
    {
        Status = message;
        Log($"error: {message}");
        Changed?.Invoke();
    }

    public async void Disconnect()
    {
        _mock?.Stop();
        _mock = null;
        if (_source is not null) await _source.DisconnectAsync();
        _source = null;
        Members.Clear();
        History.Clear();
        Transport = "未连接";
        Status = "已断开";
        RequestOverlay(false);
        Changed?.Invoke();
    }

    public void RequestOverlay(bool show) => OverlayRequested?.Invoke(show);
}
