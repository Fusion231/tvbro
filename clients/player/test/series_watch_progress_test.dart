import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_database.dart';
import 'package:iptvs/data/secret_locator_vault.dart';
import 'package:iptvs/data/series_watch_progress.dart';
import 'package:iptvs/sources/source.dart';

MediaItem episode(String id, int? season, int? number) => MediaItem(
  id: id,
  title: id,
  kind: ContentKind.episode,
  parentId: 'season-$season',
  seasonNumber: season,
  episodeNumber: number,
);

PlaybackPosition checkpoint(
  String id, {
  bool finished = true,
  int time = 1,
  bool unknownDuration = false,
}) => PlaybackPosition(
  kind: ContentKind.episode,
  itemId: id,
  position: Duration(minutes: finished ? 19 : 3),
  duration: unknownDuration ? Duration.zero : const Duration(minutes: 20),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(time),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a series without history has no suggested continuation', () {
    final progress = SeriesWatchProgress.fromEpisodes(
      [episode('first', 1, 1)],
      {'other-series': checkpoint('other-series')},
    );
    expect(progress.watchedCount, 0);
    expect(progress.latestEpisode, isNull);
    expect(progress.latestPosition, isNull);
    expect(progress.nextEpisode, isNull);
  });

  test('resumes the latest unfinished episode and ignores older gaps', () {
    final progress = SeriesWatchProgress.fromEpisodes(
      [episode('third', 1, 3), episode('first', 1, 1), episode('second', 1, 2)],
      {
        'first': checkpoint('first'),
        'third': checkpoint('third', finished: false, time: 2),
      },
    );
    expect(progress.episodes.map((item) => item.id), [
      'first',
      'second',
      'third',
    ]);
    expect(progress.watchedCount, 1);
    expect(progress.latestEpisode!.id, 'third');
    expect(progress.latestPosition!.position, const Duration(minutes: 3));
    expect(progress.nextEpisode!.id, 'third');
  });

  test('advances across seasons, skips watched episodes and never wraps', () {
    final episodes = [
      episode('s2e2', 2, 2),
      episode('s1e1', 1, 1),
      episode('s2e1', 2, 1),
      episode('s1e2', 1, 2),
    ];
    final history = {
      's1e2': checkpoint('s1e2', time: 3),
      's2e1': checkpoint('s2e1'),
    };
    final progress = SeriesWatchProgress.fromEpisodes(episodes, history);
    expect(progress.latestEpisode!.id, 's1e2');
    expect(progress.nextEpisode!.id, 's2e2');
    expect(progress.watchedCount, 2);

    history['s2e2'] = checkpoint('s2e2', time: 4);
    expect(
      SeriesWatchProgress.fromEpisodes(episodes, history).nextEpisode,
      isNull,
    );
  });

  test('all watched episodes remain counted once without a next episode', () {
    final first = episode('first', 1, 1);
    final progress = SeriesWatchProgress.fromEpisodes(
      [first, first, episode('second', 1, 2)],
      {'first': checkpoint('first'), 'second': checkpoint('second', time: 2)},
    );
    expect(progress.episodes, hasLength(2));
    expect(progress.watchedCount, 2);
    expect(progress.nextEpisode, isNull);
  });

  test(
    'unknown duration stays unfinished and numbering ties keep provider order',
    () {
      final progress = SeriesWatchProgress.fromEpisodes(
        [
          episode('unnumbered', null, null),
          episode('duplicate-a', 1, 1),
          episode('duplicate-b', 1, 1),
        ],
        {'unnumbered': checkpoint('unnumbered', unknownDuration: true)},
      );
      expect(progress.episodes.map((item) => item.id), [
        'duplicate-a',
        'duplicate-b',
        'unnumbered',
      ]);
      expect(progress.watchedCount, 0);
      expect(progress.nextEpisode!.id, 'unnumbered');
    },
  );

  test('equal checkpoint times prefer the later episode in playback order', () {
    final progress = SeriesWatchProgress.fromEpisodes(
      [episode('second', 1, 2), episode('first', 1, 1)],
      {'first': checkpoint('first'), 'second': checkpoint('second')},
    );
    expect(progress.latestEpisode!.id, 'second');
  });

  test('cached series lookup isolates sources, series and kinds without decrypting', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync(
      'tvbro_series_progress',
    );
    final db = await AppDatabase.openAt('${directory.path}/library.db');
    addTearDown(() async {
      await db.close();
      directory.deleteSync(recursive: true);
    });
    for (final sourceId in ['source', 'other']) {
      for (final seriesId in ['series', 'other-series']) {
        final season = MediaItem(
          id: seriesId == 'series' ? 'season-1' : 'other-season',
          title: 'Season',
          kind: ContentKind.season,
          parentId: seriesId,
        );
        await db.replaceMediaLibrary(sourceId, ContentKind.season, [], [
          season,
        ], parentId: seriesId);
        await db.replaceMediaLibrary(sourceId, ContentKind.episode, [], [
          for (var index = 0; index < 405; index++)
            MediaItem(
              id: '${season.id}-$index',
              title: '$sourceId $seriesId $index',
              kind: ContentKind.episode,
              parentId: season.id,
              episodeNumber: index + 1,
              extra: {'cmd': '/media/$index.mpg'},
            ),
        ], parentId: season.id);
      }
    }
    await db.replaceMediaLibrary('source', ContentKind.movie, [], [
      const MediaItem(
        id: 'movie',
        title: 'Movie',
        kind: ContentKind.movie,
        parentId: 'season-1',
      ),
    ]);
    final decrypts = db.vault.decryptCount;
    final episodes = await db.readCachedSeriesEpisodes('source', 'series');
    expect(episodes, hasLength(405));
    expect(
      episodes.every((item) => item.title.startsWith('source series ')),
      isTrue,
    );
    expect(episodes.first.episodeNumber, 1);
    expect(episodes.last.episodeNumber, 405);
    expect(episodes.every((item) => hasSealedLocator(item.extra)), isTrue);
    expect(db.vault.decryptCount, decrypts);
    expect(await db.readCachedSeriesEpisodes('missing', 'series'), isEmpty);
    expect(await db.readCachedSeriesEpisodes('source', 'missing'), isEmpty);
  });
}
