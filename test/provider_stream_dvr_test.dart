import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/data/provider_stream_gate.dart';
import 'package:iptvs/dvr/dvr_service.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  late Directory directory;
  late DvrService service;
  late _Provider provider;
  final gate = ProviderStreamGate.instance;

  setUp(() async {
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
    directory = await Directory.systemTemp.createTemp('provider-stream-dvr-');
    service = DvrService(directory: directory);
    provider = await _Provider.start();
  });

  tearDown(() async {
    await service.close();
    await provider.close();
    gate.debugReset();
    ProviderRequestGate.instance.debugReset();
    await directory.delete(recursive: true);
  });

  for (final record in [false, true]) {
    test(
      'occupied viewer quota prevents ${record ? 'recording' : 'timeshift'} HTTP',
      () async {
        final stream = provider.stream('one', maximumStreams: 1);
        final viewer = Object();
        gate.reserve(stream, owner: viewer);
        final starting = record
            ? service.startRecording(stream, channelName: 'One')
            : service.startTimeshift(stream, channelName: 'One');
        await expectLater(
          starting,
          throwsA(
            isA<DvrException>().having(
              (error) => error.message,
              'message',
              contains('stream limit (1)'),
            ),
          ),
        );
        expect(provider.requests, 0);
        expect(gate.activeStreams('account'), 1);
        gate.release(viewer);
        expect(gate.activeStreams('account'), 0);
      },
    );
  }

  test('recording occupies the account until capture stops', () async {
    final stream = provider.stream('one', maximumStreams: 1);
    final recording = await service.startRecording(
      stream,
      channelName: 'One',
      sourceId: 'source',
      channelId: 'one',
    );
    expect(gate.activeStreams('account'), 1);
    expect(
      () => gate.reserve(
        provider.stream('two', maximumStreams: 1),
        owner: Object(),
      ),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
    await service.stopRecording(recording.id);
    expect(gate.activeStreams('account'), 0);
    final viewer = Object();
    gate.reserve(provider.stream('two', maximumStreams: 1), owner: viewer);
    expect(gate.activeStreams('account'), 1);
    gate.release(viewer);
  });

  test(
    'two-stream account permits distinct recording and timeshift captures',
    () async {
      final recording = await service.startRecording(
        provider.stream('one', maximumStreams: 2),
        channelName: 'One',
        sourceId: 'source',
        channelId: 'one',
      );
      final session = await service.startTimeshift(
        provider.stream('two', maximumStreams: 2),
        channelName: 'Two',
        sourceId: 'source',
        channelId: 'two',
      );
      expect(gate.activeStreams('account'), 2);
      await service.stopTimeshift(session: session);
      expect(gate.activeStreams('account'), 1);
      await service.stopRecording(recording.id);
      expect(gate.activeStreams('account'), 0);
    },
  );

  test(
    'same-channel timeshift and recording share one provider reservation',
    () async {
      final stream = provider.stream('one', maximumStreams: 1);
      final session = await service.startTimeshift(
        stream,
        channelName: 'One',
        sourceId: 'source',
        channelId: 'one',
      );
      final recording = await service.startRecording(
        stream,
        channelName: 'One',
        sourceId: 'source',
        channelId: 'one',
      );
      expect(session.recordingId, recording.id);
      expect(gate.activeStreams('account'), 1);
      expect(session.playbackStream.providerAccount, isNull);
      await service.stopTimeshift(session: session);
      expect(gate.activeStreams('account'), 1);
      await service.stopRecording(recording.id);
      expect(gate.activeStreams('account'), 0);
    },
  );

  test('finite capture releases its reservation on completion', () async {
    provider.finite = true;
    final session = await service.startTimeshift(
      provider.stream('one', maximumStreams: 1),
      channelName: 'One',
    );
    await session.done.timeout(const Duration(seconds: 3));
    expect(gate.activeStreams('account'), 0);
    expect(session.snapshot.state, DvrCaptureState.stopped);
  });

  test(
    'cancelling a stalled startup releases its provider reservation',
    () async {
      provider.stalled = true;
      final starting = service.startTimeshift(
        provider.stream('one', maximumStreams: 1),
        channelName: 'One',
      );
      final rejected = expectLater(starting, throwsA(isA<DvrException>()));
      await provider.firstRequest.future.timeout(const Duration(seconds: 3));
      expect(gate.activeStreams('account'), 1);
      await service.stopTimeshift().timeout(const Duration(seconds: 3));
      await rejected;
      expect(gate.activeStreams('account'), 0);
      expect(provider.requests, 1);
    },
  );

  test('failed capture startup releases its provider reservation', () async {
    provider.status = 404;
    await expectLater(
      service.startTimeshift(
        provider.stream('one', maximumStreams: 1),
        channelName: 'One',
      ),
      throwsA(isA<DvrException>()),
    );
    expect(gate.activeStreams('account'), 0);
    expect(provider.requests, 1);
  });

  test('recovery keeps one reservation when a refreshed locator omits account data', () async {
    provider.temporaryFailures = 1;
    final stream = provider.stream('one', maximumStreams: 1);
    var resolutions = 0;
    final session = await service.startTimeshift(
      stream,
      channelName: 'One',
      resolveAgain: () async {
        resolutions++;
        return StreamInfo(url: stream.url);
      },
    );
    expect(resolutions, 1);
    expect(gate.activeStreams('account'), 1);
    expect(
      () => gate.reserve(
        provider.stream('two', maximumStreams: 1),
        owner: Object(),
      ),
      throwsA(isA<ProviderStreamLimitReached>()),
    );
    await service.stopTimeshift(session: session);
    expect(gate.activeStreams('account'), 0);
  });

  test(
    'a redirected refusal also pauses the configured stream origin',
    () async {
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => destination.close(force: true));
      var destinationRequests = 0;
      destination.listen((request) async {
        destinationRequests++;
        request.response.statusCode = 429;
        await request.response.close();
      });
      provider.redirect = Uri.parse(
        'http://localhost:${destination.port}/denied',
      );
      final stream = provider.stream('one', maximumStreams: 1);
      await expectLater(
        service.startTimeshift(stream, channelName: 'One'),
        throwsA(isA<DvrException>()),
      );
      expect(
        () => ProviderRequestGate.instance.check(Uri.parse(stream.url)),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(
        () => ProviderRequestGate.instance.check(provider.redirect!),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      await expectLater(
        service.startTimeshift(stream, channelName: 'One'),
        throwsA(isA<DvrException>()),
      );
      expect(provider.requests, 1);
      expect(destinationRequests, 1);
      expect(gate.activeStreams('account'), 0);
    },
  );
}

class _Provider {
  _Provider(this.server);
  final HttpServer server;
  final firstRequest = Completer<void>();
  final _closed = Completer<void>();
  var requests = 0;
  var finite = false;
  var stalled = false;
  var status = 200;
  var temporaryFailures = 0;
  Uri? redirect;

  StreamInfo stream(String channel, {required int maximumStreams}) =>
      StreamInfo(
        url: 'http://127.0.0.1:${server.port}/$channel.m3u8',
        providerAccount: ProviderStreamAccount(
          id: 'account',
          maximumStreams: maximumStreams,
        ),
      );

  static Future<_Provider> start() async {
    final result = _Provider(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen((request) => unawaited(result._serve(request)));
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    requests++;
    if (!firstRequest.isCompleted) firstRequest.complete();
    try {
      if (stalled) await _closed.future;
      if (temporaryFailures > 0) {
        temporaryFailures--;
        request.response.statusCode = 500;
        return;
      }
      request.response.statusCode = status;
      if (status != 200) return;
      if (redirect != null) {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, redirect!);
        return;
      }
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXTINF:2,\nsegment-0.ts\n#EXTINF:2,\nsegment-1.ts\n'
          '${finite ? '#EXT-X-ENDLIST\n' : ''}',
        );
      } else {
        request.response.add(Uint8List(100));
      }
    } catch (_) {
      // Cancellation deliberately closes this local fixture connection.
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
    await server.close(force: true);
  }
}
