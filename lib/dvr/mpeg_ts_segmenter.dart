import 'dart:typed_data';

import 'dvr_models.dart';

class TsSegment {
  const TsSegment(this.bytes, this.duration, this.discontinuity);
  final Uint8List bytes;
  final Duration duration;
  final bool discontinuity;
}

/// Packet-aligned MPEG-TS segments with the latest complete PAT/PMT prepended.
/// PCR/PTS use the 33-bit 90kHz clock, including wrap. No independence tag is
/// advertised: streams without a signalled/detected keyframe can require decoder
/// preroll. The bounded fallback cuts at a PES start instead of splitting PES.
class MpegTsSegmenter {
  MpegTsSegmenter({
    this.targetDuration = const Duration(seconds: 4),
    this.maximumSegmentBytes = 32 * 1024 * 1024,
    this.copyInput = true,
  });

  final Duration targetDuration;
  final int maximumSegmentBytes;

  /// False only when the caller transfers ownership of immutable input chunks.
  final bool copyInput;
  static const packetSize = 188;
  static const _clockModulus = 1 << 33;

  Uint8List _remainder = Uint8List(0);
  final BytesBuilder _segment = BytesBuilder(copy: false);
  final Map<int, _PsiSection> _psi = {};
  List<Uint8List> _pat = [];
  List<Uint8List> _pmt = [];
  int? _pmtPid;
  int? _clockPid;
  int? _videoPid;
  int? _videoType;
  int? _audioPid;
  int? _previousClock;
  int _clock = 0;
  int _segmentClock = 0;
  bool _hasClock = false;
  bool _hasPcr = false;
  bool _discontinuity = false;
  int _skipped = 0;

  List<TsSegment> add(List<int> bytes) {
    final data = !copyInput && _remainder.isEmpty && bytes is Uint8List
        ? bytes
        : (Uint8List(_remainder.length + bytes.length)
            ..setRange(0, _remainder.length, _remainder)
            ..setRange(_remainder.length, _remainder.length + bytes.length, bytes));
    final result = <TsSegment>[];
    var offset = 0;
    while (offset + packetSize <= data.length) {
      if (data[offset] != 0x47 ||
          (offset + packetSize * 2 <= data.length &&
              data[offset + packetSize] != 0x47)) {
        offset++;
        if (++_skipped > packetSize * 64) {
          throw const DvrException(
            'This stream is not supported MPEG-TS media.',
          );
        }
        continue;
      }
      _skipped = 0;
      final packet = Uint8List.sublistView(data, offset, offset + packetSize);
      offset += packetSize;
      _packet(packet, result);
    }
    _remainder = Uint8List.fromList(Uint8List.sublistView(data, offset));
    return result;
  }

  TsSegment? finish() {
    if (_segment.length == 0 || !_hasClock) return null;
    return _flush(_clock - _segmentClock);
  }

  void _packet(Uint8List packet, List<TsSegment> result) {
    if ((packet[1] & 0x80) != 0) {
      _discontinuity = true;
      return;
    }
    if ((packet[3] & 0xc0) != 0) {
      throw const DvrException('Scrambled MPEG-TS cannot be recorded locally.');
    }
    final pid = ((packet[1] & 0x1f) << 8) | packet[2];
    final payloadStart = (packet[1] & 0x40) != 0;
    final control = (packet[3] >> 4) & 3;
    if (control == 0) return;
    var payload = 4;
    var randomAccess = false;
    if (control == 2 || control == 3) {
      final length = packet[4];
      payload = 5 + length;
      if (payload > packetSize) {
        throw const DvrException('The MPEG-TS adaptation field is corrupt.');
      }
      if (length > 0) {
        final flags = packet[5];
        randomAccess = (flags & 0x40) != 0;
        if ((flags & 0x80) != 0 && pid == _clockPid) {
          if (_segment.length > 0 && _hasClock && _clock > _segmentClock) {
            result.add(_flush(_clock - _segmentClock));
          }
          _previousClock = null;
          _discontinuity = true;
        }
        if (length >= 7 &&
            (flags & 0x10) != 0 &&
            (pid == _clockPid || _clockPid == null)) {
          final clock =
              packet[6] * 33554432 +
              packet[7] * 131072 +
              packet[8] * 512 +
              packet[9] * 2 +
              (packet[10] >> 7);
          if (!_hasPcr) _previousClock = null;
          _hasPcr = true;
          _advanceClock(clock);
        }
      }
    }
    if ((control == 1 || control == 3) && payload < packetSize) {
      if (pid == 0 || pid == _pmtPid) {
        final assembler = _psi.putIfAbsent(pid, _PsiSection.new);
        final section = assembler.add(packet, payload, payloadStart);
        if (section != null) {
          if (pid == 0) {
            _readPat(section);
            _pat = List.of(assembler.packets);
          } else {
            _readPmt(section);
            _pmt = List.of(assembler.packets);
          }
        }
      }
      if (payloadStart &&
          (pid == _videoPid || (_videoPid == null && pid == _audioPid))) {
        final pts = _pts(packet, payload);
        // PTS is also available on common direct TS feeds without PCR packets.
        if (pts != null && !_hasPcr) {
          _advanceClock(pts);
        }
      }
      final elapsed = _clock - _segmentClock;
      final isVideoStart = payloadStart && pid == _videoPid;
      final isAudioStart =
          payloadStart && _videoPid == null && pid == _audioPid;
      final keyframe =
          elapsed >= targetDuration.inMicroseconds * 90000 ~/ 1000000 &&
          isVideoStart &&
          (randomAccess || _containsKeyframe(packet, payload));
      if (_hasClock &&
          _segment.length > 0 &&
          _pat.isNotEmpty &&
          _pmt.isNotEmpty &&
          elapsed >= targetDuration.inMicroseconds * 90000 ~/ 1000000 &&
          ((isVideoStart && keyframe) ||
              isAudioStart ||
              (elapsed >= targetDuration.inMicroseconds * 180000 ~/ 1000000 &&
                  isVideoStart))) {
        result.add(_flush(elapsed));
      }
    }
    if (_segment.length == 0) {
      _segmentClock = _clock;
      for (final table in [..._pat, ..._pmt]) {
        _segment.add(table);
      }
    }
    _segment.add(packet);
    if (_segment.length > maximumSegmentBytes) {
      throw const DvrException(
        'The MPEG-TS stream has no usable segment boundaries within the storage limit.',
      );
    }
  }

