import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/source.dart';
import 'package:iptvs/sources/xtream_source.dart';

const _movie = MediaItem(
  id: '42',
  title: 'Catalog movie',
  kind: ContentKind.movie,
  extra: {'cmd': '/media/movie.mpg'},
);
const _series = MediaItem(
  id: '42',
  title: 'Catalog series',
  kind: ContentKind.series,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  final sources = <XtreamSource>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_details_cache');
    db = await AppDatabase.openAt('${directory.path}/library.db');
  });

  tearDown(() async {
    for (final source in sources) {
      await source.dispose();
    }
    sources.clear();
    await db.close();
    directory.deleteSync(recursive: true);
  });

  LibraryRepository repository(_Panel panel) {
    sources.add(panel.source);
    return LibraryRepository(source: panel.source, db: db);
  }

  Future<void> seed(_Panel panel, MediaItem item) async {
    await db.migrateSourceCacheIdentity(
      panel.source.id,
      panel.source.name,
      sourceCacheIdentityForSource(panel.source)!,
    );
    await db.replaceMediaLibrary(panel.source.id, item.kind, const [], [item]);
  }

  Future<void> reopen() async {
    await db.close();
    db = await AppDatabase.openAt('${directory.path}/library.db');
  }

  test(
    'movie details survive stale callers and a database reopen offline',
    () async {
      final panel = _Panel();
      final repo = repository(panel);
      await seed(panel, _movie);

      final details = await repo.mediaDetails(_movie);
      expect(details.description, 'cache movie synopsis 1');
      final repeated = await repo.mediaDetails(_movie);
      expect(repeated.description, details.description);
      expect(panel.calls, ['authenticate', 'get_vod_info']);

      final stored = (await db.readMediaItemsByIds(
        panel.source.id,
        ContentKind.movie,
        [_movie.id],
      )).single;
      expect(hasSealedLocator(stored.extra), isTrue);
      expect(stored.extra, isNot(contains('cmd')));
      expect(stored.extra['details'], isA<Map>());
      expect(
        (await db.revealMediaItem(stored)).extra['cmd'],
        _movie.extra['cmd'],
      );

      await reopen();
      final offline = _Panel()..offline = true;
      final reopened = await repository(offline).mediaDetails(_movie);
      expect(reopened.description, details.description);
      expect(offline.calls, isEmpty);
    },
  );

  test(
    'series details and loaded seasons and episodes reopen offline',
    () async {
      final panel = _Panel();
      final repo = repository(panel);
      await seed(panel, _series);

      final details = await repo.mediaDetails(_series);
      final seasons = await repo.loadMedia(ContentKind.season, parent: details);
      final episodes = await repo.loadMedia(
        ContentKind.episode,
        parent: seasons.items.single,
      );
      expect(seasons.items.single.seasonNumber, 1);
      expect(episodes.items.single.title, 'Episode one');
      expect(panel.calls, ['authenticate', 'get_series_info']);

      await reopen();
      final offline = _Panel()..offline = true;
      final reopenedRepo = repository(offline);
      final reopenedDetails = await reopenedRepo.mediaDetails(_series);
      final cachedSeasons = await reopenedRepo.loadMedia(
        ContentKind.season,
        parent: reopenedDetails,
      );
      final cachedEpisodes = await reopenedRepo.loadMedia(
        ContentKind.episode,
        parent: cachedSeasons.items.single,
      );
      expect(reopenedDetails.description, 'cache series synopsis 1');
      expect(cachedSeasons.fromCache, isTrue);
      expect(cachedEpisodes.fromCache, isTrue);
      expect(cachedEpisodes.items.single.id, episodes.items.single.id);
      expect(offline.calls, isEmpty);
    },
  );

  test('a successful empty detail response is cached', () async {
    final panel = _Panel()..emptyDetails = true;
    final repo = repository(panel);
    await seed(panel, _movie);

    final first = await repo.mediaDetails(_movie);
    expect(first.extra['details'], isEmpty);
    final second = await repo.mediaDetails(_movie);
    expect(second.extra['details'], isEmpty);
    expect(panel.calls, ['authenticate', 'get_vod_info']);
  });

  test(
    'a failed detail request stays retryable and recovery is cached',
    () async {
      final panel = _Panel()..failDetails = true;
      final repo = repository(panel);
      await seed(panel, _movie);

      await expectLater(repo.mediaDetails(_movie), throwsStateError);
      final stored = (await db.readMediaItemsByIds(
        panel.source.id,
        ContentKind.movie,
        [_movie.id],
      )).single;
      expect(stored.extra, isNot(contains('details')));

      panel.failDetails = false;
      final recovered = await repo.mediaDetails(_movie);
      expect(recovered.description, 'cache movie synopsis 1');
      await repo.mediaDetails(_movie);
      expect(panel.calls, ['authenticate', 'get_vod_info', 'get_vod_info']);
    },
  );

  test(
    'a root catalog refresh invalidates even a detailed stale caller',
    () async {
      final panel = _Panel();
      final repo = repository(panel);
      await seed(panel, _movie);
      final staleDetails = await repo.mediaDetails(_movie);

      panel.version = 2;
      await repo.synchronizeMediaCatalog(ContentKind.movie, forceRefresh: true);
      final refreshed = (await db.readMediaItemsByIds(
        panel.source.id,
        ContentKind.movie,
        [_movie.id],
      )).single;
      expect(refreshed.extra, isNot(contains('details')));

      final details = await repo.mediaDetails(staleDetails);
      expect(details.description, 'cache movie synopsis 2');
      await repo.mediaDetails(staleDetails);
      expect(
        panel.calls.where((action) => action == 'get_vod_info'),
        hasLength(2),
      );
    },
  );

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    test(
      '${kind.name} details follow refresh policy and restart offline',
      () async {
        final panel = _Panel();
        final repo = repository(panel);
        await repo.synchronizeMediaCatalog(kind);
        final item = (await db.readMediaItems(panel.source.id, kind)).single;
        final details = await repo.mediaDetails(item);
        // Enrichment must not make an unchanged provider title look changed.
        await db.updateMediaDisplayFields(panel.source.id, [
          details.copyWith(
            title: 'Translated title',
            extra: {
              ...details.extra,
              'providerTitle': item.title,
              'metadata': {'test': {}},
            },
          ),
        ]);
        panel.catalogCommand = '/media/new-location.mpg';
        panel.catalogPosition = 2;
        await repo.synchronizeMediaCatalog(kind, forceRefresh: true);
        var stored = (await db.readMediaItems(panel.source.id, kind)).single;
        if (kind == ContentKind.series) {
          expect(stored.extra, isNot(contains('details')));
          await repo.mediaDetails(stored);
          stored = (await db.readMediaItems(panel.source.id, kind)).single;
        }
        expect(stored.extra['details'], isA<Map>());
        expect(stored.extra['num'], 2);
        expect(hasSealedLocator(stored.extra), isTrue);
        expect(
          (await db.revealMediaItem(stored)).extra['cmd'],
          panel.catalogCommand,
        );
        expect(stored.description, details.description);

        await reopen();
        final offline = _Panel()..offline = true;
        expect(
          (await repository(offline).mediaDetails(item)).description,
          details.description,
        );
        expect(offline.calls, isEmpty);
        expect(
          panel.calls.where((action) => action.endsWith('_info')),
          hasLength(kind == ContentKind.series ? 2 : 1),
        );
      },
    );
  }

  test(
    'changed series revision invalidates its cached seasons and episodes',
    () async {
      final panel = _Panel();
      final repo = repository(panel);
      await repo.synchronizeMediaCatalog(ContentKind.series);
      final item = (await db.readMediaItems(
        panel.source.id,
        ContentKind.series,
      )).single;
      final details = await repo.mediaDetails(item);
      final seasons = await repo.loadMedia(ContentKind.season, parent: details);
      await repo.loadMedia(ContentKind.episode, parent: seasons.items.single);

      panel.version = 2;
      await repo.synchronizeMediaCatalog(
        ContentKind.series,
        forceRefresh: true,
      );
      final updated = await repo.mediaDetails(item);
      final freshSeasons = await repo.loadMedia(
        ContentKind.season,
        parent: updated,
      );
      final freshEpisodes = await repo.loadMedia(
        ContentKind.episode,
        parent: freshSeasons.items.single,
      );
      expect(freshEpisodes.items.map((item) => item.id), ['101', '102']);
      expect(
        panel.calls.where((action) => action == 'get_series_info'),
        hasLength(2),
      );
    },
  );

  test('empty details remain cached through an unchanged refresh', () async {
    final panel = _Panel()..emptyDetails = true;
    final repo = repository(panel);
    await repo.synchronizeMediaCatalog(ContentKind.movie);
    final item = (await db.readMediaItems(
      panel.source.id,
      ContentKind.movie,
    )).single;
    await repo.mediaDetails(item);
    await repo.synchronizeMediaCatalog(ContentKind.movie, forceRefresh: true);
    await repo.mediaDetails(item);
    expect(
      panel.calls.where((action) => action == 'get_vod_info'),
      hasLength(1),
    );
  });

  test('detail caches are isolated by source and content kind', () async {
    final first = _Panel();
    final second = _Panel(sourceId: 'other');
    final firstRepo = repository(first);
    final secondRepo = repository(second);
    await seed(first, _movie);
    await seed(first, _series);
    await seed(second, _movie);

    expect(
      (await firstRepo.mediaDetails(_movie)).description,
      'cache movie synopsis 1',
    );
    expect(
      (await firstRepo.mediaDetails(_series)).description,
      'cache series synopsis 1',
    );
    expect(
      (await secondRepo.mediaDetails(_movie)).description,
      'other movie synopsis 1',
    );
    await firstRepo.mediaDetails(_movie);
    await firstRepo.mediaDetails(_series);
    await secondRepo.mediaDetails(_movie);
    expect(first.calls, ['authenticate', 'get_vod_info', 'get_series_info']);
    expect(second.calls, ['authenticate', 'get_vod_info']);
  });
}

