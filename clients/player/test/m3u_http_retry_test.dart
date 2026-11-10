import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/m3u_source.dart';

void main() {
  late HttpServer server;
  late M3uSource source;
  late List<int> statuses;
  late List<Uri> requests;
  late List<Duration> requestTimes;
  late Stopwatch clock;
  late int interruptedResponses;
  String? responseBody;
  Completer<void>? firstRequestStarted;
  Completer<void>? releaseFirstResponse;
  late bool skipFirstResponse;

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    statuses = [HttpStatus.ok];
    requests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    responseBody = null;
    firstRequestStarted = null;
    releaseFirstResponse = null;
    skipFirstResponse = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      requestTimes.add(clock.elapsed);
      final index = requests.length - 1;
      if (index == 0) {
        firstRequestStarted?.complete();
        await releaseFirstResponse?.future;
        if (skipFirstResponse) return;
      }
      if (index < interruptedResponses) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n'
          'Connection: close\r\n\r\n#EXTM3U',
        );
        await socket.close();
        return;
      }
      request.response.statusCode =
          statuses[index < statuses.length ? index : statuses.length - 1];
      request.response.write(
        responseBody ?? '#EXTM3U\n'
        '#EXTINF:-1 group-title="Live",Recovered channel\n'
        'http://example.invalid/live.ts\n',
      );
      await request.response.close();
    });
    source = M3uSource(
      sourceId: 'test',
      playlistUrl: 'http://127.0.0.1:${server.port}/playlist.m3u',
    );
  });

  tearDown(() async {
    await source.dispose();
    await server.close(force: true);
  });

  test('retries a temporary server error after a short pause', () async {
    statuses = [HttpStatus.serviceUnavailable, HttpStatus.ok];

    final channels = await source.channels();

    expect(channels.single.name, 'Recovered channel');
    expect(requests, hasLength(2));
    expect(requests[1], requests[0]);
    expect(
      requestTimes[1] - requestTimes[0],
      greaterThanOrEqualTo(const Duration(milliseconds: 550)),
    );
  });

  test('retries a truncated playlist without caching partial data', () async {
    interruptedResponses = 1;

    final channels = await source.channels();

    expect(channels.single.name, 'Recovered channel');
    expect(requests, hasLength(2));
  });

  test('stops after two server errors', () async {
    statuses = [HttpStatus.serviceUnavailable];

    await expectLater(source.channels(), throwsA(isA<StateError>()));

    expect(requests, hasLength(2));
  });

  test('does not retry rejected credentials', () async {
    statuses = [HttpStatus.unauthorized];

    await expectLater(
      source.channels(),
      throwsA(isA<ProviderRequestBlocked>()),
    );

    expect(requests, hasLength(1));
  });

  test('a manual retry after HTTP 403 reaches the provider again', () async {
    statuses = [HttpStatus.forbidden, HttpStatus.ok];

    await expectLater(
      source.channels(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'status',
          contains('HTTP 403'),
        ),
      ),
    );
    expect(requests, hasLength(1));

    expect((await source.channels()).single.name, 'Recovered channel');
    expect(requests, hasLength(2));
  });

  test(
    'rejects an HTTP 200 error page without caching an empty catalog',
    () async {
      responseBody = '<html><body>Provider is unavailable</body></html>';

      await expectLater(source.channels(), throwsA(isA<FormatException>()));
      expect(requests, hasLength(1));

      responseBody = null;
      expect((await source.channels()).single.name, 'Recovered channel');
      expect(requests, hasLength(2));
    },
  );

  test('shares a 429 cooldown across source instances', () async {
    statuses = [HttpStatus.tooManyRequests];
    final replacement = M3uSource(
      sourceId: 'replacement',
      playlistUrl: 'http://127.0.0.1:${server.port}/other.m3u',
    );
    addTearDown(replacement.dispose);

    await expectLater(
      source.channels(),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    await expectLater(
      replacement.categories(),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    expect(requests, hasLength(1));
  });

  test('coalesces concurrent playlist parsing', () async {
    final results = await Future.wait([
      source.channels(),
      source.categories(),
      source.channels(),
    ]);

    expect(results.every((items) => items.length == 1), isTrue);
    expect(requests, hasLength(1));
  });

  test('an invalidated parse cannot publish over its replacement', () async {
    firstRequestStarted = Completer<void>();
    releaseFirstResponse = Completer<void>();
    final stale = expectLater(
      source.channels(),
      throwsA(isA<LoadCancelledException>()),
    );
    await firstRequestStarted!.future;
    source.invalidate();
    final replacement = source.channels();
    releaseFirstResponse!.complete();

    await stale;
    expect((await replacement).single.name, 'Recovered channel');
    expect(await source.categories(), hasLength(1));
    expect(requests, hasLength(2));
  });

  test('an invalidated queued parse never opens an HTTP request', () async {
    final uri = Uri.parse(source.playlistUrl);
    final release = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    Future<void> occupy(Completer<void> started) =>
        ProviderRequestGate.instance.run<void>(uri, () {
          started.complete();
          return release.future;
        });
    final first = occupy(firstStarted);
    final second = occupy(secondStarted);
    await Future.wait([firstStarted.future, secondStarted.future]);

    final stale = expectLater(
      source.channels(),
      throwsA(isA<LoadCancelledException>()),
    );
    source.invalidate();
    final replacement = source.channels();
    release.complete();

    await Future.wait([first, second, stale]);
    expect((await replacement).single.name, 'Recovered channel');
    expect(requests, hasLength(1));
  });

  test('disposing a pending parse cancels its result', () async {
    firstRequestStarted = Completer<void>();
    releaseFirstResponse = Completer<void>();
    final pending = expectLater(
      source.channels(),
      throwsA(isA<LoadCancelledException>()),
    );
    await firstRequestStarted!.future;
    skipFirstResponse = true;
    await source.dispose();
    releaseFirstResponse!.complete();

    await pending;
    await expectLater(
      source.channels(),
      throwsA(isA<LoadCancelledException>()),
    );
    expect(requests, hasLength(1));
  });

  test('shares the retry limit between body and HTTP failures', () async {
    interruptedResponses = 1;
    statuses = [HttpStatus.ok, HttpStatus.serviceUnavailable];

    await expectLater(source.channels(), throwsA(isA<StateError>()));

    expect(requests, hasLength(2));
  });
}
