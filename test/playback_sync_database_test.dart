import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

PlaybackPositionChange change(
  String itemId, {
  String sourceId = 'cloud',
  int positionMs = 60000,
  int updatedAt = 100,
  bool removed = false,
}) => (
  sourceId: sourceId,
  kind: ContentKind.movie,
  itemId: itemId,
  positionMs: positionMs,
  durationMs: 1200000,
  updatedAt: updatedAt,
  removed: removed,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory temp;
  late AppDatabase db;
  String path() => '${temp.path}/test.db';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tvbro_playback_sync');
    db = await AppDatabase.openAt(path());
  });

  tearDown(() async {
    await db.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> save(String itemId, {String sourceId = 'cloud'}) =>
      db.savePlaybackPosition(
        sourceId,
        ContentKind.movie,
        itemId,
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 20),
      );

  test('progress and finished tombstones survive database reopening', () async {
    final localChanges = <void>[];
    final subscription = db.playbackPositionsChanged.listen(localChanges.add);
    await db.savePlaybackPosition(
      'cloud',
      ContentKind.movie,
      'too-early',
      position: const Duration(seconds: 5),
      duration: const Duration(minutes: 20),
    );
    expect(await db.readPlaybackOutbox(), isEmpty);
    await save('in-progress');
    await save('finished');
    await db.savePlaybackPosition(
      'cloud',
      ContentKind.movie,
      'finished',
      position: const Duration(minutes: 19),
      duration: const Duration(minutes: 20),
    );
    final queued = await db.readPlaybackOutbox();
    expect(queued, hasLength(2));
    expect(
      queued.singleWhere((row) => row.itemId == 'finished').removed,
      isTrue,
    );
    await subscription.cancel();
    expect(localChanges, hasLength(3));
    await db.close();
    db = await AppDatabase.openAt(path());
    expect(await db.readPlaybackOutbox(), queued);
    expect(
      (await db.readPlaybackPositionsForSync()).single.itemId,
      'in-progress',
    );
  });

  test('acknowledgement retains a newer edit with the same position', () async {
    await save('movie');
    final first = await db.readPlaybackOutbox();
    await save('movie');
    final second = await db.readPlaybackOutbox();
    expect(second.single.updatedAt, greaterThan(first.single.updatedAt));
    await db.clearPlaybackOutbox(first);
    expect(await db.readPlaybackOutbox(), second);
    await db.clearPlaybackPosition('cloud', ContentKind.movie, 'movie');
    final removed = await db.readPlaybackOutbox();
    expect(removed.single.updatedAt, greaterThan(second.single.updatedAt));
    expect(removed.single.removed, isTrue);
    await db.clearPlaybackOutbox(second);
    expect(await db.readPlaybackOutbox(), removed);
    await db.clearPlaybackOutbox(removed);
    expect(await db.readPlaybackOutbox(), isEmpty);
  });

  test(
    'cloud replacement overlays pending edits without upload feedback',
    () async {
      await save('stale');
      await db.clearPlaybackOutbox(await db.readPlaybackOutbox());
      await save('local-progress');
      await db.clearPlaybackPosition(
        'cloud',
        ContentKind.movie,
        'local-removal',
      );
      await save('device-only', sourceId: 'local');
      final pending = await db.readPlaybackOutbox();
      final localChanges = <void>[];
      final replacements = <void>[];
      final localSub = db.playbackPositionsChanged.listen(localChanges.add);
      final remoteSub = db.playbackPositionsReplaced.listen(replacements.add);
      await db.applyCloudPlaybackPositions(
        {'cloud'},
        [
          change('local-progress', positionMs: 120000),
          change('local-removal'),
          change('remote-progress', updatedAt: 200),
          change('not-managed', sourceId: 'local'),
          change('remote-removal', removed: true),
        ],
      );
      expect(
        (await db.readRecentPositions('cloud'))
            .map((row) => row.itemId)
            .toSet(),
        {'local-progress', 'remote-progress'},
      );
      expect(
        (await db.readPlaybackPosition(
          'cloud',
          ContentKind.movie,
          'local-progress',
        ))!.position,
        const Duration(minutes: 3),
      );
      expect((await db.readRecentPositions('local')).map((row) => row.itemId), [
        'device-only',
      ]);
      expect(await db.readPlaybackOutbox(), pending);
      await localSub.cancel();
      await remoteSub.cancel();
      expect(localChanges, isEmpty);
      expect(replacements, hasLength(1));
    },
  );

  test(
    'v16 upgrade seeds progress and preserves already queued removals',
    () async {
      await save('old-progress');
      await db.clearPlaybackOutbox(await db.readPlaybackOutbox());
      await db.close();
      var raw = await databaseFactoryFfi.openDatabase(path());
      await raw.execute('DROP TABLE playback_positions_outbox');
      await raw.setVersion(16);
      await raw.close();
      db = await AppDatabase.openAt(path());
      final seeded = await db.readPlaybackOutbox();
      expect(seeded.single.itemId, 'old-progress');
      expect(seeded.single.removed, isFalse);
      await db.clearPlaybackPosition(
        'cloud',
        ContentKind.movie,
        'old-progress',
      );
      final removal = await db.readPlaybackOutbox();
      await db.close();
      raw = await databaseFactoryFfi.openDatabase(path());
      await raw.insert('playback_positions', {
        'source_id': 'cloud',
        'kind': 'movie',
        'item_id': 'old-progress',
        'position_ms': 60000,
        'duration_ms': 1200000,
        'updated_at': 1,
      });
      await raw.setVersion(16);
      await raw.close();
      db = await AppDatabase.openAt(path());
      expect(await db.readPlaybackOutbox(), removal);
    },
  );

  test(
    'newer remote progress wins over a stale offline outbox entry',
    () async {
      await save('movie');
      final pending = await db.readPlaybackOutbox();
      final remoteVersion = pending.single.updatedAt + 120000;
      await db.applyCloudPlaybackPositions(
        {'cloud'},
        [change('movie', positionMs: 600000, updatedAt: remoteVersion)],
      );
      final restored = await db.readPlaybackPosition(
        'cloud',
        ContentKind.movie,
        'movie',
      );
      expect(restored!.position, const Duration(minutes: 10));
      expect(restored.updatedAt.millisecondsSinceEpoch, remoteVersion);
      expect(await db.readPlaybackOutbox(), pending);
      await db.clearPlaybackOutbox(pending);
      // Fresh edits must be newer even when the device clock trails the cloud.
      await save('movie');
      expect(
        (await db.readPlaybackOutbox()).single.updatedAt,
        greaterThan(remoteVersion),
      );
    },
  );

  test(
    'a remote removal wins an equal timestamp against queued progress',
    () async {
      await save('movie');
      final pending = await db.readPlaybackOutbox();
      await db.applyCloudPlaybackPositions(
        {'cloud'},
        [change('movie', updatedAt: pending.single.updatedAt, removed: true)],
      );
      expect(
        await db.readPlaybackPosition('cloud', ContentKind.movie, 'movie'),
        isNull,
      );
      expect(await db.readPlaybackOutbox(), pending);
    },
  );

  test(
    'source identity migration moves pending progress and removals',
    () async {
      await save('progress', sourceId: 'legacy');
      await db.clearPlaybackPosition('legacy', ContentKind.episode, 'removed');
      await db.migrateSourceNamespace('legacy', 'uuid');
      final queued = await db.readPlaybackOutbox();
      expect(queued.map((row) => row.sourceId).toSet(), {'uuid'});
      expect(
        queued.singleWhere((row) => row.itemId == 'removed').removed,
        isTrue,
      );
      expect(await db.readRecentPositions('legacy'), isEmpty);
      expect((await db.readRecentPositions('uuid')).single.itemId, 'progress');
    },
  );
}
