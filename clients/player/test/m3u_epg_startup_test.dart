import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/m3u_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached M3U startup keeps header discovery alive during daily catalog refresh',
    () => HttpOverrides.runWithHttpOverrides(() async {
      FlutterSecureStorage.setMockInitialValues({});
      ProviderRequestGate.instance.debugReset();
      final directory = await Directory.systemTemp.createTemp('m3u_epg_startup_');
      final db = await AppDatabase.openAt('${directory.path}/library.db');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstPlaylistStarted = Completer<void>();
      final releaseFirstPlaylist = Completer<void>();
      final catalogPlaylistStarted = Completer<void>();
      var playlistRequests = 0;
      var guideRequests = 0;
      final now = DateTime.now().toUtc();
      final playlistUrl = 'http://127.0.0.1:${server.port}/playlist.m3u';
      final guideUrl = 'http://127.0.0.1:${server.port}/guide.xml';
      final playlist =
          '#EXTM3U url-tvg="$guideUrl"\n'
          '#EXTINF:-1 tvg-id="guide-one",Guide One HD\n'
          'http://stream.example.invalid/one.ts\n';
      server.listen((request) async {
        try {
          switch (request.uri.path) {
            case '/playlist.m3u':
              playlistRequests++;
              if (playlistRequests == 1) {
                firstPlaylistStarted.complete();
                await releaseFirstPlaylist.future;
              } else if (!catalogPlaylistStarted.isCompleted) {
                catalogPlaylistStarted.complete();
              }
              request.response.write(playlist);
            case '/guide.xml':
              guideRequests++;
              request.response.write(
                '<?xml version="1.0"?><tv>'
                '<channel id="guide-one"><display-name>Guide One</display-name>'
                '</channel><programme channel="guide-one" '
                'start="${_stamp(now.subtract(const Duration(hours: 1)))} +0000" '
                'stop="${_stamp(now.add(const Duration(hours: 1)))} +0000">'
                '<title>Startup programme</title></programme></tv>',
              );
            default:
              request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        } on SocketException {
          // A superseded discovery request may close before its gated reply.
        } on HttpException {
          // The response cannot be sent after the client cancels its request.
        }
      });
      final source = M3uSource(sourceId: 'm3u-startup', playlistUrl: playlistUrl);
      final repo = LibraryRepository(
        source: source,
        db: db,
        now: () => DateTime.now().add(const Duration(days: 2)),
      );
      addTearDown(() async {
        if (!releaseFirstPlaylist.isCompleted) releaseFirstPlaylist.complete();
        await source.dispose();
        await server.close(force: true);
        await db.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
        ProviderRequestGate.instance.debugReset();
      });
      final channels = parseM3uPlaylist(playlist).channels;
      await db.migrateSourceCacheIdentity(
        source.id,
        source.name,
        sourceCacheIdentityForSource(source)!,
      );
      await db.replaceLibrary(
        source.id,
        source.name,
        const [],
        channels,
        completeCatalog: true,
      );

      final snapshot = await repo.load();
      expect(snapshot.fromCache, isTrue);
      await firstPlaylistStarted.future.timeout(const Duration(seconds: 5));
      final guideRefresh = repo.pendingEpgRefresh;
      expect(guideRefresh, isNotNull);

      // Home also starts a due daily catalog refresh after opening cached data.
      // Its playlist replaces the parse being used only to discover url-tvg.
      final catalogRefresh = repo.synchronizeCatalog();
      await catalogPlaylistStarted.future.timeout(const Duration(seconds: 5));
      await catalogRefresh.timeout(const Duration(seconds: 5));
      releaseFirstPlaylist.complete();
      await guideRefresh!.timeout(const Duration(seconds: 5));

      expect(playlistRequests, 2);
      expect(guideRequests, 1);
      expect(repo.lastEpgRefreshFailed, isFalse);
      expect(await db.lastEpgSynced(source.id), isNotNull);
      final guide = await db.nowNext(source.id, now);
      expect(guide.now[channels.single.id]?.title, 'Startup programme');
    }, _RealHttpOverrides()),
  );
}

class _RealHttpOverrides extends HttpOverrides {}

String _stamp(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}'
    '${value.month.toString().padLeft(2, '0')}'
    '${value.day.toString().padLeft(2, '0')}'
    '${value.hour.toString().padLeft(2, '0')}'
    '${value.minute.toString().padLeft(2, '0')}'
    '${value.second.toString().padLeft(2, '0')}';
