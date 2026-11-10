import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final operation in ['details', 'children']) {
    test('late series $operation cannot undo a completed refresh', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('series_race_');
      final db = await AppDatabase.openAt('${directory.path}/cache.db');
      final started = Completer<void>();
      final release = Completer<void>();
      var episodeCount = 2;
      var defer = true;
      final source = XtreamSource(
        sourceId: 'series-race',
        host: 'https://fixture.invalid',
        username: 'user',
        password: 'password',
        debugApi: (params) async {
          switch (params['action'] ?? 'auth') {
            case 'auth':
              return {
                'user_info': {'auth': 1},
              };
            case 'get_series_categories':
              return [];
            case 'get_series':
              return [
                {'series_id': '7', 'name': 'Unchanged series'},
              ];
            case 'get_series_info':
              final response = {
                'episodes': {
                  '1': [
                    for (var i = 1; i <= episodeCount; i++)
                      {'id': '$i', 'episode_num': i, 'title': 'Episode $i'},
                  ],
                },
              };
              if (defer) {
                started.complete();
                await release.future;
              }
              return response;
            default:
              throw StateError('${params['action']}');
          }
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await source.dispose();
        await db.close();
        directory.deleteSync(recursive: true);
      });
      final repository = LibraryRepository(source: source, db: db);
      await repository.synchronizeMediaCatalog(ContentKind.series);
      final root = (await repository.loadMedia(ContentKind.series))
          .items
          .single;
      final Future<Object> pending = operation == 'details'
          ? repository.mediaDetails(root)
          : repository.loadMedia(ContentKind.season, parent: root);
      final rejected = expectLater(
        pending,
        throwsA(isA<LoadCancelledException>()),
      );
      await started.future;
      episodeCount = 3;
      // A different screen/repository shares the persisted catalog boundary.
      await LibraryRepository(
        source: source,
        db: db,
      ).synchronizeMediaCatalog(ContentKind.series, forceRefresh: true);
      defer = false;
      release.complete();
      await rejected;
      expect(await db.readMediaItems(source.id, ContentKind.season), isEmpty);
      final stored = (await db.readMediaItems(
        source.id,
        ContentKind.series,
      )).single;
      expect(stored.extra['details'], isNull);
      final season = (await repository.loadMedia(
        ContentKind.season,
        parent: root,
      )).items.single;
      expect(
        (await repository.loadMedia(ContentKind.episode, parent: season)).items,
        hasLength(3),
      );
    });
  }

  test(
    'unchanged root refresh discovers new episodes, restart stays offline',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('series_refresh_');
      var db = await AppDatabase.openAt('${directory.path}/cache.db');
      final calls = <String>[];
      var episodeCount = 2;
      var rejectCatalog = false;
      XtreamSource createSource() => XtreamSource(
        sourceId: 'series-cache',
        host: 'https://fixture.invalid',
        username: 'fixture-user',
        password: 'fixture-password',
        debugApi: (params) async {
          final action = params['action'] ?? 'auth';
          calls.add(action);
          switch (action) {
            case 'auth':
              return {
                'user_info': {'auth': 1},
              };
            case 'get_series_categories':
              return [
                {'category_id': '1', 'category_name': 'Series'},
              ];
            case 'get_series':
              if (rejectCatalog) throw const SocketException('offline');
              return [
                {
                  'series_id': '7',
                  'name': 'Unchanged series',
                  'category_id': '1',
                },
              ];
            case 'get_series_info':
              return {
                'info': {'name': 'Unchanged series'},
                'episodes': {
                  '1': [
                    for (var i = 1; i <= episodeCount; i++)
                      {'id': '$i', 'episode_num': i, 'title': 'Episode $i'},
                  ],
                },
              };
            default:
              throw StateError(action);
          }
        },
      );
      var source = createSource();
      var repo = LibraryRepository(source: source, db: db);
      addTearDown(() async {
        await source.dispose();
        await db.close();
        directory.deleteSync(recursive: true);
      });
      await repo.synchronizeMediaCatalog(ContentKind.series);
      final root = (await repo.loadMedia(ContentKind.series)).items.single;
      final details = await repo.mediaDetails(root);
      final season = (await repo.loadMedia(
        ContentKind.season,
        parent: details,
      )).items.single;
      expect(
        (await repo.loadMedia(ContentKind.episode, parent: season)).items,
        hasLength(2),
      );
      await db.savePlaybackPosition(
        source.id,
        ContentKind.episode,
        '1',
        position: const Duration(seconds: 20),
        duration: const Duration(minutes: 10),
      );

      final beforeRestart = calls.length;
      await source.dispose();
      await db.close();
      db = await AppDatabase.openAt('${directory.path}/cache.db');
      source = createSource();
      repo = LibraryRepository(source: source, db: db);
      final warmRoot = (await repo.loadMedia(ContentKind.series)).items.single;
      final warmDetails = await repo.mediaDetails(warmRoot);
      final warmSeason = (await repo.loadMedia(
        ContentKind.season,
        parent: warmDetails,
      )).items.single;
      expect(
        (await repo.loadMedia(ContentKind.episode, parent: warmSeason)).items,
        hasLength(2),
      );
      expect(calls.length, beforeRestart);

      rejectCatalog = true;
      await expectLater(
        repo.synchronizeMediaCatalog(ContentKind.series, forceRefresh: true),
        throwsA(isA<SocketException>()),
      );
      expect(
        (await repo.loadMedia(ContentKind.episode, parent: warmSeason)).items,
        hasLength(2),
      );
      rejectCatalog = false;
      episodeCount = 3;
      await repo.synchronizeMediaCatalog(
        ContentKind.series,
        forceRefresh: true,
      );
      // Reuse a season still held by an already-open episode sheet.
      expect(
        (await repo.loadMedia(ContentKind.episode, parent: warmSeason))
            .items.map((item) => item.id),
        ['1', '2', '3'],
      );
      // Reuse the old details model too; the rebuilt child cache is now warm.
      final freshSeason = (await repo.loadMedia(
        ContentKind.season,
        parent: warmDetails,
      )).items.single;
      expect(
        (await repo.loadMedia(
          ContentKind.episode,
          parent: freshSeason,
        )).items.map((e) => e.id),
        ['1', '2', '3'],
      );
      expect(calls.where((a) => a == 'get_series_info'), hasLength(2));
      expect(
        (await db.readPlaybackPosition(
          source.id,
          ContentKind.episode,
          '1',
        ))!.position.inMilliseconds,
        20000,
      );
    },
  );

  test(
    'Xtream orders seasons and episodes and rejects empty identities',
    () async {
      final source = XtreamSource(
        sourceId: 'sort',
        host: 'https://fixture.invalid',
        username: 'u',
        password: 'p',
      );
      addTearDown(source.dispose);
      final series = MediaItem(
        id: '7',
        title: 'Series',
        kind: ContentKind.series,
        extra: {
          'details': {
            'episodes': {
              '10': [],
              '2': [],
              '0': [],
              '1': [
                {'id': '10', 'episode_num': 10},
                {'id': '2', 'episode_num': 2},
                {'episode_num': 3},
                {'id': '1', 'episode_num': 1},
              ],
            },
          },
        },
      );
      final seasons = await source.mediaItems(
        ContentKind.season,
        parent: series,
      );
      expect(seasons.map((s) => s.seasonNumber), [0, 1, 2, 10]);
      final episodes = await source.mediaItems(
        ContentKind.episode,
        parent: seasons[1],
      );
      expect(episodes.map((e) => e.id), ['1', '2', '10']);
      await expectLater(
        source.resolveMedia(
          const MediaItem(id: '', title: 'Invalid', kind: ContentKind.episode),
        ),
        throwsArgumentError,
      );
    },
  );
}
