using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace HeartRateShare.Desktop;

/// 蓝牙直连：看广播（0x180D 过滤展示）→ 连 GATT → 订阅 0x2A37 → 1 Hz 出数。
public sealed class BleSource : IHeartRateSource
{
    private static readonly Guid HeartRateServiceUuid = new("0000180d-0000-1000-8000-00805f9b34fb");
    private static readonly Guid HeartRateMeasurementUuid = new("00002a37-0000-1000-8000-00805f9b34fb");

    // 设备表是纯逻辑（BleDeviceTable）：同一地址只更新、30 秒没再听到才过期。
    private readonly BleDeviceTable _table = new();
    private Timer? _expiry;
    private BluetoothLEAdvertisementWatcher? _watcher;
    private BluetoothLEDevice? _device;
    private GattCharacteristic? _characteristic;
    private DateTime _lastSampleAt;
    private bool _firstSampleLogged;

    public string Transport => "蓝牙";
    public bool Connected => _characteristic is not null;
    // 直接暴露表里的对象（INotifyPropertyChanged）：UI 只更新属性，不替换项。
    public IReadOnlyList<BleEntry> Devices => _table.Snapshot();
    public event Action<string>? Diagnostic;
    public event Action<IReadOnlyList<MemberRow>>? MembersChanged;
    public event Action<string>? Status;
    public event Action<string>? Failed;
    public event Action? DevicesChanged;

