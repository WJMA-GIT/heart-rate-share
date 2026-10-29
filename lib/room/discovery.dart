import 'dart:async';

import '../core/logging/app_logger.dart';

final class DiscoveredRoom {
  const DiscoveredRoom({required this.name, required this.addresses});
  final String name;
  final List<Uri> addresses;
}

abstract interface class RoomDiscovery {
  Stream<List<DiscoveredRoom>> get rooms;
  Future<void> start();
  Future<void> stop();
}

/// mDNS boundary. Plugin implementations differ in Android NSD/iOS Bonjour and
/// desktop socket support, so no fake discovered room is emitted here.
final class UnimplementedRoomDiscovery implements RoomDiscovery {
  UnimplementedRoomDiscovery({AppLogger? logger})
      : _log = logger ?? AppLogger.instance;
  final AppLogger _log;
  final _rooms = StreamController<List<DiscoveredRoom>>.broadcast();
  @override
  Stream<List<DiscoveredRoom>> get rooms => _rooms.stream;
  @override
  Future<void> start() async {
    // TODO(Android/iOS): wire nsd registration and discovery after validating
    // its current API in CI; Windows needs native mDNS because plugin support
    // is not guaranteed. Manual ws://host:port remains functional meanwhile.
    _log.warn('discovery', 'mDNS is not wired; use manual relay address');
  }

  @override
  Future<void> stop() async {}
  Future<void> dispose() => _rooms.close();
}