  void _advanceClock(int raw) {
    final previous = _previousClock;
    _previousClock = raw;
    if (!_hasClock) {
      _hasClock = true;
      _clock = 0;
      _segmentClock = 0;
      return;
    }
    if (previous == null) return;
    var delta = raw - previous;
    if (delta < -_clockModulus ~/ 2) delta += _clockModulus;
    if (delta > _clockModulus ~/ 2) delta -= _clockModulus;
    if (delta < 0 || delta > 90000 * 30) {
      _discontinuity = true;
      return;
    }
    _clock += delta;
  }

  TsSegment _flush(int ticks) {
    final result = TsSegment(
      _segment.takeBytes(),
      Duration(microseconds: ((ticks > 0 ? ticks : 9000) * 1000000 ~/ 90000)),
      _discontinuity,
    );
    _segmentClock = _clock;
    _discontinuity = false;
    return result;
  }

  void _readPat(Uint8List section) {
    if (section.length < 12 || section[0] != 0 || (section[5] & 1) == 0) return;
    for (var i = 8; i + 4 <= section.length - 4; i += 4) {
      final programme = (section[i] << 8) | section[i + 1];
      if (programme != 0) {
        final next = ((section[i + 2] & 0x1f) << 8) | section[i + 3];
        if (_pmtPid != next) {
          _pmtPid = next;
          _pmt = [];
        }
        return;
      }
    }
  }

  void _readPmt(Uint8List section) {
    if (section.length < 16 || section[0] != 2 || (section[5] & 1) == 0) return;
    _clockPid = ((section[8] & 0x1f) << 8) | section[9];
    final infoLength = ((section[10] & 0xf) << 8) | section[11];
    int? videoPid;
    int? videoType;
    int? audioPid;
    for (var i = 12 + infoLength; i + 5 <= section.length - 4;) {
      final type = section[i];
      final elementaryPid = ((section[i + 1] & 0x1f) << 8) | section[i + 2];
      if ({1, 2, 0x10, 0x1b, 0x24, 0x42}.contains(type) && videoPid == null) {
        videoPid = elementaryPid;
        videoType = type;
      }
      if ({3, 4, 0xf, 0x11, 0x81, 0x87, 6}.contains(type)) {
        audioPid ??= elementaryPid;
      }
      i += 5 + ((section[i + 3] & 0xf) << 8) + section[i + 4];
    }
    _videoPid = videoPid;
    _videoType = videoType;
    _audioPid = audioPid;
  }

  bool _containsKeyframe(Uint8List packet, int offset) {
    for (var i = offset; i + 5 < packet.length; i++) {
      if (packet[i] != 0 || packet[i + 1] != 0 || packet[i + 2] != 1) continue;
      final nal = packet[i + 3];
      if (_videoType == 0x1b && (nal & 0x1f) == 5) return true;
      if (_videoType == 0x24 && {19, 20, 21}.contains((nal >> 1) & 0x3f)) {
        return true;
      }
      if ((_videoType == 1 || _videoType == 2) &&
          nal == 0 &&
          ((packet[i + 5] >> 3) & 7) == 1) {
        return true;
      }
    }
    return false;
  }

  int? _pts(Uint8List packet, int offset) {
    if (offset + 14 > packet.length ||
        packet[offset] != 0 ||
        packet[offset + 1] != 0 ||
        packet[offset + 2] != 1 ||
        (packet[offset + 7] & 0x80) == 0) {
      return null;
    }
    final p = offset + 9;
    return ((packet[p] >> 1) & 7) * 1073741824 +
        packet[p + 1] * 4194304 +
        ((packet[p + 2] >> 1) & 0x7f) * 32768 +
        packet[p + 3] * 128 +
        (packet[p + 4] >> 1);
  }
}

/// A PSI section may span multiple TS packets. Never reuse only its first packet.
class _PsiSection {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final List<Uint8List> packets = [];
  int? _expected;
  int? _continuity;
  bool _active = false;

  Uint8List? add(Uint8List packet, int payload, bool start) {
    final continuity = packet[3] & 0xf;
    if (start) {
      payload += 1 + packet[payload];
      _bytes.clear();
      packets.clear();
      _expected = null;
      _active = true;
    } else if (_continuity != null && continuity != (_continuity! + 1) % 16) {
      _active = false;
    }
    _continuity = continuity;
    if (!_active || payload >= packet.length) return null;
    // Tables outlive their media segment. Retain only these few packets, not
    // the entire transferred network chunk behind a packet view.
    packets.add(Uint8List.fromList(packet));
    _bytes.add(Uint8List.sublistView(packet, payload));
    final current = _bytes.toBytes();
    if (current.length >= 3) {
      _expected ??= 3 + ((current[1] & 0xf) << 8) + current[2];
    }
    if ((_expected ?? 0) > 4096) {
      _active = false;
      return null;
    }
    if (_expected != null && current.length >= _expected!) {
      _active = false;
      _bytes.clear();
      return Uint8List.sublistView(current, 0, _expected);
    }
    return null;
  }
}