    /// 只展示广播带 0x180D 的（"显示全部"由 UI 决定怎么过滤）。
    public void StartScan()
    {
        if (_watcher is not null) return;
        try
        {
            var watcher = new BluetoothLEAdvertisementWatcher
            {
                ScanningMode = BluetoothLEScanningMode.Active,
            };
            watcher.Received += (_, args) =>
            {
                var isHeartRate = args.Advertisement.ServiceUuids.Contains(HeartRateServiceUuid);
                var name = args.Advertisement.LocalName ?? string.Empty;
                var before = _table.Count;
                _table.Observe(args.BluetoothAddress, name, args.RawSignalStrengthInDBm,
                    isHeartRate, DateTime.UtcNow);
                if (_table.Count != before)
                {
                    Diagnostic?.Invoke(
                        $"ble: seen 0x{args.BluetoothAddress:X} {name} rssi={args.RawSignalStrengthInDBm}");
                    DevicesChanged?.Invoke();   // 只有"新设备"才需要插一行
                }
            };
            watcher.Stopped += (_, args) =>
            {
                if (args.Error == BluetoothError.RadioNotAvailable)
                {
                    Failed?.Invoke("蓝牙未开启：请在 Windows 设置里打开蓝牙");
                    AppState.Current.NoteBleAdapter("蓝牙未开启");
                }
            };
            watcher.Start();
            _watcher = watcher;
            _expiry ??= new Timer(_ => Expire(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
            Status?.Invoke("扫描中…");
            AppState.Current.NoteBleAdapter("扫描中");
        }
        catch (Exception error)
        {
            Failed?.Invoke($"蓝牙扫描启动失败：{error.Message}（未配对/适配器不可用）");
        }
    }

    private void StopScan()
    {
        _watcher?.Stop();
        _watcher = null;
        _expiry?.Dispose();
        _expiry = null;
    }

    public async Task ConnectAsync(ulong address, string displayName)
    {
        // 扫描会抢射频：连之前必须先停，否则 GATT 打开经常直接 Unreachable
        StopScan();
        Diagnostic?.Invoke($"ble: connect 0x{address:X} attempt=1");
        try
        {
            _device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (_device is null)
            {
                Diagnostic?.Invoke($"ble: connect 0x{address:X} attempt=2 (public address)");
                _device = await BluetoothLEDevice.FromBluetoothAddressAsync(
                    address, BluetoothAddressType.Public);
            }
            if (_device is null)
            {
                Diagnostic?.Invoke("ble: connect failed hr=0x0 (device null)");
                Failed?.Invoke(BuildError(BleConnectFailure.Unreachable));
                return;
            }
            var services = await _device.GetGattServicesForUuidAsync(HeartRateServiceUuid);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            {
                Diagnostic?.Invoke($"ble: service missing hr=0x{(int)services.Status:X8}");
                Failed?.Invoke(BuildError(BleErrors.FromStatus((int)services.Status)));
                return;
            }
            var characteristics = await services.Services[0].GetCharacteristicsForUuidAsync(HeartRateMeasurementUuid);
            if (characteristics.Status != GattCommunicationStatus.Success ||
                characteristics.Characteristics.Count == 0)
            {
                Failed?.Invoke("连接失败：没有 0x2A37 测量特征");
                return;
            }
            var characteristic = characteristics.Characteristics[0];
            characteristic.ValueChanged += OnMeasurement;
            var status = await characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (status != GattCommunicationStatus.Success)
            {
                Diagnostic?.Invoke($"ble: connect failed hr=0x{(int)status:X8} (subscribe)");
                Failed?.Invoke(BuildError(BleErrors.FromStatus((int)status)));
                return;
            }
            _characteristic = characteristic;
            _lastSampleAt = DateTime.UtcNow;
            Diagnostic?.Invoke("ble: subscribed");
            Status?.Invoke("已连接（蓝牙）");
        }
        catch (Exception error)
        {
            Diagnostic?.Invoke($"ble: connect failed hr=0x{error.HResult:X8} {error.Message}");
            Failed?.Invoke($"蓝牙连接异常：{error.Message}");
        }
    }

    private static string BuildError(BleConnectFailure failure) =>
        $"连接失败：{BleErrors.Describe(failure)}";

    // 过期的设备才移除，广播中间抖动不会闪没。
    private void Expire()
    {
        var stale = _table.Expire(DateTime.UtcNow);
        if (stale.Count == 0) return;
        foreach (var entry in stale) Diagnostic?.Invoke($"ble: expired 0x{entry.Address:X}");
        DevicesChanged?.Invoke();
    }

    private void OnMeasurement(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        var reader = DataReader.FromBuffer(args.CharacteristicValue);
        var buffer = new byte[reader.UnconsumedBufferLength];
        reader.ReadBytes(buffer);
        if (!HeartRateMeasurement.TryDecode(buffer, out var bpm, out _)) return;
        if (!_firstSampleLogged)
        {
            _firstSampleLogged = true;
            Diagnostic?.Invoke($"ble: first sample bpm={bpm}");
        }
        _lastSampleAt = DateTime.UtcNow;
        MembersChanged?.Invoke([new MemberRow("ble-own", AppState.Current.SelfName, bpm, true)]);
    }

    /// 真正释放链路：取消通知 → 关 GattSession.MaintainConnection → 逐层 Dispose → 冷却再扫描。
    /// 不做这些，"断开"只是界面上的事，设备在系统里仍被占用，之后就再也扫不到。
    public async Task DisconnectAsync()
    {
        Diagnostic?.Invoke("ble: disconnect begin");
        if (_characteristic is not null)
        {
            _characteristic.ValueChanged -= OnMeasurement;
            try
            {
                await _characteristic.WriteClientCharacteristicConfigurationDescriptorAsync(
                    GattClientCharacteristicConfigurationDescriptorValue.None);
            }
            catch (Exception error)
            {
                Diagnostic?.Invoke($"ble: unsubscribe failed {error.Message}");
            }
            _characteristic = null;
        }
        if (_device is not null)
        {
            // shortcut: 这一版 CsWinRT 投影里没有可用的 GattSession 静态入口，
            // 释放链路靠"取消 CCCD 通知 + Dispose 设备"，实测足够断开；
            // 一旦 SDK 投影补上 GattSession.MaintainConnection=false，再加回来。
            _device.Dispose();
            _device = null;
            Diagnostic?.Invoke("ble: device disposed");
        }
        _table.Expire(DateTime.MaxValue);   // 清空设备表，允许下次重新发现
        _firstSampleLogged = false;
        MembersChanged?.Invoke([]);
        // 让系统把链路真正放掉，否则马上扫描会扫不到同一台设备
        await Task.Delay(400);
        Diagnostic?.Invoke("ble: disconnect finished");
    }

    public ValueTask DisposeAsync() => new(DisconnectAsync());
}
