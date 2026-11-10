import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory directory;
  late DvrService service;
  late _RecoveryProvider provider;
  const quickRetry = DvrRetryPolicy(
    maxRetries: 2,
    initialDelay: Duration(milliseconds: 20),
    maxDelay: Duration(milliseconds: 40),
    jitterFraction: 0,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tvbro-recovery-test-');
    service = DvrService(directory: directory, retryPolicy: quickRetry);
    provider = await _RecoveryProvider.start();
  });

  tearDown(() async {
    await service.close();
    await provider.close();
    await directory.delete(recursive: true);
  });

  test('retry delay grows exponentially with capped jitter', () {
    const policy = DvrRetryPolicy();
    expect(policy.delayFor(1, randomValue: 0.5), const Duration(seconds: 1));
    expect(policy.delayFor(3, randomValue: 0.5), const Duration(seconds: 4));
    expect(policy.delayFor(20, randomValue: 0.5), const Duration(seconds: 8));
    expect(
      policy.delayFor(1, randomValue: 0),
      const Duration(milliseconds: 800),
    );
    expect(
      policy.delayFor(1, randomValue: 1),
      const Duration(milliseconds: 1200),
    );
  });

  test(
    'live TS EOF reconnects with a monotonic timeline and discontinuity',
    () async {
      provider.directTs = true;
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'TS recovery',
      );
      String captureState() =>
          'tsRequests=${provider.tsRequests}; '
          '${service.recordings.map((item) => '${item.status.name}: '
              '${item.duration.inMicroseconds}us, ${item.bytes} bytes, '
              'gaps=${item.hasGaps}, error=${item.error}').join('; ')}';
      await _until(
        service,
        () => service.recordings.single.hasGaps,
        describe: captureState,
      );
      final prefixDuration = service.recordings.single.duration;
      provider.resumeTs.complete();
      await _until(
        service,
        () => service.recordings.single.duration > prefixDuration,
        describe: captureState,
      );
      await service.stopRecording(recording.id);
      final saved = service.recordings.single;
      expect(provider.tsRequests, 2);
      expect(saved.hasGaps, isTrue);
      expect(saved.status, DvrRecordingStatus.completed);
      final manifest = await _manifest(await service.recordingPlayback(saved));
      expect(manifest, contains('#EXT-X-DISCONTINUITY\n'));
      final names = _segments(manifest);
      for (var index = 0; index < names.length; index++) {
        expect(names[index], 'segment-$index.ts');
      }
    },
  );

  test('a failed HLS download retries without duplicate segments or sequence reset', () async {
    final recording = await service.startRecording(
      provider.stream,
      channelName: 'Recovery',
    );
    await _until(service, () => service.recordings.single.bytes == 300);
    provider.disconnectSegments.add(3);
    provider.last = 4;
    await _until(service, () => service.recordings.single.bytes == 500);
    await service.stopRecording(recording.id);
    final saved = service.recordings.single;
    expect(saved.status, DvrRecordingStatus.completed);
    expect(saved.hasGaps, isFalse);
    expect(saved.duration, const Duration(seconds: 10));
    final manifest = await _manifest(await service.recordingPlayback(saved));
    final names = _segments(manifest);
    expect(names, hasLength(5));
    expect(names.toSet(), hasLength(5));
    expect(names.last, 'segment-4.ts');
    expect(manifest, contains('#EXT-X-DISCONTINUITY\n'));
    expect(provider.segmentRequests[3], 2);
  });

  test('recovery after an expired HLS window keeps prefix and flags a discontinuity gap', () async {
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Gap',
      sourceId: 'source',
      channelId: 'one',
    );
    await _until(
      service,
      () => session.snapshot.bufferEnd == const Duration(seconds: 6),
    );
    final recording = await service.startRecording(
      provider.stream,
      channelName: 'Gap',
      sourceId: 'source',
      channelId: 'one',
      includeBuffered: true,
    );
    provider.playlistFailures = 1;
    provider.first = 6;
    provider.last = 8;
    await _until(service, () => service.recordings.single.bytes == 600);
    expect(session.snapshot.bufferEnd, const Duration(seconds: 12));
    await service.stopRecording(recording.id);
    expect(service.recordings.single.hasGaps, isTrue);
    final manifest = await _manifest(
      await service.recordingPlayback(service.recordings.single),
    );
    expect(_segments(manifest), hasLength(6));
    expect(manifest, contains('#EXT-X-DISCONTINUITY\n'));
  });

  test(
    'authentication rejection fails immediately without a refresh callback',
    () async {
      provider.status = 401;
      await expectLater(
        service.startTimeshift(provider.stream, channelName: 'Auth'),
        throwsA(isA<DvrException>()),
      );
      expect(provider.playlistRequests, 1);
    },
  );

  test(
    'an expiring locator is refreshed once and stored metadata remains safe',
    () async {
      provider.requiredToken = 'fresh';
      var refreshed = 0;
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'Fresh token',
        resolveAgain: () async {
          refreshed++;
          return provider.streamFor('fresh');
        },
      );
      expect(refreshed, 1);
      await _until(service, () => service.recordings.single.bytes == 300);
      expect(provider.playlistRequests, 2);
      await service.stopRecording(recording.id);
      final manifest = await _manifest(
        await service.recordingPlayback(service.recordings.single),
      );
      expect(manifest, isNot(contains('fresh')));
      expect(manifest, isNot(contains(provider.origin)));
    },
  );

  test('permanent refusal and repeated authentication never loop', () async {
    provider.status = 404;
    await expectLater(
      service.startTimeshift(provider.stream, channelName: 'Missing'),
      throwsA(isA<DvrException>()),
    );
    expect(provider.playlistRequests, 1);
    provider.status = 403;
    var refreshed = 0;
    await expectLater(
      service.startTimeshift(
        provider.stream,
        channelName: 'Auth',
        resolveAgain: () async {
          refreshed++;
          return provider.stream;
        },
      ),
      throwsA(isA<DvrException>()),
    );
    expect(refreshed, 1);
    expect(provider.playlistRequests, 3);
  });

  test(
    'exhausted transient recovery retains a playable interrupted recording',
    () async {
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'Partial',
      );
      await _until(service, () => service.recordings.single.bytes == 300);
      provider.status = 503;
      await _until(service, () => service.activeRecording == null);
      final saved = service.recordings.single;
      expect(saved.id, recording.id);
      expect(saved.status, DvrRecordingStatus.interrupted);
      expect(saved.bytes, 300);
      expect(saved.error, contains('did not recover'));
      expect(provider.playlistRequests, 4);
      expect(
        await _manifest(await service.recordingPlayback(saved)),
        contains('#EXT-X-ENDLIST'),
      );
    },
  );

  test('stop cancels recovery backoff without waiting for its timer', () async {
    await service.close();
    service = DvrService(
      directory: directory,
      retryPolicy: const DvrRetryPolicy(
        initialDelay: Duration(seconds: 30),
        maxDelay: Duration(seconds: 30),
        jitterFraction: 0,
      ),
    );
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Cancel',
    );
    provider.status = 503;
    await _until(service, () => session.snapshot.reconnecting);
    final requests = provider.playlistRequests;
    await service.stopTimeshift().timeout(const Duration(seconds: 1));
    await session.done;
    expect(session.snapshot.state, DvrCaptureState.stopped);
    expect(provider.playlistRequests, requests);
  });
}

