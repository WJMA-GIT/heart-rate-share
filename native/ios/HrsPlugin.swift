// iOS native HRS transport stub (Swift/CoreBluetooth).
//
// TODO(iOS): implement CBCentralManager scan/connect/service discovery and
// 0x2A37 notification forwarding, plus bluetooth-central state restoration.
// Deferred because background/restoration behavior and Info.plist entitlements
// require an Xcode target and physical iPhone validation; no fake success.

import CoreBluetooth
import Flutter

final class HrsPlugin: NSObject, FlutterPlugin {
    static let hrsService = CBUUID(string: "180D")
    static let hrsMeasurement = CBUUID(string: "2A37")

    static func register(with registrar: FlutterPluginRegistrar) {
        // Channels must match lib/ble/platform/hrs_channel.dart.
        // Intentionally no method handler until native lifecycle is implemented.
    }
}
