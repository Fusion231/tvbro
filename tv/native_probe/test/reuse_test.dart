import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/provider_request_gate.dart';
import 'package:iptvs/data/secret_locator_vault.dart' show hasSealedLocator;
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/source_config.dart';
import 'package:iptvs/sources/source_identity.dart';
import 'package:iptvs/sources/stalker_source.dart';
import 'package:iptvs/sources/xtream_source.dart';

// This is a host-VM qualification entrypoint. Every package:iptvs import above
// resolves to the original app/lib file, as recorded by run.ps1.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Match the existing Flutter HTTP tests: allow only our real loopback server.
  HttpOverrides.global = null;

  setUp(() {
    ProviderRequestGate.instance.debugReset();
    // A host test double, not evidence of persistent TV secure storage.
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('original config factory builds every existing source kind', () async {
    final cases = <(SourceKind, Map<String, String>, Matcher)>[
      (SourceKind.demo, const {}, isA<DemoSource>()),
      (
        SourceKind.m3u,
        const {'playlistUrl': 'https://fixture.invalid/channels.m3u'},
        isA<M3uSource>(),
      ),
      (
        SourceKind.xtream,
        const {
          'host': 'https://fixture.invalid',
          'username': 'fixture-user',
          'password': 'fixture-password',
        },
        isA<XtreamSource>(),
      ),
      (
        SourceKind.stalker,
        const {
          'portal': 'https://fixture.invalid/c/',
          'mac': '00:1A:79:00:00:01',
        },
        isA<StalkerSource>(),
      ),
    ];
    for (final (kind, fields, matcher) in cases) {
      final config = SourceConfig(
        id: '11111111-1111-4111-8111-111111111111',
        kind: kind,
        label: '  Native reuse fixture  ',
        fields: fields,
        settings: const {
          'hiddenCategories': {
            'live': ['hidden'],
          },
        },
      );
      final restored = SourceConfig.fromJson(config.toJson());
      final source = restored.build();
      addTearDown(source.dispose);

      expect(source, matcher);
      expect(source.id, config.id);
      expect(source.name, 'Native reuse fixture');
      expect(restored.fields, fields);
      expect(restored.hiddenCategoryIds(ContentKind.live), {'hidden'});
    }
  });

  test('original M3U factory, repository, vault and SQLite cache execute', () async {
    final fixture = await _ProviderFixture.start();
    addTearDown(fixture.close);
    final config = SourceConfig(
      id: '22222222-2222-4222-8222-222222222222',
      kind: SourceKind.m3u,
      label: 'M3U reuse fixture',
      fields: {
        'playlistUrl': '${fixture.base}/fixture.m3u',
        'userAgent': 'TVBro-native-probe',
      },
    );
    final source = config.build();
    addTearDown(source.dispose);
    final directory = await Directory.current.createTemp('m3u-cache-');
    addTearDown(() => directory.delete(recursive: true));
    final db = await AppDatabase.openAt('${directory.path}/cache.db');
    addTearDown(db.close);
    final repo = LibraryRepository(source: source, db: db);

    final first = await repo.load();
    // Observe the repository's actual completion future, without polling.
    await repo.pendingEpgRefresh;
    expect(first.fromCache, isFalse);
    expect(first.categories.single.title, 'Wiadomości');
    expect(first.channels.map((channel) => channel.name), [
      'Kanał HD',
      'Kanał SD',
    ]);
    expect(first.channels.map((channel) => channel.id).toSet(), hasLength(2));
    expect(first.channels.map((channel) => channel.extra['tvgId']), [
      'fixture.news',
      'fixture.news',
    ]);
    expect(
      first.channels.first.id,
      stableM3uChannelId('HTTP://STREAMS.INVALID:80/live/hd.ts#ignored'),
    );
    expect(fixture.requests, ['/fixture.m3u']);
    expect(fixture.playlistUserAgent, 'TVBro-native-probe');

    final cached = await repo.load();
    await repo.pendingEpgRefresh;
    final cachedChannel = cached.channels.first;
    expect(cached.fromCache, isTrue);
    expect(cachedChannel.id, first.channels.first.id);
    expect(hasSealedLocator(cachedChannel.extra), isTrue);
    expect(cachedChannel.extra['url'], isNull);
    expect(db.vault.decryptCount, 0);
    final resolved = await repo.resolve(cachedChannel);
    expect(resolved.url, 'http://streams.invalid/live/hd.ts');
    expect(resolved.headers, {'User-Agent': 'TVBro-native-probe'});
    expect(db.vault.decryptCount, 1);

    // A fresh provider instance must browse the existing repository cache
    // without a provider request. Resolved media is never fetched by this test.
    fixture.offline = true;
    final freshSource = SourceConfig.fromJson(config.toJson()).build();
    addTearDown(freshSource.dispose);
    final freshRepo = LibraryRepository(source: freshSource, db: db);
    final offline = await freshRepo.load();
    await freshRepo.pendingEpgRefresh;
    expect(offline.fromCache, isTrue);
    expect(
      offline.channels.map((channel) => channel.id),
      cached.channels.map((channel) => channel.id),
    );
    expect(fixture.requests, ['/fixture.m3u']);
  });

  test(
    'original Xtream factory maps HTTP live, movie and series catalogs',
    () async {
      final fixture = await _ProviderFixture.start();
      addTearDown(fixture.close);
      final source = SourceConfig(
        id: '33333333-3333-4333-8333-333333333333',
        kind: SourceKind.xtream,
        label: 'Xtream reuse fixture',
        fields: {
          'host': fixture.base,
          'username': 'fixture-user',
          'password': 'fixture-password',
        },
        settings: const {'streamExtension': 'm3u8'},
      ).build();
      addTearDown(source.dispose);

      await source.connect();
      expect((await source.categories()).single.title, 'Wiadomości');
      final live = (await source.channels()).single;
      expect(live.id, '42');
      expect(live.categoryId, '7');
      expect(live.extra['streamId'], '42');
      expect(live.extra['tvgId'], 'fixture.news');
      expect(live.archiveDays, 3);
      expect(
        (await source.resolve(live)).url,
        '${fixture.base}/live/fixture-user/fixture-password/42.m3u8',
      );

      expect((await source.mediaCategories(ContentKind.movie)).single.id, '11');
      final movie = (await source.mediaItemsPage(
        ContentKind.movie,
        categoryId: '11',
      )).items.single;
      expect(movie.id, '71');
      expect(movie.title, 'Film próbny');
      expect(movie.kind, ContentKind.movie);
      expect(movie.categoryId, '11');
      final movieStream = await source.resolveMedia(movie);
      expect(
        movieStream.url,
        '${fixture.base}/movie/fixture-user/fixture-password/71.mkv',
      );
      expect(movieStream.isLive, isFalse);

      expect(
        (await source.mediaCategories(ContentKind.series)).single.id,
        '12',
      );
      final series = (await source.mediaItemsPage(
        ContentKind.series,
        categoryId: '12',
      )).items.single;
      expect(series.id, '91');
      expect(series.title, 'Serial próbny');
      expect(series.kind, ContentKind.series);
      expect(series.categoryId, '12');
      expect(fixture.requests, [
        'authenticate',
        'get_live_categories',
        'get_live_streams',
        'get_vod_categories',
        'get_vod_streams',
        'get_series_categories',
        'get_series',
      ]);
    },
  );
}

// Synthetic HTTP payloads only. Parsing, identities, state and playback URL
// construction remain exclusively in the imported TVBro implementation.
class _ProviderFixture {
  _ProviderFixture(this._server);

  final HttpServer _server;
  final requests = <String>[];
  String? playlistUserAgent;
  bool offline = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  static Future<_ProviderFixture> start() async {
    final fixture = _ProviderFixture(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture._server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    final action = request.uri.queryParameters['action'] ?? 'authenticate';
    requests.add(request.uri.path == '/fixture.m3u' ? '/fixture.m3u' : action);
    if (offline) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
    } else if (request.uri.path == '/fixture.m3u') {
      playlistUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
      request.response.write('''
#EXTM3U
#EXTINF:-1 tvg-id="fixture.news" group-title="Wiadomości",Kanał HD
http://streams.invalid/live/hd.ts
#EXTINF:-1 tvg-id="fixture.news" group-title="Wiadomości",Kanał SD
http://streams.invalid/live/sd.ts
''');
    } else if (request.uri.path == '/player_api.php') {
      final Object? payload = switch (action) {
        'authenticate' => {
          'user_info': {'auth': 1},
        },
        'get_live_categories' => [
          {'category_id': '7', 'category_name': 'Wiadomości'},
        ],
        'get_live_streams' => [
          {
            'stream_id': 42,
            'name': 'Kanał próbny',
            'category_id': '7',
            'epg_channel_id': 'fixture.news',
            'tv_archive': 1,
            'tv_archive_duration': 3,
          },
        ],
        'get_vod_categories' => [
          {'category_id': '11', 'category_name': 'Filmy'},
        ],
        'get_vod_streams' => [
          {
            'stream_id': 71,
            'name': 'Film próbny',
            'category_id': '11',
            'container_extension': 'mkv',
          },
        ],
        'get_series_categories' => [
          {'category_id': '12', 'category_name': 'Seriale'},
        ],
        'get_series' => [
          {'series_id': 91, 'name': 'Serial próbny', 'category_id': '12'},
        ],
        _ => null,
      };
      if (payload == null) request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}
