// Windows native HRS transport stub (C++/WinRT).
//
// TODO(Windows): implement Flutter MethodChannel/EventChannel registration and
// BluetoothLEDevice -> GATT 0x180D -> 0x2A37 notification forwarding. It is not
// implemented now because packaged-desktop channel setup, adapter permissions,
// and notification lifetime require CI compilation and real adapter testing.
// Do not return fake scan results or a successful connection from this stub.

#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>

namespace heartrate::windows {
constexpr wchar_t kHrsService[] = L"0000180d-0000-1000-8000-00805f9b34fb";
constexpr wchar_t kHrsMeasurement[] = L"00002a37-0000-1000-8000-00805f9b34fb";

// Channel: com.wjmagit.heartrateshare/hrs/methods and /events.
// Methods: adapterState, startScan, stopScan, connect, disconnect.
// Events: adapter, scanResult, connection, notification, error.
// Event JSON contract: lib/ble/platform/hrs_channel.dart.
} // namespace heartrate::windows
