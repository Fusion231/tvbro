import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  // This suite uses only its own loopback server, not widget HTTP mocks.
  HttpOverrides.global = null;

  late _GuideServer server;

  setUp(() async => server = await _GuideServer.start());
  tearDown(() => server.close());

  for (final batched in [false, true]) {
    test('one additional guide without a primary matches channel names '
        '(${batched ? 'batched' : 'unbatched'})', () async {
      server.headerGuide = false;
      server.playlistTvgId = 'provider-specific';
      final source = M3uSource(
        sourceId: 'm3u',
        playlistUrl: server.playlistUrl,
        extraEpgUrls: [server.guideUrl, server.guideUrl],
      );
      addTearDown(source.dispose);
      final channels = await source.channels();

      final programmes = batched
          ? (await source.epgBatched(channels)!.toList())
                .expand((batch) => batch)
                .toList()
          : await source.epg(channels);

      expect(programmes.single.channelId, channels.single.id);
      expect(programmes.single.title, 'First guide');
      expect(server.guideRequests, 1);
    });
  }

  test('a header primary retains exact tvg-id matching', () async {
    server.playlistTvgId = 'provider-specific';
    final source = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
    addTearDown(source.dispose);

    expect(await source.epg(await source.channels()), isEmpty);
    expect(server.guideRequests, 1);
  });

  for (final exactId in [true, false]) {
    test('header guide lists fetch separate deduplicated bounded URLs '
        'with ${exactId ? 'matching' : 'unmatched'} tvg-ids', () async {
      final origin = Uri.parse(server.guideUrl).resolve('/');
      String guide(int index) => origin.resolve('guide-$index.xml').toString();
      server.playlistHeader =
          'url-tvg="${guide(1)},${guide(2)}" '
          'x-tvg-url="${guide(2)} ${guide(3)}" '
          'tvg-url="${guide(4)},${guide(5)}"';
      server.playlistTvgId = exactId ? 'guide-one' : 'provider-specific';
      final source = M3uSource(
        sourceId: 'header-list',
        playlistUrl: server.playlistUrl,
      );
      addTearDown(source.dispose);
      final channels = await source.channels();

      final programmes = await source.epg(channels);

      expect(server.guidePaths, [
        '/guide-1.xml',
        '/guide-2.xml',
        '/guide-3.xml',
        '/guide-4.xml',
      ]);
      expect(server.guideRequests, 4);
      expect(programmes, exactId ? hasLength(1) : isEmpty);
      if (exactId) expect(programmes.single.channelId, channels.single.id);
    });
  }

  test(
    'a redirected get.php guide uses final credentials and survives restart',
    () async {
      final destination = await _GuideServer.start();
      addTearDown(destination.close);
      destination.headerGuide = false;
      server.playlistRedirect = Uri.parse(destination.playlistUrl).replace(
        path: '/panel/get.php',
        queryParameters: {'username': 'final-user', 'password': 'final-pass'},
      );
      final first = M3uSource(
        sourceId: 'redirected-get',
        playlistUrl: server.credentialPlaylistUrl,
      );
      addTearDown(first.dispose);
      final channels = await first.channels();

      expect((await first.epg(channels)).single.title, 'First guide');
      await first.dispose();
      final restarted = M3uSource(
        sourceId: 'redirected-get',
        playlistUrl: server.credentialPlaylistUrl,
      );
      addTearDown(restarted.dispose);
      expect((await restarted.epg(channels)).single.title, 'First guide');

      expect(server.playlistRequests, 1);
      expect(server.guideRequests, 0);
      expect(destination.playlistRequests, 1);
      expect(destination.guidePaths, ['/panel/xmltv.php', '/panel/xmltv.php']);
      expect(
        destination.guideParameters,
        everyElement({'username': 'final-user', 'password': 'final-pass'}),
      );
    },
  );

  test('relative header guides use the final playlist base after redirect and restart', () async {
    final destination = await _GuideServer.start();
    addTearDown(destination.close);
    destination.playlistHeader = 'tvg-url="guide.xml"';
    server.playlistRedirect = Uri.parse(destination.playlistUrl)
        .replace(path: '/panel/playlist.m3u');
    final first = M3uSource(
      sourceId: 'relative-guide',
      playlistUrl: server.playlistUrl,
    );
    addTearDown(first.dispose);
    final channels = await first.channels();

    expect((await first.epg(channels)).single.title, 'First guide');
    await first.dispose();
    final restarted = M3uSource(
      sourceId: 'relative-guide',
      playlistUrl: server.playlistUrl,
    );
    addTearDown(restarted.dispose);
    expect((await restarted.epg(channels)).single.title, 'First guide');

    expect(server.playlistRequests, 1);
    expect(server.guideRequests, 0);
    expect(destination.playlistRequests, 1);
    expect(destination.guidePaths, ['/panel/guide.xml', '/panel/guide.xml']);
  });

  test('a redirect without credentials does not forward original credentials to its origin', () async {
    final destination = await _GuideServer.start();
    addTearDown(destination.close);
    destination.headerGuide = false;
    server.playlistRedirect = Uri.parse(destination.playlistUrl)
        .replace(path: '/panel/get.php');
    final source = M3uSource(
      sourceId: 'redirect-no-credentials',
      playlistUrl: server.credentialPlaylistUrl,
    );
    addTearDown(source.dispose);

    expect(
      (await source.epg(await source.channels())).single.title,
      'First guide',
    );
    expect(server.guidePaths, ['/xmltv.php']);
    expect(server.guideParameters.single, {
      'username': 'user',
      'password': 'pass',
    });
    expect(destination.guideRequests, 0);
  });

  test('a credentialed get.php playlist without a header uses XMLTV', () async {
    server.headerGuide = false;
    final source = M3uSource(
      sourceId: 'm3u',
      playlistUrl: server.credentialPlaylistUrl,
    );
    addTearDown(source.dispose);
    final channels = await source.channels();

    final programmes = await source.epg(channels);

    expect(source.sourceCapabilities.epg, CapabilityAvailability.supported);
    expect(programmes.single.channelId, channels.single.id);
    expect(programmes.single.title, 'First guide');
    expect(server.playlistRequests, 1);
    expect(server.guideRequests, 1);
    expect(server.guidePaths, ['/xmltv.php']);
    expect(server.guideParameters.single, {
      'username': 'user',
      'password': 'pass',
    });
    expect(server.requestPaths, ['/get.php', '/xmltv.php']);
  });

  for (final explicit in [false, true]) {
    test(
      '${explicit ? 'explicit' : 'header'} guide wins over inferred XMLTV',
      () async {
        if (explicit) {
          final other = Uri.parse(server.guideUrl).resolve('/guide-2.xml');
          server.playlistHeader = 'url-tvg="${server.guideUrl},$other"';
        }
        final source = M3uSource(
          sourceId: 'm3u',
          playlistUrl: server.credentialPlaylistUrl,
          epgUrl: explicit ? '${server.guideUrl}?explicit=1' : null,
        );
        addTearDown(source.dispose);

        final programmes = await source.epg(await source.channels());

        expect(programmes.single.title, 'First guide');
        expect(server.guidePaths, ['/guide.xml']);
        expect(
          server.guideParameters.single,
          explicit ? {'explicit': '1'} : isEmpty,
        );
        expect(server.requestPaths, ['/get.php', '/guide.xml']);
      },
    );
  }

  test('a parsed playlist without any guide reports EPG unavailable', () async {
    server.headerGuide = false;
    final source = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
    addTearDown(source.dispose);

    expect(source.sourceCapabilities.epg, CapabilityAvailability.unknown);
    final channels = await source.channels();
    expect(source.sourceCapabilities.epg, CapabilityAvailability.unavailable);
    expect(await source.epg(channels), isEmpty);
    final rebuilt = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
    addTearDown(rebuilt.dispose);
    expect(await rebuilt.epg(channels), isEmpty);
    expect(rebuilt.sourceCapabilities.epg, CapabilityAvailability.unavailable);
    expect(server.playlistRequests, 1);
    expect(server.guideRequests, 0);
  });

  test(
    'a fresh cached source infers XMLTV despite its saved empty header',
    () async {
      server.headerGuide = false;
      final temp = await Directory.systemTemp.createTemp('iptvs_m3u_epg_');
      addTearDown(() => temp.delete(recursive: true));
      final db = await AppDatabase.openAt('${temp.path}/cache.db');
      addTearDown(db.close);
      final first = M3uSource(
        sourceId: 'm3u',
        playlistUrl: server.credentialPlaylistUrl,
      );
      addTearDown(first.dispose);
      final firstRepo = LibraryRepository(source: first, db: db);
      final cold = await firstRepo.load();
      await firstRepo.pendingEpgRefresh;
      await db.invalidateEpg('m3u');
      server.programmeTitle = 'Refreshed inferred guide';

      final fresh = M3uSource(
        sourceId: 'm3u',
        playlistUrl: server.credentialPlaylistUrl,
      );
      addTearDown(fresh.dispose);
      final repo = LibraryRepository(source: fresh, db: db);
      expect((await repo.load()).fromCache, isTrue);
      await repo.pendingEpgRefresh;

      expect(server.playlistRequests, 1);
      expect(server.guidePaths, ['/xmltv.php', '/xmltv.php']);
      expect(server.requestPaths, ['/get.php', '/xmltv.php', '/xmltv.php']);
      expect(fresh.sourceCapabilities.epg, CapabilityAvailability.supported);
      expect(
        (await db.nowNext(
          'm3u',
          server.now,
        )).now[cold.channels.single.id]?.title,
        'Refreshed inferred guide',
      );
      expect(repo.lastEpgRefreshFailed, isFalse);
    },
  );

  test(
    'a new source reuses the saved header while refreshing cached channels',
    () async {
      final temp = await Directory.systemTemp.createTemp('iptvs_m3u_epg_');
      addTearDown(() => temp.delete(recursive: true));
      final db = await AppDatabase.openAt('${temp.path}/cache.db');
      addTearDown(db.close);
      final first = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
      addTearDown(first.dispose);
      final firstRepo = LibraryRepository(source: first, db: db);
      final cold = await firstRepo.load();
      await firstRepo.pendingEpgRefresh;
      final channelId = cold.channels.single.id;
      expect(
        (await db.nowNext('m3u', server.now)).now[channelId]?.title,
        'First guide',
      );
      await db.invalidateEpg('m3u');
      server.programmeTitle = 'Refreshed guide';

      final fresh = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
      addTearDown(fresh.dispose);
      final repo = LibraryRepository(source: fresh, db: db);
      final cached = await repo.load();
      expect(cached.fromCache, isTrue);
      await repo.pendingEpgRefresh;

      expect(server.playlistRequests, 1);
      expect(server.guideRequests, 2);
      expect(
        (await db.nowNext('m3u', server.now)).now[channelId]?.title,
        'Refreshed guide',
      );
      expect(repo.lastEpgRefreshFailed, isFalse);
    },
  );

  test(
    'failed header discovery retains the previous guide and allows retry',
    () async {
      final temp = await Directory.systemTemp.createTemp('iptvs_m3u_epg_');
      addTearDown(() => temp.delete(recursive: true));
      final db = await AppDatabase.openAt('${temp.path}/cache.db');
      addTearDown(db.close);
      final first = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
      addTearDown(first.dispose);
      final firstRepo = LibraryRepository(source: first, db: db);
      final cold = await firstRepo.load();
      await firstRepo.pendingEpgRefresh;
      final channelId = cold.channels.single.id;
      await db.invalidateEpg('m3u');
      server.failPlaylist = true;
      // Simulate an older install with no persisted playlist header.
      FlutterSecureStorage.setMockInitialValues({});

      final fresh = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
      addTearDown(fresh.dispose);
      final repo = LibraryRepository(source: fresh, db: db);
      expect((await repo.load()).fromCache, isTrue);
      await repo.pendingEpgRefresh;

      expect(repo.lastEpgRefreshFailed, isTrue);
      expect(await db.lastEpgSynced('m3u'), isNull);
      expect(
        (await db.nowNext('m3u', server.now)).now[channelId]?.title,
        'First guide',
      );

      server.failPlaylist = false;
      server.programmeTitle = 'Retry guide';
      await repo.load(forceRefresh: true);
      await repo.pendingEpgRefresh;
      expect(repo.lastEpgRefreshFailed, isFalse);
      expect(
        (await db.nowNext('m3u', server.now)).now[channelId]?.title,
        'Retry guide',
      );
    },
  );
}

