import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  late HttpServer server;
  late XtreamSource source;
  late List<int> statuses;
  late List<Uri> requests;
  late List<Duration> requestTimes;
  late Stopwatch clock;
  late int interruptedResponses;
  late String body;

  setUp(() async {
    statuses = [HttpStatus.ok];
    requests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    body = '[{"category_id":"1","category_name":"Series"}]';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      requestTimes.add(clock.elapsed);
      final index = requests.length - 1;
      if (index < interruptedResponses) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n'
          'Connection: close\r\n\r\n[',
        );
        await socket.close();
        return;
      }
      request.response.statusCode =
          statuses[index < statuses.length ? index : statuses.length - 1];
      request.response.write(body);
      await request.response.close();
    });
    source = XtreamSource(
      sourceId: 'test',
      host: 'http://127.0.0.1:${server.port}',
      username: 'private-user',
      password: 'private-password',
    );
  });

  tearDown(() async {
    await source.dispose();
    await server.close(force: true);
  });

  test('loads series categories after one temporary HTTP 404', () async {
    statuses = [HttpStatus.notFound, HttpStatus.ok];

    final categories = await source.mediaCategories(ContentKind.series);

    expect(categories.single.title, 'Series');
    expect(requests, hasLength(2));
    expect(requests[1], requests[0]);
    expect(requests[0].path, '/player_api.php');
    expect(requests[0].queryParameters['action'], 'get_series_categories');
    expect(
      requestTimes[1] - requestTimes[0],
      greaterThanOrEqualTo(const Duration(milliseconds: 550)),
    );
  });

  for (final status in [408, 429, 500, 502, 503, 504]) {
    test('loads movie details after temporary HTTP $status', () async {
      statuses = [status, HttpStatus.ok];
      body = '{"info":{"plot":"Recovered details"}}';

      final details = await source.mediaDetails(
        const MediaItem(id: '12', title: 'Movie', kind: ContentKind.movie),
      );

      expect(details.description, 'Recovered details');
      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expect(requests[0].queryParameters['action'], 'get_vod_info');
    });
  }

  test('retries a response interrupted while reading its body', () async {
    interruptedResponses = 1;

    final categories = await source.mediaCategories(ContentKind.series);

    expect(categories.single.title, 'Series');
    expect(requests, hasLength(2));
    expect(
      requestTimes[1] - requestTimes[0],
      greaterThanOrEqualTo(const Duration(milliseconds: 550)),
    );
  });

  test('stops after two interrupted responses', () async {
    interruptedResponses = 2;

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<HttpException>()),
    );
    expect(requests, hasLength(2));
  });

  test('stops after two HTTP 503 responses', () async {
    statuses = [HttpStatus.serviceUnavailable];

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<StateError>()),
    );
    expect(requests, hasLength(2));
  });

  test('shares the retry limit between body and HTTP failures', () async {
    interruptedResponses = 1;
    statuses = [HttpStatus.ok, HttpStatus.serviceUnavailable];

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<StateError>()),
    );
    expect(requests, hasLength(2));
  });

  test('does not retry invalid JSON', () async {
    body = 'invalid JSON';

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<FormatException>()),
    );
    expect(requests, hasLength(1));
  });

  test('loads a series catalog after one temporary HTTP 404', () async {
    statuses = [HttpStatus.notFound, HttpStatus.ok];
    body = '[{"series_id":12,"name":"Recovered series"}]';

    final page = await source.mediaItemsPage(
      ContentKind.series,
      categoryId: '1',
    );

    expect(page.items.single.title, 'Recovered series');
    expect(requests, hasLength(2));
    expect(requests[1], requests[0]);
    expect(requests[0].queryParameters['action'], 'get_series');
  });

  test(
    'stops after a second 404 and keeps credentials out of errors',
    () async {
      statuses = [HttpStatus.notFound];

      await expectLater(
        source.mediaCategories(ContentKind.series),
        throwsA(
          isA<StateError>()
              .having(
                (error) => error.toString(),
                'status',
                contains('HTTP 404'),
              )
              .having(
                (error) => error.toString(),
                'username',
                isNot(contains('private-user')),
              )
              .having(
                (error) => error.toString(),
                'password',
                isNot(contains('private-password')),
              ),
        ),
      );
      expect(requests, hasLength(2));
    },
  );

  for (final status in [
    HttpStatus.unauthorized,
    HttpStatus.forbidden,
    HttpStatus.gone,
  ]) {
    test('does not retry HTTP $status', () async {
      statuses = [status];

      await expectLater(
        source.mediaCategories(ContentKind.series),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'status',
            contains('HTTP $status'),
          ),
        ),
      );
      expect(requests, hasLength(1));
    });
  }
}
