import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_models.dart';
import 'package:iptvs/dvr/mpeg_ts_segmenter.dart';
import 'package:iptvs/dvr/ts_segment_worker.dart';

void main() {
  test(
    'PCR wrap retains positive durations and every segment starts at a PES',
    () {
      final segmenter = MpegTsSegmenter(
        targetDuration: const Duration(seconds: 2),
      );
      final packets = <List<int>>[_pat(), ..._pmt()];
      const modulus = 1 << 33;
      for (var second = 0; second <= 8; second++) {
        packets.add(_video((modulus - 180000 + second * 90000) % modulus));
      }
      final segments = segmenter.add(packets.expand((p) => p).toList());
      final tail = segmenter.finish();
      if (tail != null) segments.add(tail);
      expect(segments.length, greaterThanOrEqualTo(4));
      for (final segment in segments) {
        expect(segment.duration, greaterThan(Duration.zero));
        expect(segment.duration, lessThanOrEqualTo(const Duration(seconds: 2)));
        expect(segment.bytes.length % 188, 0);
        expect(segment.bytes[1] & 0x40, 0x40); // PAT PUSI
        final video = _videoPackets(segment.bytes).first;
        expect(video[1] & 0x40, 0x40);
      }
    },
  );

  test('PTS fallback continues even though PMT declares a PCR PID', () {
    final segmenter = MpegTsSegmenter(
      targetDuration: const Duration(seconds: 2),
    );
    final packets = <List<int>>[_pat(), ..._pmt()];
    for (var second = 0; second <= 8; second++) {
      packets.add(_video(second * 90000, withPcr: false));
    }
    final segments = segmenter.add(packets.expand((p) => p).toList());
    expect(segments.length, 4);
    expect(
      segments.map((s) => s.duration),
      everyElement(const Duration(seconds: 2)),
    );
  });

  test(
    'prepends all packets of a multi-packet PMT, never just its first packet',
    () {
      final segmenter = MpegTsSegmenter(
        targetDuration: const Duration(seconds: 2),
      );
      final pmt = _pmt(descriptorLength: 180);
      expect(pmt.length, 2);
      final packets = <List<int>>[_pat(), ...pmt];
      for (var second = 0; second <= 6; second++) {
        packets.add(_video(second * 90000));
      }
      final segments = segmenter.add(packets.expand((p) => p).toList());
      expect(segments.length, 3);
      for (final segment in segments.skip(1)) {
        final pmtPackets = _packets(segment.bytes)
            .where((p) => _pid(p) == 100)
            .toList();
        expect(pmtPackets.length, 2);
        expect(pmtPackets[0][1] & 0x40, 0x40);
        expect(pmtPackets[1][1] & 0x40, 0);
      }
    },
  );

  test('a detected IDR inside a PES never creates a segment in that PES', () {
    final segmenter = MpegTsSegmenter(
      targetDuration: const Duration(seconds: 2),
    );
    final packets = <List<int>>[_pat(), ..._pmt(), _video(0)];
    packets.add(_video(180000, start: false));
    packets.add(_video(270000));
    packets.add(_video(450000));
    final segments = segmenter.add(packets.expand((p) => p).toList());
    expect(segments.first.duration, const Duration(seconds: 3));
    expect(_videoPackets(segments[1].bytes).first[1] & 0x40, 0x40);
  });

  test(
    'clock discontinuity closes the old segment before the reset packet',
    () {
      final segmenter = MpegTsSegmenter(
        targetDuration: const Duration(seconds: 4),
      );
      final packets = <List<int>>[
        _pat(),
        ..._pmt(),
        _video(900000),
        _video(990000),
        _video(0, discontinuity: true),
        _video(90000),
        _video(180000),
      ];
      final segments = segmenter.add(packets.expand((p) => p).toList());
      final tail = segmenter.finish()!;
      expect(segments, hasLength(1));
      expect(segments.first.discontinuity, isFalse);
      expect(tail.discontinuity, isTrue);
      expect(tail.duration, const Duration(seconds: 2));
    },
  );

  test(
    'rejects scrambled transport without writing misleading replay media',
    () {
      final packet = _video(0)..[3] |= 0x80;
      expect(() => MpegTsSegmenter().add(packet), throwsA(isA<DvrException>()));
    },
  );

  test('worker preserves split-packet PCR wrap, PMT and segment bytes', () async {
    final worker = await TsSegmentWorker.start(
      targetDuration: const Duration(seconds: 2),
    );
    addTearDown(worker.close);
    final bytes = Uint8List.fromList([
      ..._pat(),
      for (final packet in _pmt(descriptorLength: 180)) ...packet,
      for (var second = 0; second <= 10; second++)
        ..._video(((1 << 33) - 180000 + second * 90000) % (1 << 33)),
    ]);
    final parser = MpegTsSegmenter(targetDuration: const Duration(seconds: 2));
    final expected = parser.add(bytes)..add(parser.finish()!);
    final actual = <TsSegment>[];
    for (var offset = 0; offset < bytes.length; offset += 113) {
      actual.addAll(await worker.add(Uint8List.sublistView(
        bytes, offset, (offset + 113).clamp(0, bytes.length),
      )));
    }
    actual.addAll(await worker.finish());
    expect(actual.length, expected.length);
    for (var index = 0; index < expected.length; index++) {
      expect(actual[index].bytes, expected[index].bytes);
      expect(actual[index].duration, expected[index].duration);
      expect(actual[index].discontinuity, expected[index].discontinuity);
    }
  });

  test('ordinary parser callers can reuse their input buffer after add', () {
    final parser = MpegTsSegmenter(targetDuration: const Duration(seconds: 2));
    final prefix = Uint8List.fromList([
      ..._pat(), for (final packet in _pmt()) ...packet, ..._video(0),
    ]);
    parser.add(prefix);
    prefix.fillRange(0, prefix.length, 0);
    final segment = parser.add(_video(180000)).single;
    expect(segment.bytes[0], 0x47);
    expect(_videoPackets(segment.bytes).first[0], 0x47);
  });

  test('worker keeps PTS fallback and rejects scrambled media safely', () async {
    final worker = await TsSegmentWorker.start(
      targetDuration: const Duration(seconds: 2),
    );
    addTearDown(worker.close);
    final segments = await worker.add([
      ..._pat(),
      for (final packet in _pmt()) ...packet,
      for (var second = 0; second <= 6; second++)
        ..._video(second * 90000, withPcr: false),
    ]);
    expect(segments.length, 3);
    expect(segments.map((s) => s.duration),
        everyElement(const Duration(seconds: 2)));
    await expectLater(worker.add(_video(0)..[3] |= 0x80),
        throwsA(isA<DvrException>()));
  });

  test('worker bounds in-flight chunks and shutdown settles pending work', () async {
    final worker = await TsSegmentWorker.start();
    final pending = worker.add(Uint8List(4 * 1024 * 1024));
    expect(() => worker.add(_pat()), throwsStateError);
    final settled = expectLater(pending, throwsA(isA<DvrException>()));
    await worker.close();
    await settled;
    await worker.close();
    expect(() => worker.add(_pat()), throwsStateError);
  });
}

