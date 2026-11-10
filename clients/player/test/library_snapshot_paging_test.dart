import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/library_repository.dart';
import 'package:iptvs/data/metadata_provider.dart';
import 'package:iptvs/data/source_identity_migration.dart';
import 'package:iptvs/sources/demo_source.dart';
import 'package:iptvs/sources/source.dart';

class _PagedSource extends DemoSource {
  final Map<int, List<MediaItem>> pages;
  _PagedSource(this.pages) : super(sourceId: 'source');

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async => MediaPage(items: pages[page] ?? [], page: page, totalPages: 4);
}

class _CachedMetadata extends MetadataProvider {
  @override
  String get provider => 'cached';
  @override
  String get authMode => 'none';
  @override
  Future<ExternalMetadata?> search(MediaItem item) async => null;
  @override
  void close() {}
}

class _CountingDatabase implements AppDatabase {
  final AppDatabase delegate;
  int fullReads = 0;
  final requestedIds = <String>[];
  _CountingDatabase(this.delegate);

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

  @override
  Future<List<MediaItem>> readMediaItems(
    String sourceId,
    ContentKind kind, {
    String? categoryId,
    String? parentId,
  }) {
    fullReads++;
    return delegate.readMediaItems(
      sourceId,
      kind,
      categoryId: categoryId,
      parentId: parentId,
    );
  }

  @override
  Future<List<MediaItem>> readMediaItemsByIds(
    String sourceId,
    ContentKind kind,
    List<String> ids,
  ) {
    requestedIds.addAll(ids);
    return delegate.readMediaItemsByIds(sourceId, kind, ids);
  }

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
  Future<List<MediaCategory>> readMediaCategories(
    String sourceId,
    ContentKind kind,
  ) => delegate.readMediaCategories(sourceId, kind);

  @override
  Future<void> appendMediaItems(
    String sourceId,
    ContentKind kind,
    List<MediaItem> items, {
    String? categoryId,
    String? parentId,
    required int loadedPages,
    required int totalPages,
    String? expectedCacheIdentity,
  }) => delegate.appendMediaItems(
    sourceId,
    kind,
    items,
    categoryId: categoryId,
    parentId: parentId,
    loadedPages: loadedPages,
    totalPages: totalPages,
    expectedCacheIdentity: expectedCacheIdentity,
  );

  @override
  Future<MediaItem> revealMediaItem(MediaItem item) =>
      delegate.revealMediaItem(item);

