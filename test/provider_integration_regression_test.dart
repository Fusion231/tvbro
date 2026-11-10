import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUp(() => ProviderRequestGate.instance.debugReset());
  test(
    'special-character credentials survive XMLTV and playback locators',
    () async {
      const password = 'fixture&part#tail';
      final requests = <Uri>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request.uri);
        if (request.uri.path == '/player_api.php') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'user_info': {
                'auth': 1,
                'status': 'Active',
                'max_connections': '1',
              },
            }),
          );
        } else {
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write('<tv></tv>');
        }
        await request.response.close();
      });
      final source = XtreamSource(
        sourceId: 'credential-audit',
        host: 'http://127.0.0.1:${server.port}',
        username: 'fixture-user',
        password: password,
      );
      addTearDown(source.dispose);
      await source.connect();
      expect(requests.single.queryParameters['password'], password);
      await source.epg([
        const Channel(
          id: '7',
          name: 'Seven',
          extra: {'epg_channel_id': 'seven'},
        ),
      ]);
      final xmltv = requests.singleWhere((uri) => uri.path == '/xmltv.php');
      expect(xmltv.queryParameters['password'], password);
      final live = Uri.parse(
        (await source.resolve(const Channel(id: '7', name: 'Seven'))).url,
      );
      final episode = Uri.parse(
        (await source.resolveMedia(
          const MediaItem(
            id: '8',
            title: 'Episode',
            kind: ContentKind.episode,
            extra: {'container_extension': 'mkv'},
          ),
        )).url,
      );
      expect(live.fragment, isEmpty);
      expect(live.pathSegments, ['live', 'fixture-user', password, '7.ts']);
      expect(episode.fragment, isEmpty);
      expect(episode.pathSegments, [
        'series',
        'fixture-user',
        password,
        '8.mkv',
      ]);
    },
  );
  test(
    'movie_data container extension is used when root extension is absent',
    () async {
      final source = XtreamSource(
        sourceId: 'extension-audit',
        host: 'http://fixture.invalid',
        username: 'u',
        password: 'p',
        debugApi: (_) async => {
          'info': {'name': 'Movie'},
          'movie_data': {'stream_id': 7, 'container_extension': 'mkv'},
        },
      );
      addTearDown(source.dispose);
      final details = await source.mediaDetails(
        const MediaItem(id: '7', title: 'Movie', kind: ContentKind.movie),
      );
      final stream = await source.resolveMedia(details);
      expect(
        (details.extra['details'] as Map)['movie_data']['container_extension'],
        'mkv',
      );
      expect(Uri.parse(stream.url).path, endsWith('/7.mkv'));
    },
  );
}
