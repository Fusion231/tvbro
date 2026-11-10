import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

const _series = MediaItem(
  id: 'series',
  title: 'Series',
  kind: ContentKind.series,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase database;
  late _CountingDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('tvbro_series_metadata');
    database = await AppDatabase.openAt('${directory.path}/library.db');
    final source = DemoSource();
    await database.migrateSourceCacheIdentity(
      source.id,
      source.name,
      sourceCacheIdentityForSource(source)!,
    );
    db = _CountingDatabase(database);
  });

  tearDown(() async {
    await database.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> seed(
    ContentKind kind,
    MediaItem parent,
    List<MediaItem> items,
  ) => database.replaceMediaLibrary(
    'demo',
    kind,
    const [],
    items,
    parentId: parent.id,
  );

  test('series workload records cold and warm metadata work', () async {
    final provider = _ChildMetadataProvider();
    final repo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProvider: provider,
    );
    final seasons = [
      for (var number = 1; number <= 8; number++)
        MediaItem(
          id: 'season-$number',
          title: 'Provider season $number',
          kind: ContentKind.season,
          parentId: _series.id,
          seasonNumber: number,
        ),
    ];
    final episodes = [
      for (var number = 1; number <= 12; number++)
        MediaItem(
          id: 'episode-$number',
          title: 'Provider episode $number',
          kind: ContentKind.episode,
          parentId: seasons.first.id,
          seasonNumber: 1,
          episodeNumber: number,
          extra: {'cmd': '/media/episode-$number.mpg'},
        ),
    ];
    await seed(ContentKind.season, _series, seasons);
    await seed(ContentKind.episode, seasons.first, episodes);

    for (final phase in ['cold', 'warm']) {
      db.reset();
      final lookups = provider.lookups;
      final watch = Stopwatch()..start();
      final loadedSeasons = await repo.loadMedia(
        ContentKind.season,
        parent: _series,
      );
      final loadedEpisodes = await repo.loadMedia(
        ContentKind.episode,
        parent: loadedSeasons.items.first,
      );
      watch.stop();

      expect(
        loadedSeasons.items.map((item) => item.id),
        seasons.map((e) => e.id),
      );
      expect(
        loadedEpisodes.items.map((item) => item.id),
        episodes.map((e) => e.id),
      );
      expect(loadedEpisodes.items.first.description, 'Overview episode-1');
      expect(provider.maxInFlight, greaterThan(1));
      expect(provider.maxInFlight, lessThanOrEqualTo(4));
      expect(db.singleReads, 0);
      expect(db.bulkReads, 6);
      expect(db.displayRowsWritten, phase == 'cold' ? 20 : 0);
      expect(provider.lookups - lookups, phase == 'cold' ? 20 : 0);
      expect(
        (await database.revealMediaItem(loadedEpisodes.items.first))
            .extra['cmd'],
        '/media/episode-1.mpg',
      );
      debugPrint(
        'SERIES_METADATA_WORK ${jsonEncode({'phase': phase, 'seasons': seasons.length, 'episodes': episodes.length, 'lookups': provider.lookups - lookups, 'maxInFlight': provider.maxInFlight, 'singleCacheReads': db.singleReads, 'bulkCacheReads': db.bulkReads, 'displayRowsWritten': db.displayRowsWritten, 'elapsedMicros': watch.elapsedMicroseconds})}',
      );
    }
  });

  test('child failures preserve order, fallback and retryability', () async {
    final provider = _ChildMetadataProvider(
      failFor: {'episode-2'},
      noMatchFor: {'episode-3'},
    );
    final repo = LibraryRepository(
      source: DemoSource(),
      db: db,
      metadataProvider: provider,
    );
    const season = MediaItem(
      id: 'season',
      title: 'Season',
      kind: ContentKind.season,
      seasonNumber: 1,
    );
    final episodes = [
      for (var number = 1; number <= 5; number++)
        MediaItem(
          id: 'episode-$number',
          title: 'Provider episode $number',
          kind: ContentKind.episode,
          parentId: season.id,
          episodeNumber: number,
        ),
    ];
    await seed(ContentKind.episode, season, episodes);

    for (var attempt = 0; attempt < 2; attempt++) {
      final loaded = await repo.loadMedia(ContentKind.episode, parent: season);
      expect(loaded.items.map((item) => item.id), episodes.map((e) => e.id));
      expect(loaded.items[0].description, 'Overview episode-1');
      expect(loaded.items[1].title, episodes[1].title);
      expect(loaded.items[2].title, episodes[2].title);
      expect(loaded.items[4].description, 'Overview episode-5');
    }
    expect(provider.lookups, 7);
  });
}

