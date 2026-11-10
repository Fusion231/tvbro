import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
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
  String? retryAfter;
  String? redirectLocation;

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    statuses = [HttpStatus.ok];
    requests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    retryAfter = null;
    redirectLocation = null;
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
      if (retryAfter != null) {
        request.response.headers.set(HttpHeaders.retryAfterHeader, retryAfter!);
      }
      if (redirectLocation != null) {
        request.response.headers.set(
          HttpHeaders.locationHeader,
          redirectLocation!,
        );
      }
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

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    test(
      'cancelling a queued ${kind.name} bulk catalog opens no HTTP request',
      () async {
        final uri = Uri.parse(source.host);
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
        final token = LoadToken();
        final cancelled = expectLater(
          source
              .allMediaItems(kind, token: token)
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<LoadCancelledException>()),
        );
        try {
          await Future<void>.delayed(Duration.zero);
          token.cancel();
          await cancelled;
          expect(requests, isEmpty);
        } finally {
          release.complete();
          await Future.wait([first, second]);
        }
      },
    );

    test(
      'downloads the complete ${kind.name} catalog in one HTTP request',
      () async {
        body =
            '\n [{"stream_id":12,"series_id":34,"name":"Title",'
            '"category_id":"a"}]';

        final items = await source.allMediaItems(kind);

        expect(items.single.title, 'Title');
        expect(items.single.kind, kind);
        expect(items.single.categoryId, 'a');
        expect(requests, hasLength(1));
        expect(
          requests.single.queryParameters['action'],
          kind == ContentKind.movie ? 'get_vod_streams' : 'get_series',
        );
        expect(
          requests.single.queryParameters.containsKey('category_id'),
          isFalse,
        );
      },
    );
  }

  test(
    'invalid bulk HTTP payload cannot replace the catalog with an empty list',
    () async {
      body = '{"error":"catalog unavailable"}';

      await expectLater(
        source.allMediaItems(ContentKind.movie),
        throwsFormatException,
      );
      expect(requests, hasLength(1));
    },
  );

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

  for (final status in [408, 500, 502, 503, 504]) {
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

  test('shares a 429 cooldown across source instances and reloads', () async {
    statuses = [HttpStatus.tooManyRequests];
    final replacement = XtreamSource(
      sourceId: 'replacement',
      host: 'http://127.0.0.1:${server.port}',
      username: 'other-user',
      password: 'other-password',
    );
    addTearDown(replacement.dispose);

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    await expectLater(
      replacement.mediaCategories(ContentKind.movie),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    source.invalidate();
    await expectLater(
      source.channels(),
      throwsA(isA<ProviderRequestBlocked>()),
    );

    expect(requests, hasLength(1));
  });

  for (final auth in [0, '0', false, 'false']) {
    test('HTTP 200 auth=$auth pauses all requests after one refusal', () async {
      body = jsonEncode({'user_info': {'auth': auth}});
      final replacement = XtreamSource(
        sourceId: 'replacement',
        host: 'http://127.0.0.1:${server.port}',
        username: 'other-user', password: 'other-password',
      );
      addTearDown(replacement.dispose);
      await expectLater(source.connect(), throwsA(isA<ProviderRequestBlocked>()
          .having((error) => error.status, 'status', HttpStatus.unauthorized)));
      await expectLater(source.connect(), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(replacement.categories(), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(source.subscriptionExpiry(), throwsA(isA<ProviderRequestBlocked>()));
      expect(requests, hasLength(1));
    });
  }

  test(
    'malformed HTTP 200 account replies fail without pausing or caching',
    () async {
      body = '{"user_info":{}}';
      await expectLater(source.connect(), throwsFormatException);
      body = '{"user_info":{"auth":1,"status":"Active","exp_date":"0"}}';
      await source.connect();
      await source.connect();
      expect(requests, hasLength(2));
    },
  );

  test('HTTP 200 non-list live catalog is rejected without retry', () async {
    body = '{"error":"Temporarily unavailable"}';
    await expectLater(source.channels(), throwsFormatException);
    expect(requests, hasLength(1));
    body = '[]';
    expect(await source.channels(), isEmpty);
    expect(requests, hasLength(2));
  });

  test('HTTP 200 catalog auth refusal cannot become a successful empty cache', () async {
    body = '{"user_info":{"auth":false}}';
    await expectLater(source.channels(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(source.categories(), throwsA(isA<ProviderRequestBlocked>()));
    expect(requests, hasLength(1));
  });

  test('redirected HTTP 200 login refusal blocks original and destination hosts', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => destination.close(force: true));
    var destinationRequests = 0;
    destination.listen((request) async {
      destinationRequests++;
      request.response.write('{"user_info":{"auth":false}}');
      await request.response.close();
    });
    statuses = [HttpStatus.found];
    redirectLocation = 'http://localhost:${destination.port}/player_api.php';
    final direct = XtreamSource(
      sourceId: 'destination', host: 'http://localhost:${destination.port}',
      username: 'other-user', password: 'other-password',
    );
    addTearDown(direct.dispose);
    await expectLater(source.connect(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(source.categories(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(direct.categories(), throwsA(isA<ProviderRequestBlocked>()));
    expect(requests, hasLength(1));
    expect(destinationRequests, 1);
  });

  test('honors a provider Retry-After without an immediate retry', () async {
    statuses = [HttpStatus.serviceUnavailable];
    retryAfter = '120';

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    expect(requests, hasLength(1));
  });

  test('a redirected 429 blocks both original and destination hosts', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => destination.close(force: true));
    var destinationRequests = 0;
    destination.listen((request) async {
      destinationRequests++;
      request.response.statusCode = HttpStatus.tooManyRequests;
      await request.response.close();
    });
    statuses = [HttpStatus.found];
    redirectLocation = 'http://localhost:${destination.port}/player_api.php';
    final direct = XtreamSource(
      sourceId: 'destination',
      host: 'http://localhost:${destination.port}',
      username: 'other-user',
      password: 'other-password',
    );
    addTearDown(direct.dispose);

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    await expectLater(
      source.channels(),
      throwsA(isA<ProviderRequestBlocked>()),
    );
    await expectLater(
      direct.channels(),
      throwsA(isA<ProviderRequestBlocked>()),
    );

    expect(requests, hasLength(1));
    expect(destinationRequests, 1);
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
          (status != HttpStatus.unauthorized
                  ? isA<StateError>()
                  : isA<ProviderRequestBlocked>())
              .having(
                (error) => error.toString(),
                'status',
                contains('HTTP $status'),
              ),
        ),
      );
      expect(requests, hasLength(1));
    });
  }

  test('a manual retry after HTTP 403 reaches the provider again', () async {
    statuses = [HttpStatus.forbidden, HttpStatus.ok];
    retryAfter = '3600';

    await expectLater(
      source.mediaCategories(ContentKind.series),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'status',
          contains('HTTP 403'),
        ),
      ),
    );
    expect(requests, hasLength(1));

    expect(await source.mediaCategories(ContentKind.series), hasLength(1));
    expect(requests, hasLength(2));
  });
}
