import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/data/net.dart';
import 'package:iptvs/sources/m3u_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final forceMediaRefresh in [true, false]) {
    test(
      'M3U download survives concurrent ${forceMediaRefresh ? 'forced' : 'expired'} media refresh',
      () => HttpOverrides.runWithHttpOverrides(() async {
        ProviderRequestGate.instance.debugReset();
        FlutterSecureStorage.setMockInitialValues({});
        final directory = Directory.systemTemp.createTempSync('m3u_catalog');
        final db = await AppDatabase.openAt('${directory.path}/library.db');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final started = Completer<void>();
        final release = Completer<void>();
        var requests = 0;
        server.listen((request) async {
          requests++;
          if (requests == 1) {
            started.complete();
            await release.future;
          }
          request.response.write(
            '#EXTM3U\n'
            '#EXTINF:-1 tvg-id="test.pl" group-title="PL",Channel $requests\n'
            'http://example.invalid/live/$requests.ts\n',
          );
          await request.response.close();
        });
        final source = M3uSource(
          sourceId: 'm3u-catalog',
          playlistUrl: 'http://127.0.0.1:${server.port}/get.php',
        );
        final repo = LibraryRepository(
          source: source,
          db: db,
          now: () => DateTime.now().add(const Duration(days: 2)),
        );
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          await source.dispose();
          await server.close(force: true);
          await db.epgIngest.cancelAndWait();
          await db.close();
          directory.deleteSync(recursive: true);
        });

        if (!forceMediaRefresh) {
          for (final kind in [ContentKind.movie, ContentKind.series]) {
            await db.replaceMediaLibrary(
              source.id,
              kind,
              const [],
              const [],
              completeCatalog: true,
            );
          }
        }
        final token = LoadToken();
        repo.loadToken = token;
        final live = repo
            .load(forceRefresh: forceMediaRefresh)
            .then<Object>(
              (snapshot) => snapshot,
              onError: (Object error) => error,
            );
        await started.future.timeout(const Duration(seconds: 10));
        final media = Future.wait([
          for (final kind in [ContentKind.movie, ContentKind.series])
            repo.synchronizeMediaCatalog(
              kind,
              forceRefresh: forceMediaRefresh,
              token: token,
            ),
        ]);
        release.complete();
        await media;

        final result = await live.timeout(const Duration(seconds: 10));
        expect(result, isA<LibrarySnapshot>());
        expect((result as LibrarySnapshot).channels.single.name, 'Channel 1');
        expect(await db.readChannels(source.id), hasLength(1));
        expect(requests, 1);
        repo.loadToken = null;

        // An intentional channel refresh must still fetch new playlist data.
        final refreshed = await repo.load(forceRefresh: true);
        expect(refreshed.channels.single.name, 'Channel 2');
        expect(requests, 2);
      }, _RealHttpOverrides()),
    );
  }
}

class _RealHttpOverrides extends HttpOverrides {}