Future<void> _until(
  DvrService service,
  bool Function() condition, {
  String Function()? describe,
}) async {
  if (condition()) return;
  final completed = Completer<void>();
  void listener() {
    if (condition() && !completed.isCompleted) completed.complete();
  }

  service.addListener(listener);
  try {
    listener();
    await completed.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw TimeoutException(describe?.call() ?? 'DVR condition not reached');
      },
    );
  } finally {
    service.removeListener(listener);
  }
}

Future<String> _manifest(StreamInfo stream) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(stream.url))).close();
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}

List<String> _segments(String value) => value
    .split('\n')
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .toList();

class _RecoveryProvider {
  _RecoveryProvider(this.server);
  final HttpServer server;
  int first = 0;
  int last = 2;
  int? status;
  int playlistFailures = 0;
  int playlistRequests = 0;
  int tsRequests = 0;
  bool directTs = false;
  final Completer<void> _shutdown = Completer<void>();
  final Completer<void> resumeTs = Completer<void>();
  String? requiredToken;
  final Map<int, int> segmentFailures = {};
  final Set<int> disconnectSegments = {};
  final Map<int, int> segmentRequests = {};
  String get origin => 'http://127.0.0.1:${server.port}';
  StreamInfo get stream => streamFor('old');
  StreamInfo streamFor(String token) =>
      StreamInfo(url: '$origin/live.${directTs ? 'ts' : 'm3u8'}?token=$token');

