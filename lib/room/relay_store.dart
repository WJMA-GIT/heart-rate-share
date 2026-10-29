import 'dart:async';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'protocol.dart';

/// Relay-side source of truth. Call prune periodically (at least once/sec).
final class RelayStore {
  RelayStore({AppLogger? logger, DateTime Function()? clock})
      : _log = logger ?? AppLogger.instance,
        _clock = clock ?? (() => DateTime.now().toUtc());
  final AppLogger _log;
  final DateTime Function() _clock;
  final _members = <String, MemberState>{};
  final _changes = StreamController<List<MemberState>>.broadcast();

  Stream<List<MemberState>> get changes => _changes.stream;
  List<MemberState> get members {
    final result = _members.values.toList()
      ..sort((a, b) => a.report.displayName.compareTo(b.report.displayName));
    return List.unmodifiable(result);
  }

  MemberState? accept(HeartRateReport report) {
    final previous = _members[report.memberId];
    if (previous != null && report.sequence <= previous.report.sequence) return null;
    if (previous == null && _members.length >= AppConfig.maxMembers) {
      _log.warn('relay', 'Room full, member rejected', deviceId: report.memberId);
      throw StateError('ROOM_FULL');
    }
    final state = MemberState(report: report, lastSeen: _clock(), online: true);
    _members[report.memberId] = state;
    _changes.add(members);
    return state;
  }

  List<MemberState> prune() {
    final now = _clock();
    var changed = false;
    final expired = <String>[];
    for (final entry in _members.entries) {
      final age = now.difference(entry.value.lastSeen);
      if (age >= AppConfig.removeMemberAfter) {
        expired.add(entry.key);
      } else if (age >= AppConfig.offlineAfter && entry.value.online) {
        _members[entry.key] = entry.value.copyWith(online: false);
        changed = true;
      }
    }
    for (final id in expired) {
      _members.remove(id);
      changed = true;
    }
    if (changed) _changes.add(members);
    return members;
  }

  void remove(String memberId) {
    if (_members.remove(memberId) != null) _changes.add(members);
  }

  Future<void> dispose() => _changes.close();
}
