import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory tempDir;
  late AppDatabase db;
  late _TmdbProvider provider;
  late LibraryRepository repo;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('iptvs_details_metadata');
    db = await AppDatabase.openAt('${tempDir.path}/iptv.db');
    provider = _TmdbProvider();
    final source = DemoSource();
    await db.migrateSourceCacheIdentity(
      source.id,
      source.name,
      sourceCacheIdentityForSource(source)!,
    );
    repo = LibraryRepository(
      source: source,
      db: db,
      metadataProvider: provider,
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> cache(MediaItem item, {bool complete = false}) =>
      db.cacheExternalMetadata(
        'demo',
        item,
        ExternalMetadata(
          provider: 'tmdb',
          providerKey: '42',
          title: 'Cached title',
          overview: 'Cached synopsis',
          poster: 'https://images.test/cached.jpg',
          payload: {
            'id': 42,
            'overview': 'Cached synopsis',
            if (complete) 'credits': {'cast': []},
          },
          refreshedAt: DateTime(2026),
        ),
      );

  for (final kind in [ContentKind.movie, ContentKind.series]) {
    test(
      'opening ${kind.name} details upgrades an old TMDB cache once',
      () async {
        final item = MediaItem(
          id: 'item-1',
          title: 'Provider title',
          kind: kind,
        );
        await cache(item);

        final details = await repo.mediaDetails(item);
        final cached = await db.readExternalMetadata('demo', item, 'tmdb');

        expect(provider.searched, ['item-1']);
        expect(details.description, 'Detailed synopsis');
        expect(details.extra['metadata']['tmdb']['credits'], {
          'cast': [
            {'name': 'Actor Name', 'character': 'Lead'},
          ],
        });
        expect(
          cached?.payload['credits'],
          details.extra['metadata']['tmdb']['credits'],
        );

        await repo.mediaDetails(item);
        expect(provider.searched, ['item-1']);
      },
    );
  }

  test(
    'ordinary enrichment reuses old metadata without a details lookup',
    () async {
      const item = MediaItem(
        id: 'item-1',
        title: 'Provider title',
        kind: ContentKind.movie,
      );
      await cache(item);

      final items = await repo.enrichMediaMetadata([item]);

      expect(provider.searched, isEmpty);
      expect(items.single.description, 'Cached synopsis');
      expect(items.single.poster, 'https://images.test/cached.jpg');
    },
  );

  test('empty cached credits do not trigger another lookup', () async {
    const item = MediaItem(
      id: 'item-1',
      title: 'Provider title',
      kind: ContentKind.movie,
    );
    await cache(item, complete: true);

    final details = await repo.mediaDetails(item);

    expect(provider.searched, isEmpty);
    expect(details.description, 'Cached synopsis');
    expect(details.extra['metadata']['tmdb']['credits'], {'cast': []});
  });

  for (final throwsError in [true, false]) {
    test(
      'a ${throwsError ? 'failed' : 'missing'} details match preserves cached metadata',
      () async {
        const item = MediaItem(
          id: 'item-1',
          title: 'Provider title',
          kind: ContentKind.movie,
        );
        await cache(item);
        provider
          ..fail = throwsError
          ..noMatch = !throwsError;

        final details = await repo.mediaDetails(item);
        final cached = await db.readExternalMetadata('demo', item, 'tmdb');

        expect(provider.searched, ['item-1']);
        expect(details.title, 'Cached title');
        expect(details.description, 'Cached synopsis');
        expect(details.poster, 'https://images.test/cached.jpg');
        expect(details.extra['metadata']['tmdb'], {
          'id': 42,
          'overview': 'Cached synopsis',
        });
        expect(cached?.overview, 'Cached synopsis');
        expect(cached?.payload.containsKey('credits'), isFalse);
      },
    );
  }

  test('manual metadata refresh upgrades an old TMDB cache', () async {
    const item = MediaItem(
      id: 'item-1',
      title: 'Provider title',
      kind: ContentKind.movie,
    );
    await cache(item);

    final metadata = await repo.refreshExternalMetadata(item);

    expect(provider.searched, ['item-1']);
    expect(metadata?.overview, 'Detailed synopsis');
    expect(metadata?.payload['credits'], isA<Map>());
  });

  test(
    'TVmaze supplies series metadata once and preserves provider IDs',
    () async {
      const item = MediaItem(
        id: 'free-series',
        title: 'Provider series',
        kind: ContentKind.series,
      );
      final free = _TmdbProvider(name: 'tvmaze');
      final freeRepo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProviders: [free],
      );
      final details = await freeRepo.mediaDetails(item);
      expect(details.description, 'Detailed synopsis');
      expect(details.providerId, isNull);
      expect(details.extra['metadata']['tvmaze'], isA<Map>());
      await freeRepo.mediaDetails(item);
      expect(free.searched, ['free-series']);
    },
  );

  test('TVmaze is a fallback after configured metadata fails', () async {
    const item = MediaItem(
      id: 'free-series',
      title: 'Provider series',
      kind: ContentKind.series,
    );
    provider.fail = true;
    final free = _TmdbProvider(name: 'tvmaze');
    final freeRepo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProviders: [provider, free],
    );
    expect(
      (await freeRepo.mediaDetails(item)).description,
      'Detailed synopsis',
    );
    expect(free.searched, ['free-series']);
  });

  test(
    'TVmaze does not overwrite configured or cached visual metadata',
    () async {
      const item = MediaItem(
        id: 'free-series',
        title: 'Provider series',
        kind: ContentKind.series,
      );
      final free = _TmdbProvider(name: 'tvmaze');
      final freeRepo = LibraryRepository(
        source: DemoSource(),
        db: db,
        metadataProviders: [provider, free],
      );
      final details = await freeRepo.mediaDetails(item);
      expect(free.searched, isEmpty);
      final freeMetadata = ExternalMetadata(
        provider: 'tvmaze',
        providerKey: '900',
        overview: 'Free synopsis',
        refreshedAt: DateTime.now(),
      );
      expect(
        freeRepo.mergeExternalMetadata(details, freeMetadata).description,
        'Detailed synopsis',
      );
    },
  );

  test('opening a movie upgrades a TVDB search-only cache', () async {
    const item = MediaItem(
      id: 'movie',
      title: 'Provider movie',
      kind: ContentKind.movie,
    );
    final tvdb = _TmdbProvider(name: 'tvdb');
    final tvdbRepo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProviders: [tvdb],
    );
    await db.cacheExternalMetadata(
      'demo',
      item,
      ExternalMetadata(
        provider: 'tvdb',
        providerKey: '42',
        overview: 'Search synopsis',
        payload: {'tvdb_id': '42'},
        refreshedAt: DateTime(2026),
      ),
    );
    expect(
      (await tvdbRepo.mediaDetails(item)).description,
      'Detailed synopsis',
    );
    await tvdbRepo.mediaDetails(item);
    expect(tvdb.searched, ['movie']);
  });

  test('manual metadata refresh replaces a complete TMDB cache', () async {
    const item = MediaItem(
      id: 'item-1',
      title: 'Provider title',
      kind: ContentKind.movie,
    );
    await cache(item, complete: true);

    final metadata = await repo.refreshExternalMetadata(item);
    final cached = await db.readExternalMetadata('demo', item, 'tmdb');

    expect(provider.searched, ['item-1']);
    expect(metadata?.overview, 'Detailed synopsis');
    expect(cached?.refreshedAt, DateTime(2026, 10, 23));
    expect(cached?.payload['credits'], metadata?.payload['credits']);
  });

  for (final throwsError in [true, false]) {
    test(
      'manual refresh ${throwsError ? 'reports failure' : 'reports no match'} and preserves its cache',
      () async {
        const item = MediaItem(
          id: 'item-1',
          title: 'Provider title',
          kind: ContentKind.movie,
        );
        await cache(item, complete: true);
        provider
          ..fail = throwsError
          ..noMatch = !throwsError;

        if (throwsError) {
          await expectLater(
            repo.refreshExternalMetadata(item),
            throwsA(isA<SocketException>()),
          );
        } else {
          expect(await repo.refreshExternalMetadata(item), isNull);
        }
        final cached = await db.readExternalMetadata('demo', item, 'tmdb');

        expect(provider.searched, ['item-1']);
        expect(cached?.overview, 'Cached synopsis');
        expect(cached?.refreshedAt, DateTime(2026));
        expect(cached?.payload['credits'], {'cast': []});
      },
    );
  }

  for (final throwsError in [true, false]) {
    test(
      'manual refresh returns the fallback when the first provider ${throwsError ? 'fails' : 'misses'}',
      () async {
        const item = MediaItem(
          id: 'item-1',
          title: 'Provider title',
          kind: ContentKind.movie,
        );
        await cache(item, complete: true);
        provider
          ..fail = throwsError
          ..noMatch = !throwsError;
        final fallback = _TmdbProvider(name: 'tvdb');
        final fallbackRepo = LibraryRepository(
          source: DemoSource(),
          db: db,
          metadataProviders: [provider, fallback],
        );

        final metadata = await fallbackRepo.refreshExternalMetadata(item);
        final cached = await db.readExternalMetadata('demo', item, 'tmdb');

        expect(provider.searched, ['item-1']);
        expect(fallback.searched, ['item-1']);
        expect(metadata?.provider, 'tvdb');
        expect(metadata?.overview, 'Detailed synopsis');
        expect(cached?.overview, 'Cached synopsis');
        expect(
          (await db.readExternalMetadata('demo', item, 'tvdb'))?.overview,
          'Detailed synopsis',
        );
      },
    );
  }
}

class _TmdbProvider implements MetadataProvider {
  final String name;
  final searched = <String>[];
  var fail = false;
  var noMatch = false;

  _TmdbProvider({this.name = 'tmdb'});

  @override
  String get provider => name;

  @override
  String get authMode => 'none';

  @override
  bool get ratingsOnly => false;

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    searched.add(item.id);
    if (fail) throw const SocketException('Offline');
    if (noMatch) return null;
    return ExternalMetadata(
      provider: provider,
      providerKey: '42',
      title: 'Detailed title',
      overview: 'Detailed synopsis',
      payload: {
        'id': 42,
        if (provider == 'tvdb') 'details_loaded': true,
        'credits': {
          'cast': [
            {'name': 'Actor Name', 'character': 'Lead'},
          ],
        },
      },
      refreshedAt: DateTime(2026, 10, 23),
    );
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async => null;

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async => null;

  @override
  void close() {}
}
