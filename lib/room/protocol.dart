import '../core/config/app_config.dart';

enum RoomMessageType {
  hello,
  welcome,
  heartRate,
  snapshot,
  memberDelta,
  ping,
  pong,
  error,
}

final class HeartRateReport {
  const HeartRateReport({
    required this.memberId,
    required this.displayName,
    required this.bpm,
    required this.rrIntervalsMs,
    required this.sensorContact,
    required this.sequence,
    required this.measuredAt,
  });
  final String memberId;
  final String displayName;
  final int bpm;
  final List<int> rrIntervalsMs;
  final bool? sensorContact;
  final int sequence;
  final DateTime measuredAt;

  Map<String, Object?> toJson() => {
    'memberId': memberId,
    'displayName': displayName,
    'bpm': bpm,
    'rrMs': rrIntervalsMs,
    'sensorContact': sensorContact,
    'sequence': sequence,
    'measuredAt': measuredAt.toUtc().toIso8601String(),
  };
}

final class MemberState {
  const MemberState({
    required this.report,
    required this.lastSeen,
    required this.online,
  });
  final HeartRateReport report;
  final DateTime lastSeen;
  final bool online;

  MemberState copyWith({
    HeartRateReport? report,
    DateTime? lastSeen,
    bool? online,
  }) => MemberState(
    report: report ?? this.report,
    lastSeen: lastSeen ?? this.lastSeen,
    online: online ?? this.online,
  );

  Map<String, Object?> toJson() => {
    ...report.toJson(),
    'lastSeen': lastSeen.toUtc().toIso8601String(),
    'online': online,
  };
}

final class RoomEnvelope {
  const RoomEnvelope({required this.type, required this.data});
  final RoomMessageType type;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'v': AppConfig.protocolVersion,
    'type': type.name,
    ...data,
  };

  static RoomEnvelope fromJson(Map<String, Object?> json) {
    if (json['v'] != AppConfig.protocolVersion) {
      throw FormatException('Unsupported protocol version: ${json['v']}');
    }
    final type = RoomMessageType.values.asNameMap()[json['type']];
    if (type == null) {
      throw FormatException('Unknown message type: ${json['type']}');
    }
    return RoomEnvelope(type: type, data: json);
  }
}
