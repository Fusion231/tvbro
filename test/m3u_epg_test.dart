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
        extraEpgUrls: [server.guideUrl],
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

  test('a parsed playlist without any guide reports EPG unavailable', () async {
    server.headerGuide = false;
    final source = M3uSource(sourceId: 'm3u', playlistUrl: server.playlistUrl);
    addTearDown(source.dispose);

    expect(source.sourceCapabilities.epg, CapabilityAvailability.unknown);
    await source.channels();
    expect(source.sourceCapabilities.epg, CapabilityAvailability.unavailable);
    expect(await source.epg(await source.channels()), isEmpty);
    expect(server.guideRequests, 0);
  });

  test(
    'a new source discovers the header while refreshing cached channels',
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

      expect(server.playlistRequests, 2);
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
      await repo.load();
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
  bool failPlaylist = false;
  String playlistTvgId = 'guide-one';
  String programmeTitle = 'First guide';
  int playlistRequests = 0;
  int guideRequests = 0;

  String get playlistUrl => 'http://127.0.0.1:${_server.port}/playlist.m3u';
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
      switch (request.uri.path) {
        case '/playlist.m3u':
          playlistRequests++;
          if (failPlaylist) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
            break;
          }
          request.response.write(
            '#EXTM3U${headerGuide ? ' url-tvg="$guideUrl"' : ''}\n'
            '#EXTINF:-1 tvg-id="$playlistTvgId",Guide One HD\n'
            'http://stream.example.invalid/one.ts\n',
          );
        case '/guide.xml':
          guideRequests++;
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
