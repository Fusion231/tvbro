import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  late Directory directory;
  late AppDatabase db;
  String path() => '${directory.path}/test.db';

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('tvbro_episode_progress');
    db = await AppDatabase.openAt(path());
  });

  tearDown(() async {
    await db.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'finished episodes survive reopening without becoming resume points',
    () async {
      await db.savePlaybackPosition(
        'source',
        ContentKind.episode,
        'finished',
        position: const Duration(minutes: 19),
        duration: const Duration(minutes: 20),
      );
      await db.savePlaybackPosition(
        'source',
        ContentKind.episode,
        'started',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 20),
      );
      await db.close();
      db = await AppDatabase.openAt(path());

      final positions = await db.readEpisodePlaybackPositions('source', [
        'finished',
        'started',
      ]);
      expect(positions['finished']!.isFinished, isTrue);
      expect(positions['started']!.isFinished, isFalse);
      expect(positions['started']!.position, const Duration(minutes: 3));
      expect(
        PlaybackPosition(
          kind: ContentKind.episode,
          itemId: 'unknown-duration',
          position: const Duration(hours: 1),
          duration: Duration.zero,
          updatedAt: DateTime(2026),
        ).isFinished,
        isFalse,
      );
      expect(
        await db.readPlaybackPosition(
          'source',
          ContentKind.episode,
          'finished',
        ),
        isNull,
      );
      expect(
        (await db.readRecentPositions('source', limit: 1)).single.itemId,
        'started',
      );
      final outbox = await db.readPlaybackOutbox();
      expect(
        outbox.singleWhere((row) => row.itemId == 'finished').removed,
        isFalse,
      );
      expect(await db.readPlaybackPositionsForSync(), hasLength(2));
      final exported = await db.exportUserState();
      expect(exported['playback_positions'], hasLength(2));
    },
  );

  test(
    'episode progress lookup filters source and kind and chunks large lists',
    () async {
      for (final sourceId in ['source', 'other']) {
        for (final kind in [ContentKind.episode, ContentKind.movie]) {
          await db.savePlaybackPosition(
            sourceId,
            kind,
            'episode-900',
            position: Duration(minutes: sourceId == 'source' ? 3 : 6),
            duration: Duration(minutes: kind == ContentKind.episode ? 20 : 90),
          );
        }
      }
      await db.savePlaybackPosition(
        'source',
        ContentKind.episode,
        'not-requested',
        position: const Duration(minutes: 3),
        duration: const Duration(minutes: 20),
      );

      final positions = await db.readEpisodePlaybackPositions('source', [
        for (var index = 0; index < 1000; index++) 'episode-$index',
        'episode-900',
      ]);
      expect(positions.keys, ['episode-900']);
      expect(positions.values.single.position, const Duration(minutes: 3));
      expect(positions.values.single.duration, const Duration(minutes: 20));
      expect(await db.readEpisodePlaybackPositions('source', []), isEmpty);
    },
  );

  test(
    'cloud replacement and backup import preserve watched episodes',
    () async {
      await db.applyCloudPlaybackPositions(
        {'source'},
        [
          (
            sourceId: 'source',
            kind: ContentKind.episode,
            itemId: 'finished',
            positionMs: const Duration(minutes: 19).inMilliseconds,
            durationMs: const Duration(minutes: 20).inMilliseconds,
            updatedAt: 100,
            removed: false,
          ),
        ],
      );
      final exported = await db.exportUserState();
      await db.clearPlaybackPosition('source', ContentKind.episode, 'finished');
      await db.restoreUserState(exported);

      final positions = await db.readEpisodePlaybackPositions('source', [
        'finished',
      ]);
      expect(positions['finished']!.isFinished, isTrue);
      expect(await db.readRecentPositions('source'), isEmpty);
      expect(
        await db.readPlaybackPosition(
          'source',
          ContentKind.episode,
          'finished',
        ),
        isNull,
      );
    },
  );
}