int _pid(List<int> packet) => ((packet[1] & 0x1f) << 8) | packet[2];

Iterable<Uint8List> _packets(Uint8List bytes) sync* {
  for (var offset = 0; offset < bytes.length; offset += 188) {
    yield Uint8List.sublistView(bytes, offset, offset + 188);
  }
}

Iterable<Uint8List> _videoPackets(Uint8List bytes) =>
    _packets(bytes).where((packet) => _pid(packet) == 256);

Uint8List _pat() => _psiPackets(0, [
  0,
  0xb0,
  13,
  0,
  1,
  0xc1,
  0,
  0,
  0,
  1,
  0xe0,
  100,
  0,
  0,
  0,
  0,
]).single;

List<Uint8List> _pmt({int descriptorLength = 0}) {
  final section = <int>[
    2,
    0xb0,
    0,
    0,
    1,
    0xc1,
    0,
    0,
    0xe1,
    0,
    0xf0 | (descriptorLength >> 8),
    descriptorLength & 0xff,
    ...List<int>.filled(descriptorLength, 0),
    0x1b,
    0xe1,
    0,
    0xf0,
    0,
    0,
    0,
    0,
    0,
  ];
  final length = section.length - 3;
  section[1] |= length >> 8;
  section[2] = length & 0xff;
  return _psiPackets(100, section);
}

List<Uint8List> _psiPackets(int pid, List<int> section) {
  final result = <Uint8List>[];
  var offset = 0;
  while (offset < section.length) {
    final packet = Uint8List(188)..fillRange(0, 188, 0xff);
    packet[0] = 0x47;
    packet[1] = (pid >> 8) | (offset == 0 ? 0x40 : 0);
    packet[2] = pid & 0xff;
    packet[3] = 0x10 | result.length;
    final start = offset == 0 ? 5 : 4;
    if (offset == 0) packet[4] = 0;
    final count = (188 - start).clamp(0, section.length - offset);
    packet.setRange(start, start + count, section, offset);
    offset += count;
    result.add(packet);
  }
  return result;
}

Uint8List _video(
  int ticks, {
  bool withPcr = true,
  bool start = true,
  bool discontinuity = false,
}) {
  final packet = Uint8List(188)..fillRange(0, 188, 0xff);
  packet[0] = 0x47;
  packet[1] = 1 | (start ? 0x40 : 0);
  packet[2] = 0;
  packet[3] = 0x30;
  packet[4] = withPcr ? 7 : 1;
  packet[5] = 0x40 | (withPcr ? 0x10 : 0) | (discontinuity ? 0x80 : 0);
  if (withPcr) {
    packet[6] = (ticks >> 25) & 0xff;
    packet[7] = (ticks >> 17) & 0xff;
    packet[8] = (ticks >> 9) & 0xff;
    packet[9] = (ticks >> 1) & 0xff;
    packet[10] = ((ticks & 1) << 7) | 0x7e;
    packet[11] = 0;
  }
  final offset = 5 + packet[4];
  if (start) {
    packet.setRange(offset, offset + 9, [0, 0, 1, 0xe0, 0, 0, 0x80, 0x80, 5]);
    packet[offset + 9] = 0x21 | (((ticks >> 30) & 7) << 1);
    packet[offset + 10] = (ticks >> 22) & 0xff;
    packet[offset + 11] = (((ticks >> 15) & 0x7f) << 1) | 1;
    packet[offset + 12] = (ticks >> 7) & 0xff;
    packet[offset + 13] = ((ticks & 0x7f) << 1) | 1;
    packet.setRange(offset + 14, offset + 19, [0, 0, 1, 0x65, 0x88]);
  } else {
    packet.setRange(offset, offset + 5, [0, 0, 1, 0x65, 0x88]);
  }
  return packet;
}