  static Future<_RecoveryProvider> start() async {
    final value = _RecoveryProvider(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    value.server.listen((request) => unawaited(value.serve(request)));
    return value;
  }

  Future<void> serve(HttpRequest request) async {
    try {
      if (directTs) {
        tsRequests++;
        if (tsRequests > 1) await resumeTs.future;
        // The second response stays open like live TV. Dart otherwise retains
        // this small fixture in its HTTP output buffer until response.close().
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType('video', 'MP2T');
        request.response.add(_transportFixture());
        await request.response.flush();
        if (tsRequests > 1) await _shutdown.future;
      } else if (request.uri.path.endsWith('.m3u8')) {
        playlistRequests++;
        if (status != null || playlistFailures > 0) {
          request.response.statusCode = status ?? 503;
          if (playlistFailures > 0) playlistFailures--;
          return;
        }
        if (requiredToken != null &&
            request.uri.queryParameters['token'] != requiredToken) {
          request.response.statusCode = 401;
          return;
        }
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:$first\n',
        );
        for (var index = first; index <= last; index++) {
          request.response.write('#EXTINF:2,\nsegment-$index.ts\n');
        }
      } else {
        final index = int.parse(
          RegExp(r'(\d+)\.ts').firstMatch(request.uri.path)![1]!,
        );
        segmentRequests.update(index, (count) => count + 1, ifAbsent: () => 1);
        if (disconnectSegments.remove(index)) {
          // detachSocket must precede all response writes, even with
          // writeHeaders:false. Emit a deliberately truncated HTTP body on the
          // socket so the real HttpClient observes an actual dropped download.
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: video/MP2T\r\n'
              'Content-Length: 100\r\n'
              'Connection: close\r\n\r\n',
            ),
          );
          socket.add(Uint8List(40));
          await socket.flush();
          socket.destroy();
          return;
        }
        if ((segmentFailures[index] ?? 0) > 0) {
          segmentFailures[index] = segmentFailures[index]! - 1;
          request.response.statusCode = 503;
        } else {
          request.response.add(Uint8List(100)..fillRange(0, 100, index));
        }
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() {
    if (!_shutdown.isCompleted) _shutdown.complete();
    if (!resumeTs.isCompleted) resumeTs.complete();
    return server.close(force: true);
  }
}

Uint8List _transportFixture() {
  Uint8List psi(int pid, List<int> section) {
    final packet = Uint8List(188)..fillRange(0, 188, 0xff);
    packet.setRange(0, 5, [0x47, 0x40 | (pid >> 8), pid & 0xff, 0x10, 0]);
    packet.setRange(5, 5 + section.length, section);
    return packet;
  }

  final bytes = BytesBuilder(copy: false)
    ..add(psi(0, [0, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xe0, 100, 0, 0, 0, 0]))
    ..add(
      psi(100, [
        2,
        0xb0,
        18,
        0,
        1,
        0xc1,
        0,
        0,
        0xe1,
        0,
        0xf0,
        0,
        0x1b,
        0xe1,
        0,
        0xf0,
        0,
        0,
        0,
        0,
        0,
      ]),
    );
  for (var second = 0; second <= 5; second++) {
    final ticks = second * 90000;
    final packet = Uint8List(188)..fillRange(0, 188, 0xff);
    packet.setRange(0, 6, [0x47, 0x41, 0, 0x30, 7, 0x50]);
    packet[6] = (ticks >> 25) & 0xff;
    packet[7] = (ticks >> 17) & 0xff;
    packet[8] = (ticks >> 9) & 0xff;
    packet[9] = (ticks >> 1) & 0xff;
    packet[10] = ((ticks & 1) << 7) | 0x7e;
    packet[11] = 0;
    packet.setRange(12, 21, [0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0]);
    packet.setRange(21, 26, [0, 0, 1, 0x65, 0x88]);
    bytes.add(packet);
  }
  return bytes.takeBytes();
}
