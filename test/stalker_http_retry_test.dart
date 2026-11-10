import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/stalker_source.dart';

void main() {
  late HttpServer server;
  late StalkerSource source;
  late String targetAction;
  late List<int> statuses;
  late List<Uri> requests;
  late List<Duration> requestTimes;
  late Stopwatch clock;
  late int interruptedResponses;
  late int invalidTokenResponses;
  Object? targetJs;

  setUp(() async {
    targetAction = '';
    statuses = [HttpStatus.ok];
    requests = [];
    requestTimes = [];
    clock = Stopwatch()..start();
    interruptedResponses = 0;
    invalidTokenResponses = 0;
    targetJs = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final action = request.uri.queryParameters['action'];
      if (action == targetAction) {
        requests.add(request.uri);
        requestTimes.add(clock.elapsed);
        final index = requests.length - 1;
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
          request.response.write(jsonEncode({'js': null}));
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

    await expectLater(source.categories(), throwsA(isA<StalkerException>()));

    expect(requests, hasLength(1));
  });
}
