import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/m3u_source.dart';

void main() {
  late HttpServer server;
  late M3uSource source;
  late List<int> statuses;
  late List<Uri> requests;
  late List<Duration> requestTimes;
  late Stopwatch clock;
  late int interruptedResponses;

  setUp(() async {
    statuses = [HttpStatus.ok];
    requests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      requestTimes.add(clock.elapsed);
      final index = requests.length - 1;
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
        '#EXTM3U\n'
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

    await expectLater(source.channels(), throwsA(isA<StateError>()));

    expect(requests, hasLength(1));
  });

  test('shares the retry limit between body and HTTP failures', () async {
    interruptedResponses = 1;
    statuses = [HttpStatus.ok, HttpStatus.serviceUnavailable];

    await expectLater(source.channels(), throwsA(isA<StateError>()));

    expect(requests, hasLength(2));
  });
}