class _Panel {
  _Panel({this.sourceId = 'cache'});

  final String sourceId;
  final calls = <String>[];
  var offline = false;
  var emptyDetails = false;
  var failDetails = false;
  var version = 1;
  var catalogPosition = 1;
  var catalogCommand = '/media/movie.mpg';
  late final source = XtreamSource(
    sourceId: sourceId,
    host: 'https://provider.test',
    username: 'user',
    password: 'password',
    debugApi: _api,
  );

  Future<dynamic> _api(Map<String, String> params) async {
    final action = params['action'] ?? 'authenticate';
    calls.add(action);
    if (offline) throw StateError('Offline');
    if (action == 'authenticate') {
      return {
        'user_info': {'auth': 1},
      };
    }
    if (action == 'get_vod_info' || action == 'get_series_info') {
      if (failDetails) throw StateError('Details unavailable');
      if (emptyDetails) return <String, dynamic>{};
      final kind = action == 'get_vod_info' ? 'movie' : 'series';
      return {
        'info': {'plot': '$sourceId $kind synopsis $version'},
        if (kind == 'series')
          'episodes': {
            '1': [
              {'id': '101', 'title': 'Episode one', 'episode_num': 1},
              if (version > 1)
                {'id': '102', 'title': 'Episode two', 'episode_num': 2},
            ],
          },
      };
    }
    if (action == 'get_vod_categories' || action == 'get_series_categories') {
      return [];
    }
    if (action == 'get_vod_streams' || action == 'get_series') {
      return [
        {
          if (action == 'get_vod_streams') 'stream_id': 42 else 'series_id': 42,
          'name': 'Catalog title',
          'num': catalogPosition,
          'last_modified': '$version',
          'cmd': catalogCommand,
          'backdrop_path': ['https://images.test/backdrop.jpg'],
        },
      ];
    }
    throw StateError('Unexpected request: $params');
  }
}
