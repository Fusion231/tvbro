import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory temp;
  late AppDatabase db;
  String path() => '${temp.path}/test.db';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tvbro_favorites_sync');
    db = await AppDatabase.openAt(path());
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'source migration preserves pending favorite additions and removals',
    () async {
      await db.setFavorite('legacy', ContentKind.series, 'saved', true);
      await db.setFavorite('legacy', ContentKind.series, 'removed', false);
      final before = await db.readFavoritesOutbox();
      await db.migrateSourceNamespace('legacy', 'uuid');
      final pending = await db.readFavoritesOutbox();
      expect(pending.map((row) => row.sourceId).toSet(), {'uuid'});
      expect(
        pending.map((row) => (row.itemId, row.add, row.updatedAt)),
        before.map((row) => (row.itemId, row.add, row.updatedAt)),
      );
      await db.applyCloudFavorites(
        {'uuid'},
        {
          'uuid': {
            ContentKind.series: {'removed', 'remote'},
          },
        },
      );
      expect(await db.readFavoriteIds('uuid', ContentKind.series), {
        'saved',
        'remote',
      });
      expect(await db.readFavoriteIds('legacy', ContentKind.series), isEmpty);
    },
  );

  test('snapshot preserves pending intent and device-only favorites', () async {
    await db.setFavorites('cloud', ContentKind.series, ['old']);
    await db.setFavorite('cloud', ContentKind.series, 'added', true);
    await db.setFavorite('cloud', ContentKind.series, 'removed', false);
    await db.setFavorite('local', ContentKind.series, 'device-only', true);
    final pending = await db.readFavoritesOutbox();
    final changed = <void>[];
    final replaced = <void>[];
    final localSub = db.favoritesChanged.listen(changed.add);
    final remoteSub = db.favoritesReplaced.listen(replaced.add);
    await db.applyCloudFavorites(
      {'cloud'},
      {
        'cloud': {
          ContentKind.series: {'remote', 'removed'},
        },
        'local': {
          ContentKind.series: {'unrequested'},
        },
      },
    );
    await localSub.cancel();
    await remoteSub.cancel();
    expect(await db.readFavoriteIds('cloud', ContentKind.series), {
      'added',
      'remote',
    });
    expect(await db.readFavoriteIds('local', ContentKind.series), {
      'device-only',
    });
    expect(await db.readFavoritesOutbox(), pending);
    expect(changed, isEmpty);
    expect(replaced, hasLength(1));
  });

  test('failed snapshot rolls back clears and emits no replacement', () async {
    await db.setFavorites('cloud', ContentKind.series, ['original']);
    final raw = await databaseFactoryFfi.openDatabase(path());
    await raw.execute('''
      CREATE TRIGGER reject_favorite BEFORE INSERT ON favorites
      WHEN NEW.item_id = 'broken'
      BEGIN SELECT RAISE(ABORT, 'simulated interrupted replacement'); END
    ''');
    final replaced = <void>[];
    final sub = db.favoritesReplaced.listen(replaced.add);
    await expectLater(
      db.applyCloudFavorites(
        {'cloud'},
        {
          'cloud': {
            ContentKind.series: {'remote', 'broken'},
          },
        },
      ),
      throwsA(isA<DatabaseException>()),
    );
    await sub.cancel();
    expect(await db.readFavoriteIds('cloud', ContentKind.series), {'original'});
    expect(replaced, isEmpty);
  });

  test('favorite and intent roll back together if queue write fails', () async {
    final raw = await databaseFactoryFfi.openDatabase(path());
    await raw.execute('''
      CREATE TRIGGER reject_intent BEFORE INSERT ON favorites_outbox
      BEGIN SELECT RAISE(ABORT, 'simulated outbox failure'); END
    ''');
    final changed = <void>[];
    final sub = db.favoritesChanged.listen(changed.add);
    await expectLater(
      db.setFavorite('cloud', ContentKind.series, 'new', true),
      throwsA(isA<DatabaseException>()),
    );
    await sub.cancel();
    expect(await db.readFavoriteIds('cloud', ContentKind.series), isEmpty);
    expect(await db.readFavoritesOutbox(), isEmpty);
    expect(changed, isEmpty);
  });

  test(
    'acknowledgement preserves a newer repeated add despite clock rollback',
    () async {
      await db.setFavorite('cloud', ContentKind.series, 'series', true);
      final raw = await databaseFactoryFfi.openDatabase(path());
      final future = DateTime.now().millisecondsSinceEpoch + 60000;
      await raw.update('favorites_outbox', {'updated_at': future});
      final delivered = await db.readFavoritesOutbox();
      await db.setFavorite('cloud', ContentKind.series, 'series', false);
      await db.setFavorite('cloud', ContentKind.series, 'series', true);
      final pending = await db.readFavoritesOutbox();
      expect(pending.single.updatedAt, future + 2);
      await db.clearFavoritesOutbox(delivered);
      expect(await db.readFavoritesOutbox(), pending);
      await db.applyCloudFavorites({'cloud'}, const {});
      expect(await db.readFavoriteIds('cloud', ContentKind.series), {'series'});
    },
  );

  test(
    'concurrent snapshot and local changes retain the final local intent',
    () async {
      await Future.wait([
        db.setFavorite('cloud', ContentKind.series, 'first', true),
        db.applyCloudFavorites({'cloud'}, const {}),
        db.setFavorite('cloud', ContentKind.series, 'second', true),
      ]);
      expect(await db.readFavoriteIds('cloud', ContentKind.series), {
        'first',
        'second',
      });
      expect(
        (await db.readFavoritesOutbox()).map((row) => row.itemId).toSet(),
        {'first', 'second'},
      );
    },
  );
}