class _ChildMetadataProvider extends MetadataProvider {
  _ChildMetadataProvider({this.failFor = const {}, this.noMatchFor = const {}});

  final Set<String> failFor;
  final Set<String> noMatchFor;
  int lookups = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  String get provider => 'fixture';

  @override
  String get authMode => 'none';

  @override
  Future<ExternalMetadata?> search(MediaItem item) async {
    lookups++;
    inFlight++;
    if (maxInFlight < inFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(
        Duration(
          milliseconds:
              int.tryParse(
                Platform.environment['IPTVS_SERIES_RTT_MS'] ?? '0',
              ) ??
              0,
        ),
      );
      if (failFor.contains(item.id)) throw StateError('Fixture failure');
      if (noMatchFor.contains(item.id)) return null;
      return ExternalMetadata(
        provider: provider,
        providerKey: 'metadata-${item.id}',
        title: 'Metadata ${item.id}',
        overview: 'Overview ${item.id}',
        refreshedAt: DateTime(2026),
      );
    } finally {
      inFlight--;
    }
  }

  @override
  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) => search(season);

  @override
  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) => search(episode);

  @override
  void close() {}
}

class _CountingDatabase extends Fake implements AppDatabase {
  _CountingDatabase(this.delegate);

  final AppDatabase delegate;
  int singleReads = 0;
  int bulkReads = 0;
  int displayRowsWritten = 0;

  @override
  Future<bool> migrateSourceCacheIdentity(
    String sourceId,
    String name,
    String identity, {
    bool onlyIfUnknown = false,
  }) => delegate.migrateSourceCacheIdentity(
    sourceId,
    name,
    identity,
    onlyIfUnknown: onlyIfUnknown,
  );

  @override
  Future<bool> sourceCacheIdentityMatches(String sourceId, String identity) =>
      delegate.sourceCacheIdentityMatches(sourceId, identity);

  void reset() {
    singleReads = 0;
    bulkReads = 0;
    displayRowsWritten = 0;
  }

  @override
  Future<MediaItem> revealMediaItem(MediaItem item) =>
      delegate.revealMediaItem(item);

  @override
  Future<({DateTime syncedAt, int loadedPages, int totalPages})?>
  mediaSyncState(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) => delegate.mediaSyncState(
    sourceId,
    kind,
    categoryId: categoryId,
    parentId: parentId,
  );

  @override
  Future<List<MediaItem>> readMediaItems(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) => delegate.readMediaItems(
    sourceId,
    kind,
    categoryId: categoryId,
    parentId: parentId,
  );

  @override
  Future<List<MediaCategory>> readMediaCategories(
    String sourceId,
    ContentKind kind,
  ) => delegate.readMediaCategories(sourceId, kind);

  @override
  Future<ExternalMetadata?> readExternalMetadata(
    String sourceId,
    MediaItem item,
    String provider,
  ) {
    singleReads++;
    return delegate.readExternalMetadata(sourceId, item, provider);
  }

  @override
  Future<Map<String, ExternalMetadata>> readExternalMetadataForItems(
    String sourceId,
    List<MediaItem> items,
    String provider,
  ) {
    bulkReads++;
    return delegate.readExternalMetadataForItems(sourceId, items, provider);
  }

  @override
  Future<void> cacheExternalMetadata(
    String sourceId,
    MediaItem item,
    ExternalMetadata metadata, {
    String? expectedCacheIdentity,
  }) => delegate.cacheExternalMetadata(
    sourceId,
    item,
    metadata,
    expectedCacheIdentity: expectedCacheIdentity,
  );

  @override
  Future<void> updateMediaDisplayFields(
    String sourceId,
    List<MediaItem> items, {
    ({DateTime? syncedAt})? seriesCatalogVersion,
    String? expectedCacheIdentity,
  }) {
    displayRowsWritten += items.length;
    return delegate.updateMediaDisplayFields(
      sourceId,
      items,
      seriesCatalogVersion: seriesCatalogVersion,
      expectedCacheIdentity: expectedCacheIdentity,
    );
  }
}
