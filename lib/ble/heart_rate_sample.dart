import 'dart:typed_data';

final class HeartRateSample {
  const HeartRateSample({
    required this.bpm,
    required this.rrIntervalsMs,
    required this.sensorContact,
    required this.receivedAt,
  });

  final int bpm;
  final List<int> rrIntervalsMs;
  final bool? sensorContact;
  final DateTime receivedAt;
}

final class HrsFormatException implements FormatException {
  const HrsFormatException(this.message, [this.offset]);
  @override
  final String message;
  @override
  final int? offset;
  @override
  dynamic get source => null;
  @override
  String toString() => 'HrsFormatException: $message (offset: $offset)';
}

/// Bluetooth SIG Heart Rate Measurement 0x2A37 decoder.
final class HrsDecoder {
  const HrsDecoder();

  HeartRateSample decode(List<int> input, {DateTime? receivedAt}) {
    final bytes = input is Uint8List ? input : Uint8List.fromList(input);
    if (bytes.isEmpty) throw const HrsFormatException('Empty measurement');
    final flags = bytes[0];
    final wideBpm = flags & 0x01 != 0;
    final contactStatus = (flags >> 1) & 0x03;
    final energyPresent = flags & 0x08 != 0;
    final rrPresent = flags & 0x10 != 0;
    final reserved = flags & 0xe0;
    if (reserved != 0) {
      throw HrsFormatException('Reserved flag bits set: 0x${reserved.toRadixString(16)}');
    }
    var offset = 1;
    final int bpm;
    if (wideBpm) {
      _require(bytes, offset, 2);
      bpm = bytes[offset] | bytes[offset + 1] << 8;
      offset += 2;
    } else {
      _require(bytes, offset, 1);
      bpm = bytes[offset++];
    }
    final bool? contact;
    switch (contactStatus) {
      case 0 || 1:
        contact = null; // Sensor-contact detection is not supported.
      case 2:
        contact = false;
      case 3:
        contact = true;
      default:
        throw const HrsFormatException('Unreachable contact state');
    }
    if (energyPresent) {
      _require(bytes, offset, 2);
      offset += 2; // Energy Expended is intentionally not exposed yet.
    }
    final rr = <int>[];
    if (rrPresent) {
      while (offset < bytes.length) {
        _require(bytes, offset, 2);
        final raw = bytes[offset] | bytes[offset + 1] << 8;
        // One RR unit is 1/1024 second; rounded to milliseconds.
        rr.add((raw * 1000 / 1024).round());
        offset += 2;
      }
    }
    return HeartRateSample(
      bpm: bpm,
      rrIntervalsMs: List.unmodifiable(rr),
      sensorContact: contact,
      receivedAt: (receivedAt ?? DateTime.now()).toUtc(),
    );
  }


  void _require(Uint8List bytes, int offset, int count) {
    if (offset + count > bytes.length) {
      throw HrsFormatException('Truncated measurement', offset);
    }
  }
}
