import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/sources/source.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late DvrService service;
  late _Provider provider;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tvbro-dvr-test-');
    service = DvrService(directory: directory);
    provider = await _Provider.start();
  });

  tearDown(() async {
    await service.close();
    await provider.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'saved recording plays only local files after the provider closes',
    () async {
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'Local fixture',
        sourceId: 'source',
        channelId: 'one',
      );
      await _until(service, () => service.recordings.first.bytes >= 300);
      await service.stopRecording(recording.id);
      expect(service.recordings.single.status, DvrRecordingStatus.completed);
      final requests = provider.mediaRequests;
      await provider.close();
      final stream = await service.recordingPlayback(service.recordings.single);
      final manifest = await _get(Uri.parse(stream.url));
      expect(manifest.text, contains('#EXT-X-ENDLIST'));
      expect(manifest.text, isNot(contains('provider-secret')));
      expect(manifest.text, isNot(contains('http')));
      final media = _mediaUris(manifest.text, Uri.parse(stream.url));
      expect(media, hasLength(3));
      for (final uri in media) {
        final response = await _get(uri);
        expect(response.status, 200);
        expect(response.bytes, hasLength(100));
      }
      expect(provider.mediaRequests, requests);
      final metadata = await File(
        p.join(directory.path, 'recordings', recording.id, 'recording.json'),
      ).readAsString();
      expect(metadata, isNot(contains('provider-secret')));
      expect(metadata, isNot(contains('Authorization')));
    },
  );

  test(
    'timeshift uses one capture, survives a recorded-channel zap and reloads',
    () async {
      final first = await service.startTimeshift(
        provider.stream,
        channelName: 'Channel one',
        sourceId: 'source',
        channelId: 'one',
      );
      await _until(
        service,
        () => first.snapshot.bufferEnd >= const Duration(seconds: 6),
      );
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'Channel one',
        sourceId: 'source',
        channelId: 'one',
      );
      expect(first.recordingId, recording.id);
      await service.stopTimeshift(session: first);
      expect(service.activeRecording?.id, recording.id);
      final returned = await service.startTimeshift(
        StreamInfo(
          url: '${provider.origin}/changed.m3u8?token=provider-secret',
        ),
        channelName: 'Channel one',
        sourceId: 'source',
        channelId: 'one',
      );
      expect(returned.id, first.id);
      expect(returned.recordingId, recording.id);
      expect(provider.changedRequests, 0);
      await service.stopTimeshift(
        session: first,
      ); // superseded viewer cannot detach it
      expect(service.activeSession, same(returned));
      await service.stopRecording(recording.id);
      expect(returned.snapshot.state, DvrCaptureState.buffering);
    },
  );

  test('a local cursor advances across more than six segments and preserves discontinuity', () async {
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Channel',
    );
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 6),
    );
    final initial = session.playbackAt(Duration.zero);
    expect(session.playbackOriginFor(Duration.zero), Duration.zero);
    var manifest = await _get(Uri.parse(initial.url));
    provider.visible = 14;
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 30),
    );
    final seen = <String>{};
    var previousSequence = -1;
    var discontinuitySeen = false;
    for (var read = 0; read < 6; read++) {
      manifest = await _get(Uri.parse(initial.url));
      final sequence = int.parse(
        RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(manifest.text)![1]!,
      );
      expect(sequence, greaterThanOrEqualTo(previousSequence));
      previousSequence = sequence;
      discontinuitySeen |= manifest.text.contains('#EXT-X-DISCONTINUITY\n');
      for (final uri in _mediaUris(manifest.text, Uri.parse(initial.url))) {
        final response = await _get(uri);
        expect(response.status, 200);
        seen.add(uri.pathSegments.last);
      }
    }
    expect(seen.length, greaterThan(6));
    expect(discontinuitySeen, isTrue);
    expect(session.playbackOriginFor(Duration.zero), Duration.zero);
    expect(provider.mediaRequests, 15);
    final beforeReplay = provider.mediaRequests;
    final rewind = session.playbackAt(const Duration(seconds: 4));
    final rewindManifest = await _get(Uri.parse(rewind.url));
    final replay = await _get(
      _mediaUris(rewindManifest.text, Uri.parse(rewind.url)).first,
    );
    expect(replay.bytes.first, 2);
    expect(provider.mediaRequests, beforeReplay);
  });

  test(
    'local range handling and capability routing reject invalid access',
    () async {
      final session = await service.startTimeshift(
        provider.stream,
        channelName: 'Channel',
      );
      final url = Uri.parse(session.playbackStream.url);
      final manifest = await _get(url);
      final media = _mediaUris(manifest.text, url).first;
      final range = await _get(media, range: 'bytes=5-11');
      expect(range.status, 206);
      expect(range.bytes.length, 7);
      expect((await _get(media, range: 'bytes=999-')).status, 416);
      expect((await _get(media, range: 'bytes=0-1,5-6')).status, 416);
      expect(
        (await _get(url.replace(path: '/live/wrong/cursor/index.m3u8'))).status,
        404,
      );
      expect((await _get(url.resolve('../recording.json'))).status, 404);
      expect((await _get(url.resolve('key-999.bin'))).status, 410);
    },
  );

  test(
    'cancels a starting capture without waiting for a stalled provider',
    () async {
      provider.stall = true;
      final starting = service.startTimeshift(
        provider.stream,
        channelName: 'Stalled',
      );
      final failed = expectLater(starting, throwsA(isA<DvrException>()));
      await _until(service, () => service.activeSession != null);
      final done = service.activeSession!.done;
      await service.stopTimeshift().timeout(const Duration(seconds: 2));
      await failed;
      await done;
      expect(service.activeSession, isNull);
    },
  );

  test('stopping a starting recording cancels its stalled network request promptly', () async {
    provider.stall = true;
    final starting = service.startRecording(
      provider.stream,
      channelName: 'Stalled recording',
    );
    final failed = expectLater(starting, throwsA(isA<DvrException>()));
    await _until(service, () => service.activeRecording != null);
    final id = service.activeRecording!.id;
    await service.stopRecording(id).timeout(const Duration(seconds: 2));
    await failed;
    expect(service.activeRecording, isNull);
    expect(service.recordings.single.status, DvrRecordingStatus.failed);
  });

  test('buffer eviction respects byte cap and stops explicitly for advertised leases', () async {
    await service.updateSettings(
      const DvrSettings(maxBufferBytes: 1024 * 1024),
    );
    provider.segmentBytes = 400000;
    provider.visible = 1;
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Large',
    );
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 4),
    );
    await _get(Uri.parse(session.playbackAt(Duration.zero).url));
    provider.visible = 3;
    await session.done.timeout(const Duration(seconds: 5));
    expect(session.snapshot.state, DvrCaptureState.failed);
    expect(session.snapshot.error, contains('buffer limit'));
    expect(
      session.snapshot.bytes,
      lessThanOrEqualTo(service.settings.maxBufferBytes),
    );
  });

  test('recording quota stops capture and keeps already saved media', () async {
    await service.updateSettings(
      const DvrSettings(maxRecordingsBytes: 1024 * 1024),
    );
    provider.segmentBytes = 400000;
    final recording = await service.startRecording(
      provider.stream,
      channelName: 'Quota',
    );
    await _until(service, () => service.activeRecording == null);
    final saved = service.recordings.single;
    expect(saved.id, recording.id);
    expect(saved.status, DvrRecordingStatus.interrupted);
    expect(saved.bytes, 800000);
    expect(saved.error, contains('storage is full'));
    expect(
      await Directory(p.join(directory.path, 'buffers')).list().toList(),
      isEmpty,
    );
    expect(
      (await _get(Uri.parse((await service.recordingPlayback(saved)).url)))
          .status,
      200,
    );
  });

  test('buffer eviction removes old files without crossing the configured byte cap', () async {
    await service.updateSettings(
      const DvrSettings(maxBufferBytes: 1024 * 1024),
    );
    provider.segmentBytes = 400000;
    provider.visible = 1;
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Eviction',
    );
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 4),
    );
    provider.visible = 3;
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 8),
    );
    expect(session.snapshot.bufferStart, const Duration(seconds: 4));
    expect(session.snapshot.bytes, 800000);
    final files = await Directory(p.join(directory.path, 'buffers', session.id))
        .list()
        .toList();
    expect(files.whereType<File>().length, 2);
    expect(session.snapshot.state, DvrCaptureState.buffering);
  });

  test(
    'the duration cap keeps only the configured complete segment window',
    () async {
      await service.updateSettings(
        const DvrSettings(maxBufferDuration: Duration(seconds: 10)),
      );
      final session = await service.startTimeshift(
        provider.stream,
        channelName: 'Duration',
      );
      await _until(
        service,
        () => session.snapshot.bufferEnd >= const Duration(seconds: 6),
      );
      provider.visible = 14;
      await _until(
        service,
        () => session.snapshot.bufferEnd >= const Duration(seconds: 30),
      );
      expect(session.snapshot.bufferedDuration, const Duration(seconds: 10));
      expect(session.snapshot.bufferStart, const Duration(seconds: 20));
    },
  );

  test('a failed recording append rolls back new media and still releases its buffer', () async {
    provider.visible = 0;
    final recording = await service.startRecording(
      provider.stream,
      channelName: 'Disk failure',
    );
    final saved = Directory(p.join(directory.path, 'recordings', recording.id));
    final journal = File(p.join(saved.path, 'segments.jsonl'));
    await journal.rename('${journal.path}.saved');
    await Directory(journal.path).create();
    provider.visible = 1;
    await _until(service, () => service.activeRecording == null);
    expect(service.recordings.single.bytes, 100);
    expect(service.recordings.single.status, DvrRecordingStatus.interrupted);
    expect(await File(p.join(saved.path, 'segment-1.ts')).exists(), isFalse);
    expect(
      await File(p.join(saved.path, 'segment-1.ts.partial')).exists(),
      isFalse,
    );
    expect(
      await Directory(p.join(directory.path, 'buffers')).list().toList(),
      isEmpty,
    );
  });

  test(
    'stopping recording A does not wait for another channel B to become ready',
    () async {
      final second = await _Provider.start()
        ..stall = true;
      addTearDown(second.close);
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'A',
        sourceId: 'source-a',
        channelId: 'one',
      );
      await _until(service, () => service.recordings.single.bytes >= 300);
      final startingB = service.startTimeshift(
        second.stream,
        channelName: 'B',
        sourceId: 'source-b',
        channelId: 'one',
      );
      final cancelledB = expectLater(startingB, throwsA(isA<DvrException>()));
      await _until(service, () => service.activeSession?.channelName == 'B');
      final b = service.activeSession!;
      await service
          .stopRecording(recording.id)
          .timeout(const Duration(seconds: 2));
      expect(service.recordings.single.status, DvrRecordingStatus.completed);
      expect(service.recordings.single.bytes, 300);
      expect(service.activeSession, same(b));
      expect(b.snapshot.state, DvrCaptureState.starting);
      await service.stopTimeshift(session: b);
      await cancelledB;
    },
  );

  test('a superseded pending viewer cannot clean up its replacement', () async {
    final second = await _Provider.start()
      ..stall = true;
    addTearDown(second.close);
    final startingB = service.startTimeshift(second.stream, channelName: 'B');
    final cancelledB = expectLater(startingB, throwsA(isA<DvrException>()));
    await _until(service, () => service.activeSession?.channelName == 'B');
    final c = await service.startTimeshift(provider.stream, channelName: 'C');
    await cancelledB;
    expect(service.activeSession, same(c));
    expect(c.snapshot.state, DvrCaptureState.buffering);
    expect(c.snapshot.bytes, greaterThan(0));
  });

  test(
    'record A, view B and return to A retain one capture per provider',
    () async {
      final second = await _Provider.start();
      addTearDown(second.close);
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'A',
        sourceId: 'source-a',
        channelId: 'one',
      );
      await _until(service, () => service.recordings.single.bytes >= 300);
      final b = await service.startTimeshift(
        second.stream,
        channelName: 'B',
        sourceId: 'source-b',
        channelId: 'one',
      );
      await _until(
        service,
        () => b.snapshot.bufferEnd >= const Duration(seconds: 6),
      );
      final a = await service.attachRecording(recording.id);
      expect(a.recordingId, recording.id);
      expect(service.activeSession, same(a));
      expect(provider.mediaRequests, 3);
      expect(second.mediaRequests, 3);
      expect(b.snapshot.state, DvrCaptureState.stopped);
      expect(
        await Directory(p.join(directory.path, 'buffers', b.id)).exists(),
        isFalse,
      );
      expect(service.activeRecording?.id, recording.id);
    },
  );

  test('initial recording includes the startup prefix and reattaches without upstream resolution', () async {
    final session = await service.startTimeshift(
      provider.stream,
      channelName: 'Startup',
      sourceId: 'source',
      channelId: 'one',
    );
    await _until(
      service,
      () => session.snapshot.bufferEnd >= const Duration(seconds: 6),
    );
    final recording = await service.startRecording(
      provider.stream,
      channelName: 'Startup',
      sourceId: 'source',
      channelId: 'one',
      includeBuffered: true,
    );
    expect(recording.bytes, 300);
    expect(recording.duration, const Duration(seconds: 6));
    await service.stopTimeshift(session: session);
    final before = provider.mediaRequests;
    final attached = await service.attachRecording(recording.id);
    expect(attached.id, session.id);
    final local = await service.recordingPlayback(service.activeRecording!);
    expect(local.url, startsWith('http://127.0.0.1:'));
    expect(local.isLive, isTrue);
    expect(provider.mediaRequests, before);
  });

  test(
    'startup recovers an interrupted manifest and rejects missing tail media',
    () async {
      final recording = await service.startRecording(
        provider.stream,
        channelName: 'Recovered',
      );
      await _until(service, () => service.recordings.single.bytes >= 300);
      await service.close();
      final file = File(
        p.join(directory.path, 'recordings', recording.id, 'recording.json'),
      );
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      json['status'] = 'recording';
      final segments = json['segments'] as List;
      final tail = segments.last as Map;
      await File(p.join(file.parent.path, tail['filename'] as String)).delete();
      await file.writeAsString(jsonEncode(json));
      service = DvrService(directory: directory);
      await service.ensureInitialized();
      final recovered = service.recordings.single;
      expect(recovered.status, DvrRecordingStatus.interrupted);
      expect(recovered.duration, const Duration(seconds: 4));
      expect(recovered.bytes, 200);
      final manifest = await _get(
        Uri.parse((await service.recordingPlayback(recovered)).url),
      );
      expect(
        _mediaUris(
          manifest.text,
          Uri.parse((await service.recordingPlayback(recovered)).url),
        ),
        hasLength(2),
      );
      expect(manifest.text, contains('#EXT-X-ENDLIST'));
    },
  );

  test('crash recovery replays durable journal before a torn last row', () async {
    final recording = await service.startRecording(
      provider.stream, channelName: 'Journal crash',
    );
    await _until(service, () => service.recordings.single.bytes == 300);
    final saved = Directory(p.join(directory.path, 'recordings', recording.id));
    final metadata = File(p.join(saved.path, 'recording.json'));
    final journal = File(p.join(saved.path, 'segments.jsonl'));
    final checkpoint = await metadata.readAsString();
    final committed = await journal.readAsString();
    expect((jsonDecode(checkpoint) as Map)['segments'], isEmpty);
    expect(const LineSplitter().convert(committed), hasLength(3));
    await service.close();
    // Restore the files visible at process death, without a graceful close.
    await metadata.writeAsString(checkpoint, flush: true);
    await journal.writeAsString('$committed{"index":3,"segment":', flush: true);
    service = DvrService(directory: directory);
    await service.ensureInitialized();
    final recovered = service.recordings.single;
    expect(recovered.status, DvrRecordingStatus.interrupted);
    expect(recovered.bytes, 300);
    expect(recovered.duration, const Duration(seconds: 6));
    expect(await journal.exists(), isFalse);
    final manifest = await _get(Uri.parse(
      (await service.recordingPlayback(recovered)).url,
    ));
    expect(_mediaUris(manifest.text, Uri.parse('http://localhost/')), hasLength(3));
  });

  test('recovery skips journal rows already present in an atomic checkpoint', () async {
    final recording = await service.startRecording(
      provider.stream, channelName: 'Checkpoint crash',
    );
    await _until(service, () => service.recordings.single.bytes == 300);
    final saved = Directory(p.join(directory.path, 'recordings', recording.id));
    final journal = File(p.join(saved.path, 'segments.jsonl'));
    final committed = await journal.readAsString();
    await service.close();
    final metadata = File(p.join(saved.path, 'recording.json'));
    final checkpoint = jsonDecode(await metadata.readAsString()) as Map;
    checkpoint['status'] = 'recording';
    checkpoint['segments'] = (checkpoint['segments'] as List).take(2).toList();
    await metadata.writeAsString(jsonEncode(checkpoint), flush: true);
    await journal.writeAsString(committed, flush: true);
    service = DvrService(directory: directory);
    await service.ensureInitialized();
    expect(service.recordings.single.bytes, 300);
    expect(service.recordings.single.duration, const Duration(seconds: 6));
    final recovered = jsonDecode(await metadata.readAsString()) as Map;
    expect(recovered['segments'], hasLength(3));
  });

  test('failed checkpoint keeps its durable journal and capture running', () async {
    provider.visible = 0;
    final recording = await service.startRecording(
      provider.stream, channelName: 'Checkpoint storage failure',
    );
    final saved = Directory(p.join(directory.path, 'recordings', recording.id));
    final blockedCheckpoint = Directory(p.join(saved.path, 'recording.json.new'));
    await blockedCheckpoint.create();
    provider.visible = 130;
    await _until(service, () => service.recordings.single.bytes == 13100);
    final journal = File(p.join(saved.path, 'segments.jsonl'));
    final committed = await journal.readAsString();
    expect(const LineSplitter().convert(committed), hasLength(131));
    expect(service.activeRecording?.id, recording.id);
    final metadata = File(p.join(saved.path, 'recording.json'));
    final checkpoint = await metadata.readAsString();
    await blockedCheckpoint.delete();
    await service.close();
    await metadata.writeAsString(checkpoint, flush: true);
    await journal.writeAsString(committed, flush: true);
    service = DvrService(directory: directory);
    await service.ensureInitialized();
    expect(service.recordings.single.bytes, 13100);
    expect(service.recordings.single.duration, const Duration(seconds: 262));
  });

  test('periodic checkpoint compacts only the already durable journal prefix', () async {
    provider.visible = 0;
    final recording = await service.startRecording(
      provider.stream, channelName: 'Compacted journal',
    );
    provider.visible = 130;
    await _until(service, () => service.recordings.single.bytes == 13100);
    final saved = Directory(p.join(directory.path, 'recordings', recording.id));
    final metadata = File(p.join(saved.path, 'recording.json'));
    final journal = File(p.join(saved.path, 'segments.jsonl'));
    final checkpoint = await metadata.readAsString();
    final committed = await journal.readAsString();
    expect((jsonDecode(checkpoint) as Map)['segments'], hasLength(128));
    expect(const LineSplitter().convert(committed), hasLength(3));
    await service.close();
    await metadata.writeAsString(checkpoint, flush: true);
    await journal.writeAsString(committed, flush: true);
    service = DvrService(directory: directory);
    await service.ensureInitialized();
    expect(service.recordings.single.bytes, 13100);
    expect(service.recordings.single.duration, const Duration(seconds: 262));
  });

  test(
    'encrypted HLS stores only local key resources and original implicit IV',
    () async {
      provider.encrypted = true;
      final session = await service.startTimeshift(
        provider.stream,
        channelName: 'AES',
      );
      final url = Uri.parse(session.playbackAt(Duration.zero).url);
      final manifest = await _get(url);
      expect(manifest.text, contains('IV=0x00000000000000000000000000000025'));
      expect(manifest.text, isNot(contains('provider-secret')));
      final key = RegExp(r'URI="([^"]+)"').firstMatch(manifest.text)![1]!;
      expect((await _get(url.resolve(key))).bytes, hasLength(16));
      expect(provider.authorizationSeen, isTrue);
    },
  );
}

