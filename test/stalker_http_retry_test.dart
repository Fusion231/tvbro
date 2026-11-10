import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  late HttpServer server;
  late StalkerSource source;
  late String targetAction;
  late List<int> statuses;
  late List<Uri> requests;
  late List<Uri> allRequests;
  late List<Duration> requestTimes;
  late Stopwatch clock;
  late int interruptedResponses;
  late int invalidTokenResponses;
  Object? targetJs;
  String? tokenFailureMessage;
  String? redirectLocation;
  late Set<String> invalidOnceActions;
  Completer<void>? invalidRequestsReady;
  Completer<void>? renewedProfile;
  var delaySecondInvalid = false;

  setUp(() async {
    ProviderRequestGate.instance.debugReset();
    targetAction = '';
    statuses = [HttpStatus.ok];
    requests = [];
    allRequests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    invalidTokenResponses = 0;
    targetJs = null;
    tokenFailureMessage = null;
    redirectLocation = null;
    invalidOnceActions = {};
    invalidRequestsReady = null;
    renewedProfile = null;
    delaySecondInvalid = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      allRequests.add(request.uri);
      final action = request.uri.queryParameters['action'];
      if (invalidOnceActions.remove(action)) {
        if (invalidOnceActions.isEmpty) invalidRequestsReady!.complete();
        await invalidRequestsReady!.future;
        if (delaySecondInvalid && action == 'get_epg_info') {
          await renewedProfile!.future;
        }
        request.response.write(jsonEncode({'js': null}));
        await request.response.close();
        return;
      }
      if (action == 'get_profile' && renewedProfile?.isCompleted == false) {
        renewedProfile!.complete();
      }
      if (action == targetAction) {
        requests.add(request.uri);
        requestTimes.add(clock.elapsed);
        final index = requests.length - 1;
        if (redirectLocation != null) {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, redirectLocation!);
          await request.response.close();
          return;
        }
        if (index < interruptedResponses) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n'
            'Connection: close\r\n\r\n{',
          );
          await socket.close();
          return;
        }
        request.response.statusCode =
            statuses[index < statuses.length ? index : statuses.length - 1];
        if (index < invalidTokenResponses) {
          request.response.write(jsonEncode({
            'js': null,
            'error': ?tokenFailureMessage,
          }));
          await request.response.close();
          return;
        }
      }
      final Object js = switch (action) {
        'handshake' => {'token': 'test-token'},
        'get_genres' => [
          {'id': '1', 'title': 'Recovered category'},
        ],
        'get_all_channels' => {
          'data': [
            {
              'id': '1',
              'name': 'Recovered channel',
              'number': 1,
              'tv_genre_id': '1',
              'cmd': 'ffmpeg http://example.invalid/live.ts',
            },
          ],
        },
        'get_epg_info' => {
          '1': [
            {
              'start_timestamp': '1000',
              'stop_timestamp': 2000,
              'name': 'Recovered programme',
              'descr': 'Details',
            },
          ],
        },
        _ => <String, dynamic>{},
      };
      request.response.write(
        jsonEncode({
          'js': action == targetAction && targetJs != null ? targetJs : js,
        }),
      );
      await request.response.close();
    });
    source = StalkerSource(
      sourceId: 'test',
      portal: 'http://127.0.0.1:${server.port}/',
      mac: '00:1A:79:12:34:56',
      diagnostics: false,
    );
    await source.connect();
  });

  tearDown(() async {
    await source.dispose();
    await server.close(force: true);
  });

  for (final delayed in [false, true]) {
    test('different stale-token reads share one renewal (delayed=$delayed)', () async {
      invalidOnceActions = {'get_genres', 'get_epg_info'};
      invalidRequestsReady = Completer<void>();
      renewedProfile = Completer<void>();
      delaySecondInvalid = delayed;
      final results = await Future.wait([source.categories(), source.epg(const [])]);
      expect(results.every((result) => result.isNotEmpty), isTrue);
      int count(String action) => allRequests
          .where((uri) => uri.queryParameters['action'] == action).length;
      expect(count('handshake'), 2);
      expect(count('get_profile'), 2);
      expect(count('get_genres'), 2);
      expect(count('get_epg_info'), 2);
    });
  }

  test('exhausted handshake HTTP 500 stops discovery instead of probing other paths', () async {
    targetAction = 'handshake';
    statuses = [500];
    final fresh = StalkerSource(
      sourceId: 'fresh',
      portal: 'http://127.0.0.1:${server.port}/',
      mac: '00:1A:79:12:34:56',
      diagnostics: false,
    );
    addTearDown(fresh.dispose);
    await expectLater(fresh.connect(), throwsA(isA<StalkerException>()));
    expect(requests, hasLength(3));
    expect(requests.map((uri) => uri.path).toSet(), hasLength(1));
  });

  test(
    'series search preserves an exhausted server error without VOD fallback',
    () async {
      targetAction = 'get_ordered_list';
      statuses = [HttpStatus.serviceUnavailable];

      await expectLater(
        source.searchMedia(ContentKind.series, 'Example'),
        throwsA(
          isA<StalkerException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 503'),
          ),
        ),
      );

      expect(requests, hasLength(3));
      expect(
        requests.every((uri) => uri.queryParameters['type'] == 'series'),
        isTrue,
      );
    },
  );

  for (final phase in ['details', 'seasons']) {
    test(
      '$phase preserves exhausted server errors instead of empty metadata',
      () async {
        targetAction = 'get_movie_details';
        statuses = [HttpStatus.serviceUnavailable];
        const item = MediaItem(
          id: '42',
          title: 'Example',
          kind: ContentKind.series,
        );

        await expectLater(
          phase == 'details'
              ? source.mediaDetails(item)
              : source.mediaItemsPage(ContentKind.season, parent: item),
          throwsA(
            isA<StalkerException>().having(
              (error) => error.message,
              'message',
              contains('HTTP 503'),
            ),
          ),
        );

        expect(requests, hasLength(3));
      },
    );
  }

  test('unsupported details endpoint still keeps list metadata', () async {
    targetAction = 'get_movie_details';
    statuses = [HttpStatus.notFound];
    const item = MediaItem(
      id: '42',
      title: 'Example',
      kind: ContentKind.series,
    );

    expect(await source.mediaDetails(item), same(item));
    expect(requests, hasLength(1));
  });

  for (final action in ['get_genres', 'get_all_channels', 'get_epg_info']) {
    group(action, () {
      Future<List<String>> load() async => switch (action) {
        'get_genres' => (await source.categories()).map((c) => c.title).toList(),
        'get_epg_info' => (await source.epg(const [])).map((p) => p.title).toList(),
        _ => (await source.channels()).map((c) => c.name).toList(),
      };

      final expectedName = action == 'get_genres'
          ? 'Recovered category'
          : action == 'get_epg_info'
          ? 'Recovered programme'
          : 'Recovered channel';

      test('retries a temporary server error after a short pause', () async {
        targetAction = action;
        statuses = [HttpStatus.serviceUnavailable, HttpStatus.ok];

        expect(await load(), [expectedName]);

        expect(requests, hasLength(2));
        expect(requests[1], requests[0]);
        expect(
          requestTimes[1] - requestTimes[0],
          greaterThanOrEqualTo(const Duration(milliseconds: 550)),
        );
      });

      test('retries an interrupted response body', () async {
        targetAction = action;
        interruptedResponses = 1;

        expect(await load(), [expectedName]);

        expect(requests, hasLength(2));
        expect(requests[1], requests[0]);
      });

      test('stops after three interrupted response bodies', () async {
        targetAction = action;
        interruptedResponses = 3;

        await expectLater(load(), throwsA(isA<HttpException>()));

        expect(requests, hasLength(3));
      });

      for (final status in [HttpStatus.unauthorized, HttpStatus.tooManyRequests]) {
        test('stops HTTP $status without catalog or auth fallback', () async {
          targetAction = action;
          statuses = [status];
          allRequests.clear();

          await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()));
          await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()));

          expect(requests, hasLength(1));
          expect(allRequests, hasLength(1));
        });
      }

      for (final logical in [false, true]) {
        test('manual retry after ${logical ? 'logical' : 'HTTP'} 403 reaches $action again', () async {
          targetAction = action;
          statuses = logical ? [HttpStatus.ok] : [HttpStatus.forbidden, HttpStatus.ok];
          if (logical) targetJs = {'error': 'Your MAC is banned'};
          allRequests.clear();

          await expectLater(load(), throwsA(isA<StalkerException>().having(
            (error) => error.message, 'status', contains('HTTP 403'))));
          expect(requests, hasLength(1));
          expect(allRequests, hasLength(1));

          targetJs = null;
          expect(await load(), [expectedName]);
          expect(requests, hasLength(2));
        });
      }

      for (final refusal in [
        (js: {'error': 'Authorization failed'}, status: HttpStatus.unauthorized),
        (js: {'auth': false}, status: HttpStatus.unauthorized),
        (js: {'error': 'Invalid credentials'}, status: HttpStatus.unauthorized),
        (js: {'error': 'Too many requests'}, status: HttpStatus.tooManyRequests),
      ]) {
        test('HTTP 200 ${refusal.js} stops without catalog or auth fallback', () async {
          targetAction = action;
          targetJs = refusal.js;
          allRequests.clear();
          await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()
              .having((error) => error.status, 'status', refusal.status)));
          await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()));
          expect(requests, hasLength(1));
          expect(allRequests, hasLength(1));
        });
      }

      test('a stale token can renew once and recover', () async {
        targetAction = action;
        invalidTokenResponses = 1;
        tokenFailureMessage = 'Invalid token: authorization denied';
        allRequests.clear();
        expect(await load(), [expectedName]);
        expect(requests, hasLength(2));
        expect(allRequests.map((request) => request.queryParameters['action']), [
          action, 'handshake', 'get_profile', action,
          if (action == 'get_all_channels') 'get_genres',
        ]);
      });

      test('a second stale token pauses the host instead of another fallback', () async {
        targetAction = action;
        invalidTokenResponses = 2;
        allRequests.clear();
        await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()));
        await expectLater(load(), throwsA(isA<ProviderRequestBlocked>()));
        expect(requests, hasLength(2));
        expect(allRequests, hasLength(4));
      });
    });
  }

  for (final js in [
    {'error': 'Authorization failed'},
    {'error': 'Invalid credentials'},
    {'error': 'MAC not registered'},
    {'auth': 0},
    {'error': 'Rate limit exceeded'},
  ]) {
    test('HTTP 200 $js ends endpoint discovery after one request', () async {
      targetAction = 'handshake';
      targetJs = js;
      allRequests.clear();
      final replacement = StalkerSource(
        sourceId: 'replacement',
        portal: 'http://127.0.0.1:${server.port}/c/',
        mac: '00:1A:79:65:43:21', diagnostics: false,
      );
      addTearDown(replacement.dispose);
      await expectLater(replacement.connect(), throwsA(isA<ProviderRequestBlocked>()));
      await expectLater(replacement.connect(), throwsA(isA<ProviderRequestBlocked>()));
      expect(requests, hasLength(1));
      expect(allRequests, hasLength(1));
    });
  }

  for (final action in ['get_all_channels', 'get_epg_info']) {
    test('large $action worker preserves logical refusal status', () async {
      targetAction = action;
      targetJs = {'error': 'Authorization failed', 'padding': 'x' * (256 * 1024)};
      allRequests.clear();
      await expectLater(
        action == 'get_all_channels' ? source.channels() : source.epg(const []),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      expect(requests, hasLength(1));
      expect(allRequests, hasLength(1));
    });
  }

  test('redirected HTTP 200 refusal blocks original and destination hosts', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => destination.close(force: true));
    var destinationRequests = 0;
    destination.listen((request) async {
      destinationRequests++;
      request.response.write('{"js":{"error":"Authorization failed"}}');
      await request.response.close();
    });
    targetAction = 'get_genres';
    redirectLocation = 'http://localhost:${destination.port}/portal.php';
    final direct = StalkerSource(
      sourceId: 'destination', portal: 'http://localhost:${destination.port}/c/',
      mac: '00:1A:79:65:43:21', diagnostics: false,
    );
    addTearDown(direct.dispose);
    allRequests.clear();
    await expectLater(source.categories(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(source.categories(), throwsA(isA<ProviderRequestBlocked>()));
    await expectLater(direct.connect(), throwsA(isA<ProviderRequestBlocked>()));
    expect(allRequests, hasLength(1));
    expect(destinationRequests, 1);
  });

  for (final status in [HttpStatus.unauthorized, HttpStatus.tooManyRequests]) {
    test('stops endpoint discovery after HTTP $status', () async {
      targetAction = 'handshake';
      statuses = [status];
      allRequests.clear();
      final replacement = StalkerSource(
        sourceId: 'replacement',
        portal: 'http://127.0.0.1:${server.port}/c/',
        mac: '00:1A:79:65:43:21',
        diagnostics: false,
      );
      addTearDown(replacement.dispose);

      await expectLater(
        replacement.connect(),
        throwsA(isA<ProviderRequestBlocked>()),
      );
      await expectLater(
        replacement.connect(),
        throwsA(isA<ProviderRequestBlocked>()),
      );

      expect(requests, hasLength(1));
      expect(allRequests, hasLength(1));
    });
  }

  for (final logical in [false, true]) {
    test('manual endpoint discovery after ${logical ? 'logical' : 'HTTP'} 403 sends a new handshake', () async {
      targetAction = 'handshake';
      statuses = logical ? [HttpStatus.ok] : [HttpStatus.forbidden, HttpStatus.ok];
      if (logical) targetJs = {'error': 'Account banned'};
      allRequests.clear();
      final replacement = StalkerSource(
        sourceId: 'replacement',
        portal: 'http://127.0.0.1:${server.port}/c/',
        mac: '00:1A:79:65:43:21', diagnostics: false,
      );
      addTearDown(replacement.dispose);

      await expectLater(replacement.connect(), throwsA(isA<StalkerException>().having(
        (error) => error.message, 'status', contains('HTTP 403'))));
      expect(requests, hasLength(1));
      expect(allRequests, hasLength(1));

      targetJs = null;
      await replacement.connect();
      expect(requests, hasLength(2));
      expect(allRequests, hasLength(3));
    });
  }

  test('large ordinary JSON responses retain category mapping', () async {
    targetAction = 'get_genres';
    targetJs = [
      for (var i = 0; i < 4000; i++)
        {'id': '$i', 'title': 'Category $i ${'x' * 80}'},
    ];
    expect(
      utf8.encode(jsonEncode({'js': targetJs})).length,
      greaterThan(256 * 1024),
    );
    final categories = await source.categories();
    expect(categories, hasLength(4000));
    expect(categories.last.id, '3999');
  });

  test('large portal EPG maps programmes and skips malformed rows', () async {
    targetAction = 'get_epg_info';
    targetJs = {
      'data': {
        '42': [
          for (var i = 0; i < 4000; i++)
            {
              'start_timestamp': '${1000 + i}',
              'stop_timestamp': 2000 + i,
              'name': 'Programme $i',
              'descr': 'x' * 80,
            },
          null,
          {'start_timestamp': 'invalid', 'stop_timestamp': 2000},
        ],
      },
    };
    expect(
      utf8.encode(jsonEncode({'js': targetJs})).length,
      greaterThan(256 * 1024),
    );
    final programmes = await source.epg(const []);
    expect(programmes, hasLength(4000));
    expect(programmes.last.channelId, '42');
    expect(programmes.last.title, 'Programme 3999');
    expect(programmes.first.start.millisecondsSinceEpoch, 1000000);
  });

  test('portal EPG reauthenticates once after an invalid token', () async {
    targetAction = 'get_epg_info';
    invalidTokenResponses = 1;
    final programmes = await source.epg(const <Channel>[]);
    expect(programmes.single.title, 'Recovered programme');
    expect(requests, hasLength(2));
  });

  test('does not retry rejected credentials', () async {
    targetAction = 'get_genres';
    statuses = [HttpStatus.unauthorized];

    await expectLater(
      source.categories(),
      throwsA(isA<ProviderRequestBlocked>()),
    );

    expect(requests, hasLength(1));
  });
}
