import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/load_token.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late String path;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = Directory.systemTemp.createTempSync('catalog_database');
    path = '${directory.path}/cache.db';
    db = await AppDatabase.openAt(path);
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  for (final kind in [
    ContentKind.live,
    ContentKind.movie,
    ContentKind.series,
  ]) {
    test('complete empty ${kind.name} catalog survives reopening', () async {
      if (kind == ContentKind.live) {
        await db.replaceLibrary(
          'source',
          'Source',
          [],
          [],
          completeCatalog: true,
        );
      } else {
        await db.replaceMediaLibrary(
          'source',
          kind,
          [],
          [],
          completeCatalog: true,
        );
      }
      final before = await db.lastCatalogSynced('source', kind);
      expect(before, isNotNull);
      expect(
        DateTime.now().difference(before!),
        lessThan(const Duration(seconds: 5)),
      );

      await db.close();
      db = await AppDatabase.openAt(path);
      expect(await db.lastCatalogSynced('source', kind), before);
      expect(await db.lastCatalogSynced('other', kind), isNull);
      if (kind != ContentKind.live) {
        final state = await db.mediaSyncState(
          'source',
          kind,
          categoryId: 'empty',
        );
        expect(state?.syncedAt, before);
        expect(state?.loadedPages, 1);
        expect(state?.totalPages, 1);
      }
    });
  }

  test(
    'legacy partial caches are not promoted during schema 15 upgrade',
    () async {
      await db.replaceLibrary('source', 'Source', [], const [
        Channel(id: 'tv', name: 'TV'),
      ]);
      await db.replaceMediaLibrary(
        'source',
        ContentKind.movie,
        [],
        const [MediaItem(id: 'old', title: 'Old', kind: ContentKind.movie)],
        loadedPages: 1,
        totalPages: 8,
      );
      await db.close();
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.execute('DROP TABLE catalog_sync');
      await raw.setVersion(15);
      await raw.close();

      db = await AppDatabase.openAt(path);
      expect(await db.lastCatalogSynced('source', ContentKind.live), isNull);
      expect(await db.lastCatalogSynced('source', ContentKind.movie), isNull);
      expect(
        (await db.mediaSyncState('source', ContentKind.movie))?.totalPages,
        8,
      );
      expect((await db.readChannels('source')).single.id, 'tv');
      expect(
        (await db.readMediaItems('source', ContentKind.movie)).single.id,
        'old',
      );
    },
  );

  test('full media import replaces category pages and clears removed groups', () async {
    await db.replaceMediaLibrary(
      'source',
      ContentKind.movie,
      [],
      const [
        MediaItem(
          id: 'stale',
          title: 'Stale',
          kind: ContentKind.movie,
          categoryId: 'a',
        ),
      ],
      categoryId: 'a',
      loadedPages: 2,
      totalPages: 20,
    );
    await db.replaceMediaLibrary('source', ContentKind.movie, [], const [
      MediaItem(
        id: 'gone',
        title: 'Gone',
        kind: ContentKind.movie,
        categoryId: 'removed',
      ),
    ], categoryId: 'removed');
    await db.replaceMediaLibrary(
      'source',
      ContentKind.movie,
      const [
        MediaCategory(id: 'a', title: 'A', kind: ContentKind.movie),
        MediaCategory(id: 'empty', title: 'Empty', kind: ContentKind.movie),
      ],
      const [
        MediaItem(
          id: 'fresh',
          title: 'Fresh',
          kind: ContentKind.movie,
          categoryId: 'a',
        ),
      ],
      completeCatalog: true,
      loadedPages: 20,
      totalPages: 20,
    );

    expect(
      (await db.readMediaItems('source', ContentKind.movie)).single.id,
      'fresh',
    );
    expect(
      (await db.readMediaCategories(
        'source',
        ContentKind.movie,
      )).map((c) => c.id),
      ['a', 'empty'],
    );
    final complete = await db.lastCatalogSynced('source', ContentKind.movie);
    for (final category in ['a', 'empty', 'removed']) {
      final state = await db.mediaSyncState(
        'source',
        ContentKind.movie,
        categoryId: category,
      );
      expect(state?.syncedAt, complete);
      expect(state?.loadedPages, 1);
      expect(state?.totalPages, 1);
    }
    expect(
      await db.mediaSyncState('source', ContentKind.movie, parentId: 'child'),
      isNull,
    );

    // A later partial root import invalidates the marker. Deleted category page
    // states must not then reappear from the older catalog.
    await db.replaceMediaLibrary(
      'source',
      ContentKind.movie,
      [],
      [],
      totalPages: 2,
    );
    expect(await db.lastCatalogSynced('source', ContentKind.movie), isNull);
    expect(
      await db.mediaSyncState(
        'source',
        ContentKind.movie,
        categoryId: 'removed',
      ),
      isNull,
    );
  });

  test(
    'local search respects source, kind, category and literal Unicode text',
    () async {
      await db.replaceMediaLibrary('source', ContentKind.movie, [], const [
        MediaItem(
          id: 'polish',
          title: 'ŁÓDŹ 100%_test',
          kind: ContentKind.movie,
          categoryId: 'a',
          extra: {'url': 'https://private.invalid/movie'},
        ),
        MediaItem(
          id: 'other-cat',
          title: 'Łódź',
          kind: ContentKind.movie,
          categoryId: 'b',
        ),
        MediaItem(id: 'ordinary', title: 'Ordinary', kind: ContentKind.movie),
      ], completeCatalog: true);
      await db.replaceMediaLibrary('other', ContentKind.movie, [], const [
        MediaItem(id: 'other-source', title: 'Łódź', kind: ContentKind.movie),
      ]);
      await db.replaceMediaLibrary('source', ContentKind.series, [], const [
        MediaItem(id: 'other-kind', title: 'Łódź', kind: ContentKind.series),
      ]);

      final results = await db.searchMediaItems(
        'source',
        ContentKind.movie,
        ' łódź ',
        categoryId: 'a',
      );
      expect(results.map((item) => item.id), ['polish']);
      expect(results.single.extra['url'], isNull);
      expect(results.single.extra['secretLocator'], isNotEmpty);
      expect(
        (await db.searchMediaItems(
          'source',
          ContentKind.movie,
          '%_',
        )).single.id,
        'polish',
      );
      expect(
        await db.searchMediaItems('source', ContentKind.movie, "' OR 1=1"),
        isEmpty,
      );
      expect(
        await db.searchMediaItems('source', ContentKind.movie, ' '),
        isEmpty,
      );
    },
  );

  for (final kind in [
    ContentKind.live,
    ContentKind.movie,
    ContentKind.series,
  ]) {
    test(
      'cancelled ${kind.name} writer cannot overwrite complete empty catalog',
      () async {
        final token = LoadToken()..cancel();
        if (kind == ContentKind.live) {
          await db.replaceLibrary(
            'source',
            'Source',
            [],
            [],
            completeCatalog: true,
          );
        } else {
          await db.replaceMediaLibrary(
            'source',
            kind,
            [],
            [],
            completeCatalog: true,
          );
        }
        final before = await db.lastCatalogSynced('source', kind);
        final wrote = kind == ContentKind.live
            ? await db.replaceLibrary(
                'source',
                'Source',
                [],
                const [Channel(id: 'late', name: 'Late')],
                completeCatalog: true,
                token: token,
              )
            : await db.replaceMediaLibrary(
                'source',
                kind,
                [],
                [MediaItem(id: 'late', title: 'Late', kind: kind)],
                completeCatalog: true,
                token: token,
              );
        expect(wrote, isFalse);
        expect(await db.lastCatalogSynced('source', kind), before);
        expect(
          kind == ContentKind.live
              ? await db.readChannels('source')
              : await db.readMediaItems('source', kind),
          isEmpty,
        );
      },
    );
  }

  test(
    'cancelled media writer can seed an absent cache without marking complete',
    () async {
      final token = LoadToken()..cancel();
      expect(
        await db.replaceMediaLibrary(
          'source',
          ContentKind.movie,
          [],
          const [MediaItem(id: 'seed', title: 'Seed', kind: ContentKind.movie)],
          completeCatalog: true,
          token: token,
        ),
        isTrue,
      );
      expect(
        (await db.readMediaItems('source', ContentKind.movie)).single.id,
        'seed',
      );
      expect(await db.lastCatalogSynced('source', ContentKind.movie), isNull);
    },
  );

  test('category and append writes invalidate completeness; child writes preserve it', () async {
    await db.replaceMediaLibrary('source', ContentKind.series, [], const [
      MediaItem(id: 'show', title: 'Show', kind: ContentKind.series),
    ], completeCatalog: true);
    final before = await db.lastCatalogSynced('source', ContentKind.series);
    await db.replaceMediaLibrary('source', ContentKind.episode, [], const [
      MediaItem(id: 'episode', title: 'Episode', kind: ContentKind.episode),
    ], parentId: 'season');
    expect(await db.lastCatalogSynced('source', ContentKind.series), before);
    await db.replaceMediaLibrary(
      'source',
      ContentKind.series,
      [],
      [],
      categoryId: 'a',
    );
    expect(await db.lastCatalogSynced('source', ContentKind.series), isNull);
    await db.replaceMediaLibrary(
      'source',
      ContentKind.series,
      [],
      [],
      completeCatalog: true,
    );
    await db.appendMediaItems(
      'source',
      ContentKind.series,
      [],
      loadedPages: 2,
      totalPages: 3,
    );
    expect(await db.lastCatalogSynced('source', ContentKind.series), isNull);
  });

  test('source namespace migration moves complete catalog markers', () async {
    await db.replaceMediaLibrary(
      'old',
      ContentKind.movie,
      [],
      [],
      completeCatalog: true,
    );
    final before = await db.lastCatalogSynced('old', ContentKind.movie);
    await db.migrateSourceNamespace('old', 'new');
    expect(await db.lastCatalogSynced('old', ContentKind.movie), isNull);
    expect(await db.lastCatalogSynced('new', ContentKind.movie), before);
  });

  test(
    'lost locator key clears completion markers with regenerable cache',
    () async {
      await db.replaceMediaLibrary('source', ContentKind.movie, [], const [
        MediaItem(
          id: 'movie',
          title: 'Movie',
          kind: ContentKind.movie,
          extra: {'url': 'https://private.invalid/movie'},
        ),
      ], completeCatalog: true);
      await db.close();
      FlutterSecureStorage.setMockInitialValues({});
      db = await AppDatabase.openAt(path);
      expect(await db.lastCatalogSynced('source', ContentKind.movie), isNull);
      expect(await db.readMediaItems('source', ContentKind.movie), isEmpty);
    },
  );
}