class _GuideServer {
  _GuideServer(this._server);

  final HttpServer _server;
  final DateTime now = DateTime.now().toUtc();
  bool headerGuide = true;
  String? playlistHeader;
  Uri? playlistRedirect;
  bool failPlaylist = false;
  String playlistTvgId = 'guide-one';
  String programmeTitle = 'First guide';
  int playlistRequests = 0;
  int guideRequests = 0;
  final requestPaths = <String>[];
  final guidePaths = <String>[];
  final guideParameters = <Map<String, String>>[];

  String get playlistUrl => 'http://127.0.0.1:${_server.port}/playlist.m3u';
  String get credentialPlaylistUrl =>
      'http://127.0.0.1:${_server.port}/get.php'
      '?username=user&password=pass&type=m3u_plus&output=ts';
  String get guideUrl => 'http://127.0.0.1:${_server.port}/guide.xml';

  static Future<_GuideServer> start() async {
    final fixture = _GuideServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture._server.listen(fixture._serve);
    return fixture;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      requestPaths.add(request.uri.path);
      switch (request.uri.path) {
        case '/playlist.m3u':
        case '/get.php':
        case '/panel/playlist.m3u':
        case '/panel/get.php':
          playlistRequests++;
          if (playlistRedirect != null) {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              playlistRedirect.toString(),
            );
            break;
          }
          if (failPlaylist) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            break;
          }
          request.response.write(
            '#EXTM3U ${playlistHeader ?? (headerGuide ? 'url-tvg="$guideUrl"' : '')}\n'
            '#EXTINF:-1 tvg-id="$playlistTvgId",Guide One HD\n'
            'http://stream.example.invalid/one.ts\n',
          );
        case '/guide.xml':
        case '/xmltv.php':
        case '/panel/guide.xml':
        case '/panel/xmltv.php':
        case final path when RegExp(r'^/guide-[1-5]\.xml$').hasMatch(path):
          guideRequests++;
          guidePaths.add(request.uri.path);
          guideParameters.add(request.uri.queryParameters);
          request.response.write(
            '<?xml version="1.0"?><tv>'
            '<channel id="guide-one"><display-name>Guide One</display-name>'
            '</channel><programme channel="guide-one" '
            'start="${_stamp(now.subtract(const Duration(hours: 1)))} +0000" '
            'stop="${_stamp(now.add(const Duration(hours: 1)))} +0000">'
            '<title>$programmeTitle</title></programme></tv>',
          );
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

String _stamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}'
    '${value.month.toString().padLeft(2, '0')}'
    '${value.day.toString().padLeft(2, '0')}'
    '${value.hour.toString().padLeft(2, '0')}'
    '${value.minute.toString().padLeft(2, '0')}'
    '${value.second.toString().padLeft(2, '0')}';