Future<void> _until(DvrService service, bool Function() condition) async {
  if (condition()) return;
  final ready = Completer<void>();
  void listener() {
    if (condition() && !ready.isCompleted) ready.complete();
  }

  service.addListener(listener);
  try {
    listener();
    await ready.future.timeout(const Duration(seconds: 5));
  } finally {
    service.removeListener(listener);
  }
}

class _Response {
  _Response(this.status, this.bytes);
  final int status;
  final Uint8List bytes;
  String get text => utf8.decode(bytes);
}

Future<_Response> _get(Uri uri, {String? range}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    return _Response(response.statusCode, bytes.takeBytes());
  } finally {
    client.close(force: true);
  }
}

List<Uri> _mediaUris(String manifest, Uri base) => manifest
    .split('\n')
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .map(base.resolve)
    .toList();

class _Provider {
  _Provider(this.server);
  final HttpServer server;
  int visible = 2;
  int segmentBytes = 100;
  int mediaRequests = 0;
  int changedRequests = 0;
  bool authorizationSeen = false;
  bool encrypted = false;
  bool stall = false;
  bool _closed = false;
  final Completer<void> _shutdown = Completer<void>();

  String get origin => 'http://127.0.0.1:${server.port}';
  StreamInfo get stream => StreamInfo(
    url: '$origin/live.m3u8?token=provider-secret',
    headers: const {
      'Authorization': 'Bearer provider-secret',
      'User-Agent': 'DVR fixture',
    },
  );

