import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Native channel contract shared by Windows C++/WinRT and iOS Swift stubs.
/// Events are JSON to keep the boundary inspectable; raw HRS bytes are a list
/// of unsigned octets, never base64 credentials or pairing material.
abstract final class HrsChannel {
  static const method = MethodChannel('com.wjmagit.heartrateshare/hrs/methods');
  static const events = EventChannel('com.wjmagit.heartrateshare/hrs/events');

  // Methods: adapterState, startScan({timeoutMs}), stopScan,
  // connect({deviceId}), disconnect({deviceId}).
  // Events: adapter, scanResult, connection, notification, error.
  static Map<String, Object?> scanResult(String id, String name, int rssi) => {
        'type': 'scanResult',
        'deviceId': id,
        'name': name,
        'rssi': rssi,
      };
  static Map<String, Object?> notification(String id, List<int> bytes) => {
        'type': 'notification',
        'deviceId': id,
        'bytes': bytes,
      };
  static String encode(Map<String, Object?> event) => jsonEncode(event);
}