  @override
  Future<Map<String, ExternalMetadata>> readExternalMetadataForItems(
    String sourceId,
    List<MediaItem> items,
    String provider,
  ) => delegate.readExternalMetadataForItems(sourceId, items, provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late _CountingDatabase counted;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('snapshot_paging');
    db = await AppDatabase.openAt('${directory.path}/db');
    final source = DemoSource(sourceId: 'source');
    await db.migrateSourceCacheIdentity(
      source.id,
      source.name,
      sourceCacheIdentityForSource(source)!,
    );
    counted = _CountingDatabase(db);
  });
  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  Future<MediaLibrarySnapshot> seed(
    List<MediaItem> items, {
    ContentKind kind = ContentKind.movie,
    String? categoryId,
    String? parentId,
  }) async {
    await db.replaceMediaLibrary(
      'source',
      kind,
      [],
      items,
      categoryId: categoryId,
      parentId: parentId,
      loadedPages: 1,
      totalPages: 4,
    );
    final sync = (await db.mediaSyncState(
      'source',
      kind,
      categoryId: categoryId,
      parentId: parentId,
    ))!;
    return MediaLibrarySnapshot(
      kind: kind,
      categoryId: categoryId,
      parentId: parentId,
      categories: [],
      items: await db.readMediaItems(
        'source',
        kind,
        categoryId: categoryId,
        parentId: parentId,
      ),
      fromCache: true,
      syncedAt: sync.syncedAt,
      loadedPages: 1,
      totalPages: 4,
    );
  }

  test(
    'paging reads only appended rows and keeps replacement order and metadata',
    () async {
      final current = await seed([
        for (var i = 0; i < 1000; i++)
          MediaItem(id: '$i', title: 'Movie $i', kind: ContentKind.movie),
      ]);
      final source = _PagedSource({
        2: [const MediaItem(id: '1000', title: 'New', kind: ContentKind.movie)],
        3: [
          const MediaItem(id: '5', title: 'Updated', kind: ContentKind.movie),
        ],
        4: [
          const MediaItem(
            id: '1001',
            title: 'Last',
            kind: ContentKind.movie,
            extra: {'url': 'https://stream.invalid/movie'},
          ),
        ],
      });
      addTearDown(source.dispose);
      await db.cacheExternalMetadata(
        'source',
        current.items.first,
        ExternalMetadata(
          provider: 'cached',
          providerKey: '0',
          title: 'Enriched',
          refreshedAt: DateTime.now(),
        ),
      );
      final repo = LibraryRepository(
        source: source,
        db: counted,
        metadataProvider: _CachedMetadata(),
        autoEnrichMetadata: false,
      );

      final result = await repo.loadMoreMediaFromSnapshot(current);
      final expected = await db.readMediaItems('source', ContentKind.movie);
      expect(
        result.items.map((item) => item.id),
        expected.map((item) => item.id),
      );
      expect(result.items.first.title, 'Enriched');
      expect(
        result.items.where((item) => item.id == '5').single.title,
        'Updated',
      );
      expect(result.items.last.extra['url'], isNull);
      expect(result.items.last.extra['secretLocator'], isNotEmpty);
      expect(result.loadedPages, 4);
      expect(counted.fullReads, 0);
      expect(counted.requestedIds.toSet(), {'1000', '5', '1001'});
    },
  );

  test('a stale snapshot falls back to the current database catalog', () async {
    final current = await seed([
      const MediaItem(id: 'old', title: 'Old', kind: ContentKind.movie),
    ]);
    await db.appendMediaItems(
      'source',
      ContentKind.movie,
      [
        const MediaItem(
          id: 'external',
          title: 'External',
          kind: ContentKind.movie,
        ),
      ],
      loadedPages: 2,
      totalPages: 4,
    );
    final source = _PagedSource({
      3: [const MediaItem(id: 'new', title: 'New', kind: ContentKind.movie)],
    });
    addTearDown(source.dispose);
    final result = await LibraryRepository(
      source: source,
      db: counted,
    ).loadMoreMediaFromSnapshot(current);
    expect(result.items.map((item) => item.id), ['old', 'external', 'new']);
    expect(counted.fullReads, 1);
  });

  test(
    'child paging preserves effective parent and category filtering',
    () async {
      const parent = MediaItem(
        id: 'season',
        title: 'Season',
        kind: ContentKind.season,
      );
      final current = await seed(
        [
          const MediaItem(
            id: 'e1',
            title: 'Episode 1',
            kind: ContentKind.episode,
            categoryId: 'a',
          ),
        ],
        kind: ContentKind.episode,
        categoryId: 'a',
        parentId: parent.id,
      );
      final source = _PagedSource({
        2: [
          const MediaItem(
            id: 'e2',
            title: 'Episode 2',
            kind: ContentKind.episode,
            categoryId: 'a',
          ),
        ],
        3: [
          const MediaItem(
            id: 'hidden',
            title: 'Other category',
            kind: ContentKind.episode,
            categoryId: 'b',
          ),
        ],
      });
      addTearDown(source.dispose);
      final repo = LibraryRepository(
        source: source,
        db: counted,
      );
      final result = await repo.loadMoreMediaFromSnapshot(current, parent: parent);
      expect(result.loadedPages, 2);
      expect(result.items.map((item) => item.id), ['e1', 'e2']);
      expect(
        result.items.map((item) => item.parentId),
        everyElement(parent.id),
      );
      final next = await repo.loadMoreMediaFromSnapshot(result, parent: parent);
      expect(next.loadedPages, 3);
      expect(next.items.map((item) => item.id), ['e1', 'e2']);
      expect(counted.fullReads, 0);
    },
  );
}