  static Future<_Provider> start() async {
    final provider = _Provider(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    provider.server.listen((request) => unawaited(provider._serve(request)));
    return provider;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      authorizationSeen |=
          request.headers.value(HttpHeaders.authorizationHeader) ==
          'Bearer provider-secret';
      if (stall) {
        await _shutdown.future;
        return;
      }
      if (request.uri.path.endsWith('.m3u8')) {
        if (request.uri.path.contains('changed')) changedRequests++;
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        final text = StringBuffer(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:${encrypted ? 37 : 0}\n',
        );
        if (encrypted) {
          text.writeln(
            '#EXT-X-KEY:METHOD=AES-128,URI="key.bin?secret=provider-secret"',
          );
        }
        for (var index = 0; index <= visible; index++) {
          if (index == 7) text.writeln('#EXT-X-DISCONTINUITY');
          text.writeln('#EXTINF:2,\nsegment-$index.ts?secret=provider-secret');
        }
        request.response.write(text);
      } else if (request.uri.path.endsWith('.ts')) {
        mediaRequests++;
        final index = int.parse(
          RegExp(r'(\d+)\.ts').firstMatch(request.uri.path)![1]!,
        );
        request.response.add(
          Uint8List(segmentBytes)..fillRange(0, segmentBytes, index),
        );
      } else if (request.uri.path.endsWith('key.bin')) {
        request.response.add(Uint8List(16));
      } else {
        request.response.statusCode = 404;
      }
    } catch (_) {
      // Closing a fixture provider deliberately disconnects in-flight clients.
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _shutdown.complete();
    await server.close(force: true);
  }
}
