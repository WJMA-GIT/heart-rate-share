using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace HeartRateShare.Desktop;

public sealed record BleDevice(ulong Address, string Name, short Rssi, bool IsHeartRate);

/// 蓝牙直连：看广播（0x180D 过滤展示）→ 连 GATT → 订阅 0x2A37 → 1 Hz 出数。
public sealed class BleSource : IHeartRateSource
{
    private static readonly Guid HeartRateServiceUuid = new("0000180d-0000-1000-8000-00805f9b34fb");
    private static readonly Guid HeartRateMeasurementUuid = new("00002a37-0000-1000-8000-00805f9b34fb");

    private readonly Dictionary<ulong, BleDevice> _devices = [];
    private BluetoothLEAdvertisementWatcher? _watcher;
    private BluetoothLEDevice? _device;
    private GattCharacteristic? _characteristic;
    private DateTime _lastSampleAt;

    public string Transport => "蓝牙";
    public bool Connected => _characteristic is not null;
    public IReadOnlyList<BleDevice> Devices => _devices.Values.OrderByDescending(d => d.Rssi).ToList();
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
                _devices[args.BluetoothAddress] = new BleDevice(
                    args.BluetoothAddress, name, args.RawSignalStrengthInDBm, isHeartRate);
                DevicesChanged?.Invoke();
            };
            watcher.Stopped += (_, args) =>
            {
                if (args.Error == BluetoothError.RadioNotAvailable)
                    Failed?.Invoke("蓝牙未开启：请在 Windows 设置里打开蓝牙");
            };
            watcher.Start();
            _watcher = watcher;
            Status?.Invoke("扫描中…");
        }
        catch (Exception error)
        {
            Failed?.Invoke($"蓝牙扫描启动失败：{error.Message}（未配对/适配器不可用）");
        }
    }

    public async Task ConnectAsync(ulong address, string displayName)
    {
        try
        {
            _device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (_device is null)
            {
                Failed?.Invoke("连接失败：设备不在范围内");
                return;
            }
            var services = await _device.GetGattServicesForUuidAsync(HeartRateServiceUuid);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            {
                Failed?.Invoke("连接失败：设备没有心率服务（可能被手机占用）");
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
                Failed?.Invoke($"订阅心率失败：{status}（设备可能已被占用）");
                return;
            }
            _characteristic = characteristic;
            _lastSampleAt = DateTime.UtcNow;
            Status?.Invoke("已连接（蓝牙）");
        }
        catch (Exception error)
        {
            Failed?.Invoke($"蓝牙连接异常：{error.Message}");
        }
    }

    private void OnMeasurement(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        var reader = DataReader.FromBuffer(args.CharacteristicValue);
        var buffer = new byte[reader.UnconsumedBufferLength];
        reader.ReadBytes(buffer);
        if (!HeartRateMeasurement.TryDecode(buffer, out var bpm, out _)) return;
        _lastSampleAt = DateTime.UtcNow;
        MembersChanged?.Invoke([new MemberRow("ble-own", "蓝牙设备", bpm, true)]);
    }

    public async Task DisconnectAsync()
    {
        _watcher?.Stop();
        _watcher = null;
        if (_characteristic is not null)
        {
            _characteristic.ValueChanged -= OnMeasurement;
            _characteristic = null;
        }
        _device?.Dispose();
        _device = null;
        MembersChanged?.Invoke([]);
        await Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => new(DisconnectAsync());
}
