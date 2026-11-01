using System.Collections.ObjectModel;
using System.Windows.Threading;

namespace HeartRateShare.Desktop;

public sealed class Sample(DateTime at, int bpm)
{
    public DateTime At { get; } = at;
    public int Bpm { get; } = bpm;
}

/// 一个成员的实时曲线（最多 60 秒，1 Hz）。
public sealed class Member(string id, string name)
{
    private const int Capacity = 60;
    public string Id { get; } = id;
    public string Name { get; } = name;
    public bool Online { get; set; } = true;
    public ObservableCollection<Sample> Samples { get; } = [];
    public int? Bpm => Samples.Count == 0 ? null : Samples[^1].Bpm;

    public void Add(int bpm)
    {
        Samples.Add(new Sample(DateTime.Now, bpm));
        while (Samples.Count > Capacity) Samples.RemoveAt(0);
    }
}

/// 全局状态：数据源往里写，界面订阅。
public sealed class AppState
{
    public static AppState Current { get; } = new();

    public ObservableCollection<Member> Members { get; } = [];
    public string Transport { get; private set; } = "未连接";
    public event Action? Changed;

    private DispatcherTimer? _mockTimer;
    private readonly Random _random = new();

    public bool Connected => Members.Count > 0;

    public void Start()
    {
        if (!App.MockMode) return;
        // CI 截图/冒烟用：没有蓝牙也没有手机时给三行假数据。
        Members.Add(new Member("mock-1", "小明"));
        Members.Add(new Member("mock-2", "小红"));
        Members.Add(new Member("mock-3", "阿强"));
        Transport = "云端（演示）";
        _mockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _mockTimer.Tick += (_, _) =>
        {
            foreach (var member in Members)
            {
                member.Add(62 + _random.Next(0, 25));
            }
            Changed?.Invoke();
        };
        _mockTimer.Start();
    }

    public void Disconnect()
    {
        _mockTimer?.Stop();
        _mockTimer = null;
        Members.Clear();
        Transport = "未连接";
        Changed?.Invoke();
        OverlayRequested?.Invoke(false);
    }

    /// 悬浮窗显隐（由主窗口订阅）。
    public event Action<bool>? OverlayRequested;

    public void RequestOverlay(bool show) => OverlayRequested?.Invoke(show);
}
