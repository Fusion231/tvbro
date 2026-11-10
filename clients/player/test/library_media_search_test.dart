import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppDatabase db;
  late String path;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('tvbro_media_search');
    path = '${directory.path}/library.db';
    db = await AppDatabase.openAt(path);
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<void> seed(String source, ContentKind kind, List<MediaItem> items) =>
      db.replaceMediaLibrary(source, kind, const [], items);

  test(
    'local search preserves Unicode, literal characters and catalog order',
    () async {
      await seed('source', ContentKind.movie, const [
        MediaItem(id: 'z', title: 'ŻÓŁĆ 100%_done', kind: ContentKind.movie),
        MediaItem(id: 'a', title: 'żółć 100%_done', kind: ContentKind.movie),
        MediaItem(id: 'b', title: 'Other 100x_done', kind: ContentKind.movie),
      ]);
      expect(
        (await db.searchMediaItems(
          'source',
          ContentKind.movie,
          ' ŻółĆ ',
        )).map((item) => item.id),
        ['z', 'a'],
      );
      expect(
        (await db.searchMediaItems(
          'source',
          ContentKind.movie,
          '%_',
        )).map((item) => item.id),
        ['z', 'a'],
      );
      expect(
        await db.searchMediaItems('source', ContentKind.movie, '  '),
        isEmpty,
      );
    },
  );

  test('local search isolates source, kind and category and leaves locators sealed', () async {
    MediaItem item(String id, ContentKind kind, String category) => MediaItem(
      id: id,
      title: 'Matching title',
      kind: kind,
      categoryId: category,
      extra: {'cmd': '/media/$id.mpg'},
    );
    await seed('source', ContentKind.movie, [
      item('selected', ContentKind.movie, 'selected'),
      item('other-category', ContentKind.movie, 'other'),
    ]);
    await seed('other-source', ContentKind.movie, [
      item('other-source', ContentKind.movie, 'selected'),
    ]);
    await seed('source', ContentKind.series, [
      item('other-kind', ContentKind.series, 'selected'),
    ]);
    final result = await db.searchMediaItems(
      'source',
      ContentKind.movie,
      'matching',
      categoryId: 'selected',
    );
    expect(result.map((item) => item.id), ['selected']);
    expect(hasSealedLocator(result.single.extra), isTrue);
    expect(db.vault.decryptCount, 0);
    expect(
      (await db.revealMediaItem(result.single)).extra['cmd'],
      '/media/selected.mpg',
    );
  });

  test(
    'a selective search does not decode unrelated metadata payloads',
    () async {
      await seed('source', ContentKind.movie, const [
        MediaItem(id: 'hit', title: 'Wanted movie', kind: ContentKind.movie),
        MediaItem(
          id: 'miss',
          title: 'Unrelated movie',
          kind: ContentKind.movie,
        ),
        MediaItem(
          id: 'another-miss',
          title: 'Another movie',
          kind: ContentKind.movie,
        ),
      ]);
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.update(
        'media_items',
        {'extra': 'unrelated malformed JSON'},
        where: 'id = ?',
        whereArgs: ['miss'],
      );
      expect(
        (await db.searchMediaItems(
          'source',
          ContentKind.movie,
          'wanted',
        )).map((item) => item.id),
        ['hit'],
      );
    },
  );

  test(
    'broad series search preserves children and skips unrelated payloads',
    () async {
      await seed('source', ContentKind.series, const [
        MediaItem(id: 'root', title: 'Matching series', kind: ContentKind.series),
        MediaItem(
          id: 'child',
          title: 'Matching season',
          kind: ContentKind.series,
          parentId: 'root',
        ),
        MediaItem(id: 'miss', title: 'Unrelated series', kind: ContentKind.series),
        MediaItem(
          id: 'episode',
          title: 'Matching episode',
          kind: ContentKind.series,
          parentId: 'child',
        ),
      ]);
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.update(
        'media_items',
        {'extra': 'unrelated malformed JSON'},
        where: 'id = ?',
        whereArgs: ['miss'],
      );
      expect(
        (await db.searchMediaItems(
          'source',
          ContentKind.series,
          'matching',
        )).map((item) => item.id),
        ['root', 'child', 'episode'],
      );
      expect(
        await db.searchMediaItems('source', ContentKind.series, 'absent'),
        isEmpty,
      );
    },
  );

  test('many search matches retain catalog order', () async {
    final ids = [for (var i = 1100; i >= 0; i--) '$i'];
    await seed('source', ContentKind.movie, [
      for (final id in ids)
        MediaItem(id: id, title: 'Matching $id', kind: ContentKind.movie),
      for (var i = 0; i < 1200; i++)
        MediaItem(
          id: 'miss-$i',
          title: 'Unrelated $i',
          kind: ContentKind.movie,
        ),
    ]);
    expect(
      (await db.searchMediaItems(
        'source',
        ContentKind.movie,
        'matching',
      )).map((item) => item.id),
      ids,
    );
  });

  test(
    'chunked cache reads retain parent/category scope, order and sealed values',
    () async {
      final ids = [for (var i = 420; i >= 0; i--) '$i'];
      await seed('source', ContentKind.series, [
        for (final id in ids)
          MediaItem(
            id: id,
            title: 'Item $id',
            kind: ContentKind.series,
            categoryId: 'selected',
            parentId: 'parent',
            extra: id == ids.first ? {'cmd': '/media/synthetic.mpg'} : const {},
          ),
        const MediaItem(
          id: 'other-category',
          title: 'Other category',
          kind: ContentKind.series,
          categoryId: 'other',
          parentId: 'parent',
        ),
        const MediaItem(
          id: 'other-parent',
          title: 'Other parent',
          kind: ContentKind.series,
          categoryId: 'selected',
          parentId: 'other',
        ),
      ]);
      for (final (source, kind) in [
        ('other-source', ContentKind.series),
        ('source', ContentKind.movie),
      ]) {
        await seed(source, kind, [
          MediaItem(
            id: ids.first,
            title: 'Other scope',
            kind: kind,
            categoryId: 'selected',
            parentId: 'parent',
          ),
        ]);
      }
      final result = await db.readMediaItems(
        'source',
        ContentKind.series,
        categoryId: 'selected',
        parentId: 'parent',
      );
      expect(result.map((item) => item.id), ids);
      expect(
        result.every(
          (item) => item.categoryId == 'selected' && item.parentId == 'parent',
        ),
        isTrue,
      );
      expect(hasSealedLocator(result.first.extra), isTrue);
      expect(db.vault.decryptCount, 0);
      expect(
        (await db.revealMediaItem(result.first)).extra['cmd'],
        '/media/synthetic.mpg',
      );
    },
  );

  test(
    'catalog counts isolate source and kind without decoding payloads',
    () async {
      expect(await db.countMediaItems('source', ContentKind.movie), 0);
      await seed('source', ContentKind.movie, const [
        MediaItem(id: 'a', title: 'A', kind: ContentKind.movie),
        MediaItem(id: 'b', title: 'B', kind: ContentKind.movie),
      ]);
      await seed('other', ContentKind.movie, const [
        MediaItem(id: 'a', title: 'A', kind: ContentKind.movie),
      ]);
      await seed('source', ContentKind.series, const [
        MediaItem(id: 'a', title: 'A', kind: ContentKind.series),
      ]);
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.update('media_items', {'extra': 'payload need not be decoded'});
      expect(await db.countMediaItems('source', ContentKind.movie), 2);
      expect(await db.countMediaItems('source', ContentKind.series), 1);
      expect(await db.countMediaItems('other', ContentKind.movie), 1);
    },
  );
}
